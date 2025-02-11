#!/bin/bash
# Copyright 2021 Absa Group Limited
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Generated by GoLic, for more details see: https://github.com/AbsaOSS/golic

set -o errexit
set -o pipefail
#set -o nounset     ;handling unset environment variables manually
#set -x             ;debugging

YELLOW=
CYAN=
RED=
NC=
K3D_URL=https://raw.githubusercontent.com/rancher/k3d/main/install.sh
K3D_VERSION=v4.4.7
DEFAULT_NETWORK=k3d-action-bridge-network
DEFAULT_SUBNET=172.16.0.0/24
NOT_FOUND=k3d-not-found-network
REGISTRY_HOSTNAME=registry.localhost
REGISTRY_NAME=registry.local
REGISTRY_CONFIG_PATH="$(pwd)/registries-local.yaml"
DEFAULT_REGISTRY_PORT=5000

#######################
#
#     FUNCTIONS
#
#######################
usage(){
  cat <<EOF

  Usage: $(basename "$0") <COMMAND>
  Commands:
      deploy            deploy custom k3d cluster

  Environment variables:
      deploy
                        CLUSTER_NAME (Required) k3d cluster name.

                        ARGS (Optional) k3d arguments.

                        NETWORK (Optional) If not set than default k3d-action-bridge-network is created
                                               and all clusters share that network.

                        SUBNET_CIDR (Optional) If not set than default 172.16.0.0/24 is used. Variable requires
                                              NETWORK to be set.

                        USE_DEFAULT_REGISTRY (Optional) If not set than default false. If true provides local docker registry
                                              registry.localhost:5000 without TLS and authentication.

                        REGISTRY_PORT (Optional) Registry port. Default value 5000.

      test-registry
                        REGISTRY_PORT (Optional) Registry port. Default value 5000.
EOF
}

panic() {
  (>&2 echo -e " - ${RED}$*${NC}")
  usage
  exit 1
}

deploy(){
    local name=${CLUSTER_NAME}
    local arguments=${ARGS:-}
    local network=${NETWORK:-$DEFAULT_NETWORK}
    local subnet=${SUBNET_CIDR:-$DEFAULT_SUBNET}
    local registry=${USE_DEFAULT_REGISTRY:-}
    local registryPort=${REGISTRY_PORT:-$DEFAULT_REGISTRY_PORT}
    local registryArg

    if [[ -z "${CLUSTER_NAME}" ]]; then
      panic "CLUSTER_NAME must be set"
    fi

    existing_network=$(docker network list | awk '   {print $2 }' | grep -w "^$network$" || echo $NOT_FOUND)

    if [[ ($network == "$DEFAULT_NETWORK") && ($subnet != "$DEFAULT_SUBNET") ]]
    then
      panic "You can't specify custom subnet for default network."
    fi

    if [[ ($network != "$DEFAULT_NETWORK") && ($subnet == "$DEFAULT_SUBNET") ]]
    then
      if [[ "$existing_network" == "$NOT_FOUND" ]]
      then
        panic "Subnet CIDR must be specified for custom network"
      fi
    fi

    echo

    # create network if doesn't exists
    if [[ "$existing_network" == "$NOT_FOUND" ]]
    then
      echo -e "${YELLOW}create new network ${CYAN}$network $subnet ${NC}"
      docker network create --driver=bridge --subnet="$subnet" "$network"
    else
      echo -e "${YELLOW}attaching nodes to existing ${CYAN}$network ${NC}"
      subnet=$(docker network inspect "$network" -f '{{(index .IPAM.Config 0).Subnet}}')
    fi

    if [[ "$registry" == "true" ]]
    then
      echo -e "${YELLOW}attaching registry to ${CYAN}$network ${NC}"
      registry "$network" "$registryPort"
      registryArg="--volume \"${REGISTRY_CONFIG_PATH}:/etc/rancher/k3s/registries.yaml\""
      cat "${REGISTRY_CONFIG_PATH}"
    fi

    # Setup GitHub Actions outputs
    echo "::set-output name=network::$network"
    echo "::set-output name=subnet-CIDR::$subnet"

    echo -e "${YELLOW}Downloading ${CYAN}k3d@${K3D_VERSION} ${NC}see: ${K3D_URL}"
    curl --silent --fail ${K3D_URL} | TAG=${K3D_VERSION} bash

    echo -e "\existing_network${YELLOW}Deploy cluster ${CYAN}$name ${NC}"
    eval "k3d cluster create $name --wait $arguments --network $network $registryArg"
    wait_for_nodes
}

# see: https://rancher.com/docs/k3s/latest/en/installation/private-registry/#mirrors
registry(){
    local network=$1
    local port=$2
    # create registry if not exists
    if [ ! "$(docker ps -q -f name=${REGISTRY_NAME})" ];
    then
      echo -e "${YELLOW}Inject registry ${CYAN}${REGISTRY_NAME}:${port}${NC}"
      cat > "${REGISTRY_CONFIG_PATH}" <<EOF
mirrors:
  "$REGISTRY_HOSTNAME:$port":
    endpoint:
      - "http://$REGISTRY_NAME:$port"
EOF
      docker volume create local_registry
      docker container run -d --name ${REGISTRY_NAME} -v local_registry:/var/lib/registry --restart always -p "${port}":5000 registry:2
    fi
    # connect registry to network if not connected yet
    containsRegistry=$(docker network inspect "$network" | grep ${REGISTRY_NAME} || echo $NOT_FOUND)
    if [[ "$containsRegistry" == "$NOT_FOUND" ]]
    then
      docker network connect "$network" ${REGISTRY_NAME}
    fi
}

# test_registry check registry from outside the cluster
test_registry(){
  local registryPort=${REGISTRY_PORT:-$DEFAULT_REGISTRY_PORT}
  local tag=localhost:${registryPort}/k3d-action-dummy:v0.0.1
  echo -e "${CYAN}Test whether local registry is running${NC}"
  echo -e "${YELLOW}push and remove image${CYAN} ${tag}${NC}"
  docker build -t "${tag}" -f- . &> /dev/null <<EOF
FROM scratch
LABEL type=dummy
EOF
  docker push "${tag}"
  docker image rm "${tag}" &> /dev/null
  echo -e "${YELLOW}pull${CYAN} ${tag}${NC}"
  docker pull "${tag}"
  docker images
}


init_registry(){
    # create registry if not exists
    local port=$1
    local registryName=$2
    if [ ! "$(docker ps -q -f name="${registryName}")" ];
    then
      k3d registry create "${registryName}" --image=docker.io/library/registry:2 --port="${port}"
    fi
}

# waits until all nodes are ready
wait_for_nodes(){
  echo -e "${YELLOW}wait until all agents are ready${NC}"
  while :
  do
    readyNodes=1
    statusList=$(kubectl get nodes --no-headers | awk '{ print $2}')
    # shellcheck disable=SC2162
    while read status
    do
      if [ "$status" == "NotReady" ] || [ "$status" == "" ]
      then
        readyNodes=0
        break
      fi
    done <<< "$(echo -e  "$statusList")"
    # all nodes are ready; exit
    if [[ $readyNodes == 1 ]]
    then
      break
    fi
    sleep 1
  done
}
#######################
#
#     GUARDS SECTION
#
#######################
if [[ "$#" -lt 1 ]]; then
  usage
  exit 1
fi
if [[ -z "${NO_COLOR}" ]]; then
      YELLOW="\033[0;33m"
      CYAN="\033[1;36m"
      NC="\033[0m"
      RED="\033[0;91m"
fi

#######################
#
#     COMMANDS
#
#######################
case "$1" in
    "deploy")
       deploy
    ;;
    "test-registry")
       test_registry
    ;;
#    "<put new command here>")
#       command_handler
#    ;;
      *)
  usage
  exit 0
  ;;
esac

#!/bin/bash

#CHANGEME: change to sepcify the appropriate rhcos  image and corresponding release image:
export OPENSHIFT_INSTALL_OS_IMAGE_OVERRIDE=http://127.0.0.1:8000/rhcos-43.81.201912251015.0-openstack.ppc64le.qcow2
export OPENSHIFT_VERSION=6b3f7278f311ce084ad1cdd6556026e2108bea7e8932e1815f67e26362cd10d8
export OPENSHIFT_CLIENT_VERSION=4.3.0-0.nightly-ppc64le-2020-01-06-161556


export LC_ALL=C
export LANG=C

INSTALL_DIR=crc-tmp-install-data
JQ=${JQ:-jq}
OC=${OC:-oc}
YQ=${YQ:-yq}
OPENSHIFT_INSTALL=${OPENSHIFT_INSTALL:-./openshift-install}
CRC_VM_NAME=${CRC_VM_NAME:-crc}
BASE_DOMAIN=${CRC_BASE_DOMAIN:-testing}
QUAY_REGISTRY=${QUAY_REGISTRY:-quay.io/openshift-release-dev/ocp-release-nightly@sha256}
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i id_rsa_crc"

arch=$(uname -m)
if [ "$(arch)" == "x86_64" ]; then
    arch="amd64"
fi

# If user defined the OPENSHIFT_VERSION environment variable then use it.
# Otherwise use the tagged version if available
function get_openshift_version {
    if [ "${OPENSHIFT_VERSION}" != "" ]; then
        OPENSHIFT_RELEASE_VERSION=$OPENSHIFT_VERSION
    else
        OPENSHIFT_RELEASE_VERSION=$(git describe --exact-match --tags HEAD 2>/dev/null)
    fi
}

function create_json_description {
    openshiftInstallerVersion=$(${OPENSHIFT_INSTALL} version)
    sncGitHash=$(git describe --abbrev=4 HEAD 2>/dev/null || git rev-parse --short=4 HEAD)
    echo {} | ${JQ} '.version = "1.0"' \
            | ${JQ} '.type = "snc"' \
            | ${JQ} ".buildInfo.buildTime = \"$(date -u --iso-8601=seconds)\"" \
            | ${JQ} ".buildInfo.openshiftInstallerVersion = \"${openshiftInstallerVersion}\"" \
            | ${JQ} ".buildInfo.sncVersion = \"git${sncGitHash}\"" \
            | ${JQ} ".clusterInfo.openshiftVersion = \"${OPENSHIFT_RELEASE_VERSION:-git}\"" \
            | ${JQ} ".clusterInfo.clusterName = \"${CRC_VM_NAME}\"" \
            | ${JQ} ".clusterInfo.baseDomain = \"${BASE_DOMAIN}\"" \
            | ${JQ} ".clusterInfo.appsDomain = \"apps-${CRC_VM_NAME}.${BASE_DOMAIN}\"" >${INSTALL_DIR}/crc-bundle-info.json
}

get_openshift_version

# Download the oc binary if not present in current directory
if ! which $OC; then
    if [[ ! -e oc ]] ; then
        if [ "${OPENSHIFT_RELEASE_VERSION}" != "" ]; then
            curl -L http://mirror.openshift.com/pub/openshift-v4/${arch}/clients/ocp-dev-preview/${OPENSHIFT_CLIENT_VERSION}/openshift-client-linux-${OPENSHIFT_CLIENT_VERSION}.tar.gz | tar zx oc
        else
            curl -L https://mirror.openshift.com/pub/openshift-v4/clients/oc/latest/linux/oc.tar.gz | tar zx oc
        fi
    fi
    OC=./oc
fi

# Download yq for manipulating in place yaml configs
if ! which $YQ; then
    if [[ ! -e yq ]]; then
        curl -L https://github.com/mikefarah/yq/releases/download/2.2.1/yq_linux_${arch} -o yq
        chmod +x yq
    fi
    YQ=./yq
fi

if ! which ${JQ}; then
    sudo yum -y install /usr/bin/jq
fi

# Destroy an existing cluster and resources
${OPENSHIFT_INSTALL} --dir $INSTALL_DIR destroy cluster --log-level debug

if [ "${OPENSHIFT_PULL_SECRET}" = "" ]; then
    echo "OpenShift pull secret must be specified through the OPENSHIFT_PULL_SECRET environment variable"
    exit 1
fi

# Use the release payload for the latest known openshift release as indicated by git tags
if [ "${OPENSHIFT_RELEASE_VERSION}" != "" ]; then
    OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${QUAY_REGISTRY}:${OPENSHIFT_RELEASE_VERSION}
    export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE
    echo "Setting OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE to ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
fi

# Generate a new ssh keypair for this cluster
rm id_rsa_crc* || true
ssh-keygen -N "" -f id_rsa_crc -C "core"

# Set NetworkManager DNS overlay file
cat << EOF | sudo tee /etc/NetworkManager/dnsmasq.d/openshift.conf
server=/${CRC_VM_NAME}.${BASE_DOMAIN}/192.168.126.1
address=/apps-${CRC_VM_NAME}.${BASE_DOMAIN}/192.168.126.11
EOF

# Reload the NetworkManager to make DNS overlay effective
sudo systemctl reload NetworkManager

# Create the INSTALL_DIR for the installer and copy the install-config
rm -fr $INSTALL_DIR && mkdir $INSTALL_DIR && cp install-config.yaml $INSTALL_DIR
${YQ} write --inplace $INSTALL_DIR/install-config.yaml baseDomain $BASE_DOMAIN
${YQ} write --inplace $INSTALL_DIR/install-config.yaml metadata.name $CRC_VM_NAME
${YQ} write --inplace $INSTALL_DIR/install-config.yaml compute[0].replicas 0
${YQ} write --inplace $INSTALL_DIR/install-config.yaml pullSecret "${OPENSHIFT_PULL_SECRET}"
${YQ} write --inplace $INSTALL_DIR/install-config.yaml sshKey "$(cat id_rsa_crc.pub)"

# Create the manifests using the INSTALL_DIR
${OPENSHIFT_INSTALL} --dir $INSTALL_DIR create manifests || exit 1

# Add custom domain to cluster-ingress
${YQ} write --inplace $INSTALL_DIR/manifests/cluster-ingress-02-config.yml spec[domain] apps-${CRC_VM_NAME}.${BASE_DOMAIN}
# Add master memory to 12 GB and 6 cpus 
# This is only valid for openshift 4.3 onwards
${YQ} write --inplace $INSTALL_DIR/openshift/99_openshift-cluster-api_master-machines-0.yaml spec.providerSpec.value[domainMemory] 16384
${YQ} write --inplace $INSTALL_DIR/openshift/99_openshift-cluster-api_master-machines-0.yaml spec.providerSpec.value[domainVcpu] 6

# Start the cluster with 10GB memory and 4 CPU create and wait till it finish
# Todo: we need to remove this once stop building 4.2 bits.
# For 4.3 this is ignored.
export TF_VAR_libvirt_master_memory=10192
export TF_VAR_libvirt_master_vcpu=4

# Add codeReadyContainer as invoker to identify it with telemeter
export OPENSHIFT_INSTALL_INVOKER="codeReadyContainers"

${OPENSHIFT_INSTALL} --dir $INSTALL_DIR create cluster --log-level debug

export KUBECONFIG=$INSTALL_DIR/auth/kubeconfig

# Wait for install to complete, this provide another 30 mins to make resources (apis) stable
${OPENSHIFT_INSTALL} --dir $INSTALL_DIR wait-for install-complete --log-level debug
if [ $? -ne 0 ]; then
    echo "This is known to fail with:
'pool master is not ready - timed out waiting for the condition'
see https://github.com/openshift/machine-config-operator/issues/579"
fi

# Set the VM static hostname to crc-xxxxx-master-0 instead of localhost.localdomain
HOSTNAME=$(${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} hostnamectl status --transient)
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} sudo hostnamectl set-hostname ${HOSTNAME}

create_json_description

# Once it is finished, disable the CVO
${OC} scale --replicas=0 deployment --all -n openshift-cluster-version

# Get the pod name associated with cluster-monitoring-operator deployment
cmo_pod=$(${OC} get pod -l app=cluster-monitoring-operator -o jsonpath="{.items[0].metadata.name}" -n openshift-monitoring)
# Disable the deployment/replicaset/statefulset config for openshift-monitoring namespace
${OC} scale --replicas=0 deployment --all -n openshift-monitoring
# Wait till the cluster-monitoring-operator pod is deleted
${OC} wait --for=delete pod/$cmo_pod --timeout=60s -n openshift-monitoring
# Disable the statefulset for openshift-monitoring namespace
${OC} scale --replicas=0 statefulset --all -n openshift-monitoring

# Delete the pods which are there in Complete state
${OC} delete pods -l 'app in (installer, pruner)' -n openshift-kube-apiserver
${OC} delete pods -l 'app in (installer, pruner)' -n openshift-kube-scheduler
${OC} delete pods -l 'app in (installer, pruner)' -n openshift-kube-controller-manager

# Disable the deployment/replicaset for openshift-machine-api and openshift-machine-config-operator
${OC} scale --replicas=0 deployment --all -n openshift-machine-api
${OC} scale --replicas=0 deployment --all -n openshift-machine-config-operator

# Set replica to 0 for openshift-insights
${OC} scale --replicas=0 deployment --all -n openshift-insights

# Scale route deployment from 2 to 1
${OC} patch --patch='{"spec": {"replicas": 1}}' --type=merge ingresscontroller/default -n openshift-ingress-operator

# Scale console deployment from 2 to 1
${OC} scale --replicas=1 deployment.apps/console -n openshift-console

# Scale console download deployment from 2 to 0
${OC} scale --replicas=0 deployment.apps/downloads -n openshift-console

# Set default route for registry CRD from false to true.
${OC} patch config.imageregistry.operator.openshift.io/cluster --patch '{"spec":{"defaultRoute":true}}' --type=merge

# Set replica for cloud-credential-operator from 1 to 0
${OC} scale --replicas=0 deployment --all -n openshift-cloud-credential-operator

# Add registry storage to pvc
${OC} patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"storage":{"pvc":{"claim":""}}}}'
# Remove emptyDir as storage for registry
${OC} patch config.imageregistry.operator.openshift.io/cluster --patch='[{"op": "remove", "path": "/spec/storage/emptyDir"}]' --type=json

# Delete the v1beta1.metrics.k8s.io apiservice since we are already scale down cluster wide monitioring.
# Since this CRD block namespace deletion forever.
${OC} delete apiservice v1beta1.metrics.k8s.io

# Get the cert pod name
#cert_pod=$(${OC} get pod -l k8s-app=kubelet-bootstrap-cred-manager -o jsonpath="{.items[0].metadata.name}" -n openshift-machine-config-operator)
# Remove the bootstrap-cred-manager daemonset
#${OC} delete daemonset.apps/kubelet-bootstrap-cred-manager -n openshift-machine-config-operator
# Wait till the cert pod is removed
#${OC} wait --for=delete pod/$cert_pod --timeout=120s -n openshift-machine-config-operator
# Remove the cli image which was used for the bootstrap-cred-manager daemonset
#${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- sudo crictl rmi quay.io/openshift/origin-cli:v4.0

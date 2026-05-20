#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ caas-agents setup ************"
echo "E2E_NAMESPACE: ${E2E_NAMESPACE}"
echo "-------------------------------------------"

# Discover the libvirt network cluster-tool created for this clone
echo "Available libvirt networks:"
ssh -F "${SHARED_DIR}/ssh_config" ci_machine "virsh net-list --name" || true
LIBVIRT_NETWORK=$(ssh -F "${SHARED_DIR}/ssh_config" ci_machine \
    "virsh net-list --name | grep \"${CLUSTER_TOOL_FLAVOR_NAME}\"" | head -1 | tr -d '[:space:]')
[[ -z "${LIBVIRT_NETWORK}" ]] && { echo "ERROR: No libvirt network matching '${CLUSTER_TOOL_FLAVOR_NAME}' found"; exit 1; }
echo "Libvirt network: ${LIBVIRT_NETWORK}"

KUBECONFIG_PATH="/root/.kube/${CLUSTER_TOOL_FLAVOR_NAME}.kubeconfig"

# Write the caas-agents setup script to the machine.
# This is a byte-for-byte copy of osac-installer/scripts/setup-caas-agents.sh
# with marked changes for CI adaptation (BEGIN/END CHANGE blocks).
echo "Creating caas-agents script on machine..."
timeout -s 9 1m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash -c 'cat > /root/caas-agents.sh' <<'REMOTE_SCRIPT'
#!/usr/bin/env bash
# Sets up CaaS agent infrastructure: InfraEnv + agent VM + label + approve.
# Runs after setup.sh (MCE + AgentServiceConfig must be ready).
# In CI, runs inside the installer container with SSH access to the bare metal host.

set -o nounset
set -o errexit
set -o pipefail

###### BEGIN CHANGE ########
# Inline retry_until from osac-installer/scripts/lib.sh — the host
# does not have lib.sh, so we embed it here.
retry_until() {
    local timeout="$1"
    local interval="$2"
    local condition="$3"
    local loop_cmd="${4:-}"
    local start=${SECONDS}
    until eval "${condition}"; do
        if (( SECONDS - start >= timeout )); then
            return 1
        fi
        [[ -n "${loop_cmd}" ]] && eval "${loop_cmd}" || true
        sleep "${interval}"
    done
}
###### END CHANGE ########
INSTALLER_NAMESPACE=${INSTALLER_NAMESPACE:-"osac-e2e-ci"}
AGENT_NAMESPACE=${AGENT_NAMESPACE:-"hardware-inventory"}
AGENT_RESOURCE_CLASS=${AGENT_RESOURCE_CLASS:-"ci-worker"}
AGENT_VM_NAME=${AGENT_VM_NAME:-"agent-worker-01"}
AGENT_VM_MEMORY=${AGENT_VM_MEMORY:-"16384"}
AGENT_VM_VCPUS=${AGENT_VM_VCPUS:-"4"}
AGENT_VM_DISK_SIZE=${AGENT_VM_DISK_SIZE:-"120G"}
AGENT_VM_STORAGE_DIR=${AGENT_VM_STORAGE_DIR:-"/data/osac-storage"}
LIBVIRT_NETWORK=${LIBVIRT_NETWORK:?"LIBVIRT_NETWORK must be set"}
###### BEGIN CHANGE ########
# SSH_CONFIG not needed — this script runs directly on the bare metal host.
# In osac-installer, SSH_CONFIG is used to SSH from the CI pod to the host.
###### END CHANGE ########

echo "=== Setting up CaaS agent infrastructure ==="
echo "Agent namespace: ${AGENT_NAMESPACE}"
echo "Resource class: ${AGENT_RESOURCE_CLASS}"
echo ""

NODE_IP=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
echo "Node IP: ${NODE_IP}"
echo "Cluster domain: ${CLUSTER_DOMAIN}"

###### BEGIN CHANGE ########
# Reconfigure MetalLB IPAddressPool for the clone's subnet.
# Each CI clone gets a different subnet; the snapshot has a static pool.
SUBNET_PREFIX=$(echo "${NODE_IP}" | cut -d. -f1-3)
cat <<METALLBEOF | oc apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: caas-address-pool
  namespace: metallb-system
spec:
  addresses:
    - ${SUBNET_PREFIX}.240-${SUBNET_PREFIX}.250
  autoAssign: false
METALLBEOF
echo "MetalLB IPAddressPool configured for ${SUBNET_PREFIX}.240-${SUBNET_PREFIX}.250"
###### END CHANGE ########
echo "[1/6] Registering '${AGENT_RESOURCE_CLASS}' host type in fulfillment service..."
INTERNAL_API="https://$(oc get route fulfillment-internal-api -n "${INSTALLER_NAMESPACE}" -o jsonpath='{.status.ingress[0].host}')"
TOKEN=$(oc create token -n "${INSTALLER_NAMESPACE}" admin)
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -X POST "${INTERNAL_API}/api/private/v1/host_types" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"id\": \"${AGENT_RESOURCE_CLASS}\", \"title\": \"CI Worker\", \"description\": \"Worker nodes for CI testing\"}")
if [[ "${HTTP_CODE}" == "200" || "${HTTP_CODE}" == "201" ]]; then
    echo "  Host type '${AGENT_RESOURCE_CLASS}' created"
elif [[ "${HTTP_CODE}" == "409" ]]; then
    echo "  Host type '${AGENT_RESOURCE_CLASS}' already exists"
else
    echo "  ERROR: Failed to create host type (HTTP ${HTTP_CODE})"
    exit 1
fi

echo "[2/6] Creating agent namespace and CAPI provider role..."
oc create namespace "${AGENT_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

cat <<EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: capi-provider-role
  namespace: ${AGENT_NAMESPACE}
rules:
- apiGroups: ["agent-install.openshift.io"]
  resources: ["agents"]
  verbs: ["*"]
EOF

echo "[3/6] Creating InfraEnv..."

oc get secret pull-secret -n openshift-config -o json \
  | python3 -c "import json,sys; s=json.load(sys.stdin); s['metadata']={'name':'pull-secret','namespace':'${AGENT_NAMESPACE}'}; json.dump(s,sys.stdout)" \
  | oc apply -f -

cat <<EOF | oc apply -f -
apiVersion: agent-install.openshift.io/v1beta1
kind: InfraEnv
metadata:
  name: ${AGENT_NAMESPACE}
  namespace: ${AGENT_NAMESPACE}
spec:
  pullSecretRef:
    name: pull-secret
EOF

echo "Waiting for discovery ISO URL..."
retry_until 300 5 '[[ -n "$(oc get infraenv ${AGENT_NAMESPACE} -n ${AGENT_NAMESPACE} -o jsonpath="{.status.isoDownloadURL}" 2>/dev/null)" ]]' || {
    echo "Timed out waiting for ISO URL"
    exit 1
}
ISO_URL=$(oc get infraenv "${AGENT_NAMESPACE}" -n "${AGENT_NAMESPACE}" -o jsonpath='{.status.isoDownloadURL}')
echo "ISO URL: ${ISO_URL}"

echo "[4/6] Configuring host DNS for ISO download..."
###### BEGIN CHANGE ########
# In osac-installer, the commands below are wrapped in:
#   timeout -s 9 2m ssh -F "${SSH_CONFIG}" ci_machine bash -s \
#       "${NODE_IP}" "${CLUSTER_DOMAIN}" <<'DNSEOF'
# with set -euo pipefail and positional arg assignments.
# Here they run inline since the script executes on the host itself.
# The closing DNSEOF heredoc terminator is also removed.
###### END CHANGE ########
SLUG=$(echo "${CLUSTER_DOMAIN}" | sed 's/[^a-zA-Z0-9]/-/g')
echo "address=/.${CLUSTER_DOMAIN}/${NODE_IP}" > "/etc/dnsmasq.d/${SLUG}.conf"
systemctl restart dnsmasq
echo "  *.${CLUSTER_DOMAIN} -> ${NODE_IP}"

echo "[5/6] Creating agent VM..."
###### BEGIN CHANGE ########
# In osac-installer, the commands below are wrapped in:
#   timeout -s 9 10m ssh -F "${SSH_CONFIG}" ci_machine bash -s <<SSHEOF
# with set -euo pipefail. Here they run inline.
# Also install virt-install which is not pre-installed on the bare metal host.
dnf install -y virt-install
###### END CHANGE ########

mkdir -p ${AGENT_VM_STORAGE_DIR}

###### BEGIN CHANGE ########
# Wait for assisted-image-service to be ready before downloading ISO.
# After snapshot boot the service may return 503 while it initializes.
echo "Waiting for assisted-image-service to be ready..."
for attempt in $(seq 1 30); do
    HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" -L "${ISO_URL}" 2>/dev/null || echo "000")
    [[ "${HTTP_CODE}" == "200" ]] && break
    echo "  attempt ${attempt}/30 - HTTP ${HTTP_CODE}, retrying in 10s..."
    sleep 10
done
[[ "${HTTP_CODE}" != "200" ]] && { echo "ERROR: assisted-image-service not ready after 30 attempts (last HTTP ${HTTP_CODE})"; exit 1; }
###### END CHANGE ########
echo "Downloading discovery ISO..."
###### BEGIN CHANGE ########
# In osac-installer, '${ISO_URL}' is inside an unquoted heredoc (<<SSHEOF)
# where the shell expands ${ISO_URL} at heredoc creation; single quotes are
# literal. Here ${ISO_URL} is a local variable, so double quotes allow
# runtime expansion.
curl -k -L --fail -o ${AGENT_VM_STORAGE_DIR}/discovery.iso "${ISO_URL}"
###### END CHANGE ########

virsh destroy ${AGENT_VM_NAME} 2>/dev/null || true
virsh undefine ${AGENT_VM_NAME} 2>/dev/null || true
rm -f ${AGENT_VM_STORAGE_DIR}/${AGENT_VM_NAME}.qcow2

qemu-img create -f qcow2 ${AGENT_VM_STORAGE_DIR}/${AGENT_VM_NAME}.qcow2 ${AGENT_VM_DISK_SIZE}

virt-install \
  --name ${AGENT_VM_NAME} \
  --memory ${AGENT_VM_MEMORY} \
  --vcpus ${AGENT_VM_VCPUS} \
  --disk ${AGENT_VM_STORAGE_DIR}/${AGENT_VM_NAME}.qcow2 \
  --cdrom ${AGENT_VM_STORAGE_DIR}/discovery.iso \
  --network network=${LIBVIRT_NETWORK} \
  --os-variant rhel9.0 \
  --boot hd,cdrom \
  --noautoconsole

echo "Agent VM created and booting"
###### BEGIN CHANGE ########
# Removed: SSHEOF heredoc terminator (commands run inline on host).
###### END CHANGE ########

echo "[6/6] Waiting for agent to register..."
retry_until 600 10 '[[ $(oc get agent -n ${AGENT_NAMESPACE} --no-headers 2>/dev/null | wc -l) -gt 0 ]]' || {
    echo "Timed out waiting for agent to register"
    exit 1
}

AGENT_NAME=$(oc get agent -n "${AGENT_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}')
echo "Agent registered: ${AGENT_NAME}"

oc label agent/"${AGENT_NAME}" -n "${AGENT_NAMESPACE}" "osac.openshift.io/resource_class=${AGENT_RESOURCE_CLASS}" --overwrite
oc patch agent/"${AGENT_NAME}" -n "${AGENT_NAMESPACE}" --type=merge -p '{"spec":{"approved":true}}'

echo ""
echo "=== CaaS agent setup complete ==="
echo "Agent: ${AGENT_NAME}"
echo "Resource class: ${AGENT_RESOURCE_CLASS}"
echo "Namespace: ${AGENT_NAMESPACE}"
REMOTE_SCRIPT

echo "Executing caas-agents script on machine..."
timeout -s 9 20m ssh -F "${SHARED_DIR}/ssh_config" ci_machine \
    "KUBECONFIG=${KUBECONFIG_PATH} LIBVIRT_NETWORK=${LIBVIRT_NETWORK} INSTALLER_NAMESPACE=${E2E_NAMESPACE} bash /root/caas-agents.sh"

echo "CaaS agent infrastructure ready."

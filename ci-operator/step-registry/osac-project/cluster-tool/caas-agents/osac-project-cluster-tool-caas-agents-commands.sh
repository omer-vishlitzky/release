#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ caas-agents setup ************"
echo "E2E_NAMESPACE: ${E2E_NAMESPACE}"
echo "-------------------------------------------"

CLONE_NAME="ci-test"
AGENT_NAMESPACE="hardware-inventory"
AGENT_VM_NAME="agent-worker-01"
AGENT_VM_STORAGE_DIR="/data/osac-storage"

# Discover the libvirt network cluster-tool created for this clone
echo "Available libvirt networks:"
ssh -F "${SHARED_DIR}/ssh_config" ci_machine "virsh net-list --name" || true
LIBVIRT_NETWORK=$(ssh -F "${SHARED_DIR}/ssh_config" ci_machine \
    "virsh net-list --name | grep \"${CLONE_NAME}\"" | head -1 | tr -d '[:space:]')
[[ -z "${LIBVIRT_NETWORK}" ]] && { echo "ERROR: No libvirt network matching '${CLONE_NAME}' found"; exit 1; }
echo "Libvirt network: ${LIBVIRT_NETWORK}"

# Run agent setup on the bare metal host (oc is already installed from boot step)
timeout -s 9 20m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash -s \
    "${CLONE_NAME}" \
    "${AGENT_NAMESPACE}" \
    "${AGENT_VM_NAME}" \
    "${AGENT_VM_STORAGE_DIR}" \
    "${LIBVIRT_NETWORK}" \
    <<'REMOTE_EOF'
set -euo pipefail

CLONE_NAME="$1"
AGENT_NAMESPACE="$2"
AGENT_VM_NAME="$3"
AGENT_VM_STORAGE_DIR="$4"
LIBVIRT_NETWORK="$5"

export KUBECONFIG="/root/.kube/${CLONE_NAME}.kubeconfig"

# Reconfigure MetalLB IPAddressPool for the clone's subnet
NODE_IP=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
SUBNET_PREFIX=$(echo "${NODE_IP}" | cut -d. -f1-3)
echo "Node IP: ${NODE_IP}, subnet prefix: ${SUBNET_PREFIX}"
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

# Create agent namespace
oc create namespace "${AGENT_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

# Copy pull secret to agent namespace
oc get secret pull-secret -n openshift-config -o json \
    | python3 -c "import json,sys; s=json.load(sys.stdin); s['metadata']={'name':'pull-secret','namespace':'${AGENT_NAMESPACE}'}; json.dump(s,sys.stdout)" \
    | oc apply -f -

# Create InfraEnv
cat <<INFRAEOF | oc apply -f -
apiVersion: agent-install.openshift.io/v1beta1
kind: InfraEnv
metadata:
  name: ${AGENT_NAMESPACE}
  namespace: ${AGENT_NAMESPACE}
spec:
  pullSecretRef:
    name: pull-secret
INFRAEOF

# Wait for ISO URL
echo "Waiting for discovery ISO URL..."
for i in $(seq 1 60); do
    ISO_URL=$(oc get infraenv "${AGENT_NAMESPACE}" -n "${AGENT_NAMESPACE}" -o jsonpath='{.status.isoDownloadURL}' 2>/dev/null)
    [[ -n "${ISO_URL}" ]] && break
    sleep 5
done
[[ -z "${ISO_URL}" ]] && { echo "Timed out waiting for ISO URL"; exit 1; }
echo "ISO URL: ${ISO_URL}"

# Create agent VM
mkdir -p "${AGENT_VM_STORAGE_DIR}"
echo "Downloading discovery ISO..."
curl -k -L --fail -o "${AGENT_VM_STORAGE_DIR}/discovery.iso" "${ISO_URL}"

virsh destroy "${AGENT_VM_NAME}" 2>/dev/null || true
virsh undefine "${AGENT_VM_NAME}" 2>/dev/null || true
rm -f "${AGENT_VM_STORAGE_DIR}/${AGENT_VM_NAME}.qcow2"

qemu-img create -f qcow2 "${AGENT_VM_STORAGE_DIR}/${AGENT_VM_NAME}.qcow2" 120G

virt-install \
    --name "${AGENT_VM_NAME}" \
    --memory 16384 \
    --vcpus 4 \
    --disk "${AGENT_VM_STORAGE_DIR}/${AGENT_VM_NAME}.qcow2" \
    --cdrom "${AGENT_VM_STORAGE_DIR}/discovery.iso" \
    --network network="${LIBVIRT_NETWORK}" \
    --os-variant rhel9.0 \
    --boot hd,cdrom \
    --noautoconsole

echo "Agent VM created, waiting for registration..."
for i in $(seq 1 120); do
    COUNT=$(oc get agent -n "${AGENT_NAMESPACE}" --no-headers 2>/dev/null | wc -l)
    [[ "${COUNT}" -gt 0 ]] && break
    sleep 5
done
[[ "${COUNT}" -eq 0 ]] && { echo "Timed out waiting for agent"; exit 1; }

AGENT_NAME=$(oc get agent -n "${AGENT_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}')
echo "Agent registered: ${AGENT_NAME}"

oc label agent/"${AGENT_NAME}" -n "${AGENT_NAMESPACE}" "osac.openshift.io/resource_class=ci-worker" --overwrite
oc patch agent/"${AGENT_NAME}" -n "${AGENT_NAMESPACE}" --type=merge -p '{"spec":{"approved":true}}'

echo "Agent setup complete: ${AGENT_NAME} (ci-worker)"
REMOTE_EOF

echo "CaaS agent infrastructure ready."

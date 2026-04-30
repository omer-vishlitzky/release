#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ osac-caas-agent-setup commands ************"
echo "--- Running with the following parameters ---"
echo "E2E_NAMESPACE: ${E2E_NAMESPACE}"
echo "OSAC_CLUSTER_TEMPLATE: ${OSAC_CLUSTER_TEMPLATE}"
echo "-------------------------------------------"

timeout -s 9 120m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash -s "${E2E_NAMESPACE}" "${OSAC_CLUSTER_TEMPLATE}" << 'REMOTE_EOF'
set -euo pipefail

E2E_NAMESPACE="$1"
OSAC_CLUSTER_TEMPLATE="$2"

KUBECONFIG=$(find ${KUBECONFIG} -type f -print -quit 2>/dev/null)
[[ -z "${KUBECONFIG}" ]] && echo "ERROR: No kubeconfig found" && exit 1

PULL_SECRET_PATH="/root/pull-secret"

echo "Creating namespace ${E2E_NAMESPACE} if it does not exist..."
oc get namespace "${E2E_NAMESPACE}" 2>/dev/null || oc create namespace "${E2E_NAMESPACE}"

echo "Creating pull-secret in ${E2E_NAMESPACE}..."
oc get secret pull-secret -n "${E2E_NAMESPACE}" 2>/dev/null || \
  oc create secret generic pull-secret --from-file=.dockerconfigjson="${PULL_SECRET_PATH}" --type=kubernetes.io/dockerconfigjson -n "${E2E_NAMESPACE}"

echo "Creating InfraEnv for agent registration..."
cat <<INFRAEOF | oc apply -f -
apiVersion: agent-install.installers.osac.rh/v1beta1
kind: InfraEnv
metadata:
  name: osac-infraenv
  namespace: ${E2E_NAMESPACE}
spec:
  pullSecretRef:
    name: pull-secret
INFRAEOF

echo "Waiting for InfraEnv ISO URL to become available..."
for i in $(seq 1 60); do
  ISO_URL=$(oc get infraenv osac-infraenv -n "${E2E_NAMESPACE}" -o jsonpath='{.status.isoDownloadURL}' 2>/dev/null || true)
  if [[ -n "${ISO_URL}" ]]; then
    echo "ISO URL: ${ISO_URL}"
    break
  fi
  echo "Waiting for ISO URL... (${i}/60)"
  sleep 10
done
[[ -z "${ISO_URL}" ]] && echo "ERROR: ISO URL not available after 10 minutes" && exit 1

echo "Downloading discovery ISO..."
curl -k -L -o /tmp/discovery.iso "${ISO_URL}"

echo "Creating agent VM with virt-install..."
virt-install \
  --name osac-agent \
  --memory 16384 \
  --vcpus 4 \
  --disk size=120 \
  --cdrom /tmp/discovery.iso \
  --os-variant rhel9-unknown \
  --network network=default \
  --noautoconsole \
  --boot hd,cdrom

echo "Waiting for agent to register..."
for i in $(seq 1 120); do
  AGENT_NAME=$(oc get agents -n "${E2E_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "${AGENT_NAME}" ]]; then
    echo "Agent registered: ${AGENT_NAME}"
    break
  fi
  echo "Waiting for agent registration... (${i}/120)"
  sleep 10
done
[[ -z "${AGENT_NAME}" ]] && echo "ERROR: No agent registered after 20 minutes" && exit 1

echo "Labeling agent as worker..."
oc label agent "${AGENT_NAME}" -n "${E2E_NAMESPACE}" agentclassification=worker --overwrite

echo "Approving agent..."
oc patch agent "${AGENT_NAME}" -n "${E2E_NAMESPACE}" --type merge -p '{"spec":{"approved":true}}'

echo "Setting HOSTED_CLUSTER_BASE_DOMAIN..."
INGRESS_DOMAIN=$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')
HOSTED_CLUSTER_BASE_DOMAIN="${INGRESS_DOMAIN#apps.}"
echo "HOSTED_CLUSTER_BASE_DOMAIN: ${HOSTED_CLUSTER_BASE_DOMAIN}"

echo "Agent setup complete"
REMOTE_EOF

echo "CaaS agent setup completed"

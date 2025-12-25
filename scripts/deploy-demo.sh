#!/bin/bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-homelab-test}"
KUBECTL_CMD="kubectl --context=kind-${CLUSTER_NAME}"
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
DEPLOYMENT_NAME="${DEMO_DEPLOYMENT_NAME:-demo}"

echo "Deploying helm..."

# Check if namespace exists and add Helm ownership metadata if missing
if ${KUBECTL_CMD} get namespace "$DEPLOYMENT_NAME" &>/dev/null; then
  echo "Namespace $DEPLOYMENT_NAME already exists, ensuring Helm ownership metadata..."
  ${KUBECTL_CMD} label namespace "$DEPLOYMENT_NAME" app.kubernetes.io/managed-by=Helm --overwrite || true
  ${KUBECTL_CMD} annotate namespace "$DEPLOYMENT_NAME" meta.helm.sh/release-name="$DEPLOYMENT_NAME" --overwrite || true
  ${KUBECTL_CMD} annotate namespace "$DEPLOYMENT_NAME" meta.helm.sh/release-namespace="$DEPLOYMENT_NAME" --overwrite || true
fi

# Install or upgrade the Helm chart
# Note: Namespace is created/updated by the chart template with proper Istio labels
helm upgrade --install "$DEPLOYMENT_NAME" "${REPO_ROOT}/charts/demo" \
  --namespace "$DEPLOYMENT_NAME" \
  --create-namespace
--wait \
  --timeout 5m

sleep 10

echo "Demo deployment completed!"

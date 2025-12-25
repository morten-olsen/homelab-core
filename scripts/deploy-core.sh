#!/bin/bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-homelab-test}"
KUBECTL_CMD="kubectl --context=kind-${CLUSTER_NAME}"
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
REPO_URL="${REPO_URL:-}"
DEPLOYMENT_NAME="${CORE_DEPLOYMENT_NAME:-core}"

# Source utility functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

echo "Deploying helm..."

# If REPO_URL is not set, try to detect it from git remote
if [ -z "$REPO_URL" ]; then
  if git remote get-url origin &>/dev/null; then
    REPO_URL=$(git remote get-url origin)
    echo "Detected repo URL from git remote: $REPO_URL"
  else
    echo "WARNING: No REPO_URL set and no git remote found."
    echo "The bootstrap application may not sync correctly."
    echo "Set REPO_URL environment variable or configure git remote."
  fi
fi

# Deploy using Helm chart (recommended) or direct YAML
echo "Deploying using Helm chart..."

# Install or upgrade the Helm chart
helm upgrade --install "$DEPLOYMENT_NAME" "${REPO_ROOT}/charts/core" \
  --namespace "$DEPLOYMENT_NAME" \
  --create-namespace \
  --wait \
  --timeout 5m

sleep 10

# Wait for cert-manager ArgoCD Application to exist and be synced
wait-for-arg-app cert-manager 600 argocd || exit 1
wait-for-arg-app istiod 600 argocd || exit 1

echo "✓ cert-manager CRDs are available!"
echo "Core deployment completed!"

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

echo "Deploying homelab..."

# Deploy using Helm chart (recommended) or direct YAML
echo "Deploying using Helm chart..."
helm template test "${REPO_ROOT}/charts/homelab" | ${KUBECTL_CMD} apply -f -

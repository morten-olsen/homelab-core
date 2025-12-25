#!/bin/bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-homelab-test}"
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"

echo "Cleaning up Kind cluster: ${CLUSTER_NAME}"

# Stop and remove cloud-provider-kind container if it exists
echo "Stopping cloud-provider-kind container..."
docker stop "cloud-provider-kind-${CLUSTER_NAME}" 2>/dev/null || true
docker rm "cloud-provider-kind-${CLUSTER_NAME}" 2>/dev/null || true

kind delete cluster --name "${CLUSTER_NAME}"

rm -rf "$REPO_ROOT/argo-password.txt"

echo "Cleanup completed!"

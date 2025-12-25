#!/bin/bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-homelab-test}"
KUBECTL_CMD="kubectl --context=kind-${CLUSTER_NAME}"
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
DEPLOYMENT_NAME="${SHARED_DEPLOYMENT_NAME:-shared}"

echo "Deploying helm..."

# Install or upgrade the Helm chart
# Use staging ACME server for e2e tests to avoid rate limits
helm upgrade --install "$DEPLOYMENT_NAME" "${REPO_ROOT}/charts/shared" \
  --namespace "$DEPLOYMENT_NAME" \
  --create-namespace \
  --set acme=stage \
  --wait \
  --timeout 5m

sleep 10

echo "Shared deployment completed!"

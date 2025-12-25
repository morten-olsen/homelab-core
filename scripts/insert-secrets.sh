#!/bin/bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-homelab-test}"
KUBECTL_CMD="kubectl --context=kind-${CLUSTER_NAME}"
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"

${KUBECTL_CMD} apply -f "${REPO_ROOT}/cloudflare-secret.yaml"

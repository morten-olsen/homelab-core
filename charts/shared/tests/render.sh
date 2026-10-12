#!/usr/bin/env bash
set -euo pipefail
chart="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
helm template shared "$chart" --namespace shared \
  --set resources.storageClass.path="$tmp/nvme" \
  --set resources.storageClass.ci.path="$tmp/ci" \
  --set resources.storageClass.ci.filesystemUUID=test-filesystem \
  --show-only templates/storage-class.yaml \
  | yq -o=json -I=0 '.' | jq -s '.' > "$tmp/objects.json"
python3 "$chart/tests/storage_test.py" "$tmp"

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
python3 "$chart/tests/waf_test.py"

helm template shared "$chart" --namespace shared --show-only templates/authentik-groups.yaml > "$tmp/groups.yaml"
yq -o=json -I=0 '.' "$tmp/groups.yaml" > "$tmp/groups.json"
python3 - "$tmp/groups.json" <<'PYTEST'
import json
import sys
x = json.load(open(sys.argv[1]))
assert x['kind'] == 'AuthentikGroup'
assert x['metadata']['name'] == 'admin' and x['metadata']['namespace'] == 'shared'
assert x['spec']['serverRef'] == {'name': 'authentik', 'namespace': 'shared'}
assert x['spec']['members'] == [{'id': 7, 'uuid': 'd8359fc2-7656-45d2-a22e-5cbd13cb941f'}]
assert set(x['spec']) == {'serverRef', 'members'}
print('ok: central admin references only existing morten and exposes no superuser setting')
PYTEST

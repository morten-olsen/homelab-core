#!/usr/bin/env bash
set -euo pipefail
chart="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
python3 "$chart/tests/istio_monitors_test.py"
helm template monitor "$chart" --namespace monitoring --show-only templates/prometheus-rules.yaml \
  | yq '.spec | .groups = [.groups[] | select(.name == "homelab.node")]' > "$tmp/rules.yaml"
cp "$chart/tests/io-pressure.yaml" "$tmp/tests.yaml"
cd "$tmp"
"${PROMTOOL:-promtool}" check rules rules.yaml
"${PROMTOOL:-promtool}" test rules tests.yaml

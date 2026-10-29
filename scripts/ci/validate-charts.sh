#!/usr/bin/env bash
# Check Falco scopes, storage, WAF, scraping and I/O alerts on every PR and push.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if [ -z "${PROMTOOL:-}" ]; then
  # Same version as the live Prometheus. Pin the official amd64 archive.
  curl -fsSL https://github.com/prometheus/prometheus/releases/download/v3.15.0/prometheus-3.15.0.linux-amd64.tar.gz -o "$tmp/prometheus.tar.gz"
  printf '%s  %s\n' 2a542df32eac02ee17b9d844fb2aa1de00dafa5476579ba8a3ba862e9d572ea0 "$tmp/prometheus.tar.gz" | sha256sum --check
  tar -xz -C "$tmp" --strip-components=1 -f "$tmp/prometheus.tar.gz" prometheus-3.15.0.linux-amd64/promtool
  export PROMTOOL="$tmp/promtool"
fi
helm lint "$root/charts/core" "$root/charts/shared" "$root/charts/monitor"
"$root/charts/homelab-common/tests/render.sh"
"$root/charts/core/tests/render.sh"
"$root/charts/shared/tests/render.sh"
"$root/charts/monitor/tests/render.sh"

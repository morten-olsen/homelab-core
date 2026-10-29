#!/usr/bin/env bash
set -euo pipefail
chart="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$chart/tests/oidc_test.py" "$chart"
python3 "$chart/tests/forward_auth_test.py" "$chart"

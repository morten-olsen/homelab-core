#!/usr/bin/env bash
set -euo pipefail
chart="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$chart/tests/falco_exceptions_test.py"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LINK_HELPER_DEFAULTS_FILE="${LINK_HELPER_DEFAULTS_FILE:-$SCRIPT_DIR/../state/link-helper.defaults.real.env}"
exec "$SCRIPT_DIR/link-helper.sh" "$@"

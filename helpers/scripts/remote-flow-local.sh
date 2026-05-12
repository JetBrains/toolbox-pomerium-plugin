#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() {
  printf '[remote-flow-local] %s\n' "$*"
}

run_step() {
  local script_name="$1"
  shift || true
  log "Running ${script_name}"
  "$SCRIPT_DIR/$script_name" "$@"
}

run_step prepare-remote-docker-instance.sh
run_step install-tbcli-remote.sh
run_step write-link-defaults-remote.sh

printf '\n'
log "Remote-flow defaults are ready"
log "Next step: ./link-helper.sh"

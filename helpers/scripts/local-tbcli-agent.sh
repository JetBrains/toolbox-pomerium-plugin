#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$SCRIPT_DIR/../state" ]]; then
  DEFAULT_HELPERS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
else
  DEFAULT_HELPERS_DIR="$(cd "$SCRIPT_DIR/../toolbox/toolbox-pomerium-plugin/helpers" && pwd)"
fi

HELPERS_DIR="${HELPERS_DIR:-$DEFAULT_HELPERS_DIR}"
STATE_DIR="${STATE_DIR:-$HELPERS_DIR/state}"
DEFAULTS_FILE="${LINK_HELPER_DEFAULTS_FILE:-$STATE_DIR/link-helper.defaults.real.env}"
LOCAL_TBCLI_CACHE_DIR="${LOCAL_TBCLI_CACHE_DIR:-$STATE_DIR/.cache}"
TBCLI_VERSION="${TBCLI_VERSION:-3.6.0.84134}"
TBCLI_PLATFORM_SUFFIX="${TBCLI_PLATFORM_SUFFIX:-mac-aarch64}"
LOCAL_TBCLI_DIR="${LOCAL_TBCLI_DIR:-$LOCAL_TBCLI_CACHE_DIR/tbcli-$TBCLI_PLATFORM_SUFFIX-$TBCLI_VERSION}"
LOCAL_TBCLI_PATH="${LOCAL_TBCLI_PATH:-$LOCAL_TBCLI_DIR/bin/tbcli}"
LOCAL_TBCLI_ARCHIVE="${LOCAL_TBCLI_ARCHIVE:-$LOCAL_TBCLI_CACHE_DIR/tbcli-$TBCLI_PLATFORM_SUFFIX-$TBCLI_VERSION.tar.gz}"
TB_JAVA_HOME="${TB_JAVA_HOME:-${JAVA_HOME:-}}"

log() {
  printf '[local-tbcli-agent] %s\n' "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

usage() {
  cat <<EOF
Usage:
  ./local-tbcli-agent.sh install
  ./local-tbcli-agent.sh path
  ./local-tbcli-agent.sh run [--port PORT] [--address ADDRESS]
  ./local-tbcli-agent.sh help

Defaults:
  defaults file: $DEFAULTS_FILE
  local cache:    $LOCAL_TBCLI_CACHE_DIR
  tbcli version:  $TBCLI_VERSION

Examples:
  ./local-tbcli-agent.sh install
  ./local-tbcli-agent.sh path
  ./local-tbcli-agent.sh run
  ./local-tbcli-agent.sh run --port 44000 --address 0.0.0.0
EOF
}

ensure_java() {
  if [[ -n "${TB_JAVA_HOME:-}" ]] && [[ -x "${TB_JAVA_HOME}/bin/java" ]]; then
    export TB_JAVA_HOME
    return
  fi

  if ! command -v java >/dev/null 2>&1; then
    fail "Java was not found. Set TB_JAVA_HOME or install java in PATH."
  fi
}

download_tbcli() {
  if [[ -x "$LOCAL_TBCLI_PATH" ]]; then
    log "tbcli already present at $LOCAL_TBCLI_PATH"
    return
  fi

  mkdir -p "$LOCAL_TBCLI_CACHE_DIR"
  if [[ ! -f "$LOCAL_TBCLI_ARCHIVE" ]]; then
    log "Downloading tbcli $TBCLI_VERSION from JetBrains https://download.jetbrains.com/toolbox/agent/tbcli-$TBCLI_PLATFORM_SUFFIX-$TBCLI_VERSION.tar.gz"
    curl -fsSL "https://download.jetbrains.com/toolbox/agent/tbcli-$TBCLI_PLATFORM_SUFFIX-$TBCLI_VERSION.tar.gz" -o "$LOCAL_TBCLI_ARCHIVE"


  else
    log "Using cached archive $LOCAL_TBCLI_ARCHIVE"
  fi

  rm -rf "$LOCAL_TBCLI_DIR"
  mkdir -p "$LOCAL_TBCLI_DIR"
  tar -xzf "$LOCAL_TBCLI_ARCHIVE" -C "$LOCAL_TBCLI_DIR" --strip-components 1
  log "tbcli extracted to $LOCAL_TBCLI_DIR"
}

defaults_get() {
  local key="$1"
  [[ -f "$DEFAULTS_FILE" ]] || return 0

  python3 - <<'PY' "$DEFAULTS_FILE" "$key"
import pathlib
import shlex
import sys

path = pathlib.Path(sys.argv[1])
target = sys.argv[2]

for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, value = line.split("=", 1)
    if key.strip() != target:
        continue
    value = value.strip()
    if not value:
        print("")
        break
    try:
        print(" ".join(shlex.split(value, posix=True)))
    except ValueError:
        print(value.strip("\"'"))
    break
PY
}

print_path() {
  download_tbcli
  printf '%s\n' "$LOCAL_TBCLI_PATH"
}

run_agent() {
  local listen_port=""
  local listen_address="0.0.0.0"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port)
        [[ $# -ge 2 ]] || fail "--port requires a value"
        listen_port="$2"
        shift 2
        ;;
      --address)
        [[ $# -ge 2 ]] || fail "--address requires a value"
        listen_address="$2"
        shift 2
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
  done

  if [[ -z "$listen_port" ]]; then
    listen_port="$(defaults_get "AGENT_TCP_LISTEN_ON_PORT")"
  fi

  download_tbcli
  ensure_java
  log "agent path: ${LOCAL_TBCLI_PATH}"

  local cmd=("$LOCAL_TBCLI_PATH" "agent")

  if [[ -n "$listen_port" ]]; then
    cmd+=( "--expose-port=$listen_port")
  fi

  log "Running: ${cmd[*]}"
  "${cmd[@]}"
}

case "${1:-help}" in
  install)
    shift
    [[ $# -eq 0 ]] || fail "install does not accept arguments"
    download_tbcli
    ;;
  path)
    shift
    [[ $# -eq 0 ]] || fail "path does not accept arguments"
    print_path
    ;;
  run)
    shift
    run_agent "$@"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

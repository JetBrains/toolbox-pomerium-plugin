#!/usr/bin/env bash
set -euo pipefail

USERNAME="${USERNAME:-dev}"
PASSWORD="${PASSWORD:-dev}"
TBCLI_VERSION="${TBCLI_VERSION:-3.5.0.73530}"
TOOLBOX_HOME="${TOOLBOX_HOME:-/home/$USERNAME}"
TOOLBOX_DATA_DIR="${TOOLBOX_DATA_DIR:-$TOOLBOX_HOME/.local/share/JetBrains/Toolbox}"
TOOLBOX_CACHE_DIR="${TOOLBOX_CACHE_DIR:-$TOOLBOX_HOME/.cache/JetBrains/Toolbox-CLI-dist}"
IDEA_DIST_ROOT="${IDEA_DIST_ROOT:-/opt/idea-dist}"
USE_HOST_TBCLI="${USE_HOST_TBCLI:-1}"
HOST_TBCLI_DIR="${HOST_TBCLI_DIR:-/opt/helpers/host-tbcli}"
TBCLI_DIR="${TBCLI_DIR:-$TOOLBOX_CACHE_DIR/tbcli-$TBCLI_VERSION}"
TB_CLI_PATH="${TB_CLI_PATH:-$TBCLI_DIR/bin/tbcli}"
TB_JAVA_HOME="${TB_JAVA_HOME:-$JAVA_HOME}"
POMERIUM_STACK_MODE="${POMERIUM_STACK_MODE:-real}"
AGENT_LOG="$TOOLBOX_DATA_DIR/agent.log"
TOOLBOX_ENVIRONMENT_FILE="$TOOLBOX_DATA_DIR/environment.json"

log() {
  printf '[helpers-upstream] %s\n' "$*"
}

fail() {
  log "ERROR: $*"
  if [[ -f "$AGENT_LOG" ]]; then
    log "Last agent log lines:"
    tail -n 200 "$AGENT_LOG" || true
  fi
  exit 1
}

resolve_java_home() {
  if [[ -n "${TB_JAVA_HOME:-}" ]] && [[ -x "${TB_JAVA_HOME}/bin/java" ]]; then
    return
  fi

  local java_bin
  java_bin="$(command -v java || true)"
  if [[ -z "$java_bin" ]]; then
    fail "Java was not found. Set TB_JAVA_HOME or install java in PATH."
  fi

  java_bin="$(readlink -f "$java_bin")"
  TB_JAVA_HOME="$(dirname "$(dirname "$java_bin")")"

  if [[ ! -x "${TB_JAVA_HOME}/bin/java" ]]; then
    fail "Resolved TB_JAVA_HOME is invalid: $TB_JAVA_HOME"
  fi
}

mkdir -p "$TOOLBOX_DATA_DIR" "$TOOLBOX_CACHE_DIR"
chown -R "$USERNAME:$USERNAME" "$TOOLBOX_HOME"
echo "$USERNAME:$PASSWORD" | chpasswd

download_tbcli() {
  if [[ -x "$TB_CLI_PATH" ]]; then
    log "tbcli already present at $TB_CLI_PATH"
    return
  fi

  local archive="$TOOLBOX_CACHE_DIR/tbcli-$TBCLI_VERSION.tar.gz"
  log "Downloading tbcli $TBCLI_VERSION from JetBrains"
  curl -fsSL "https://download.jetbrains.com/toolbox/cli/tbcli-$TBCLI_VERSION.tar.gz" -o "$archive"
  rm -rf "$TBCLI_DIR"
  mkdir -p "$TBCLI_DIR"
  tar -xzf "$archive" -C "$TBCLI_DIR" --strip-components 1
  chown -R "$USERNAME:$USERNAME" "$TOOLBOX_CACHE_DIR"
  log "tbcli extracted to $TBCLI_DIR"
}

resolve_tbcli() {
  if [[ "$USE_HOST_TBCLI" == "1" ]]; then
    TBCLI_DIR="$HOST_TBCLI_DIR"
    TB_CLI_PATH="$TBCLI_DIR/bin/tbcli"
    [[ -x "$TB_CLI_PATH" ]] || fail "host-mounted tbcli was requested but not found at $TB_CLI_PATH"
    log "Using host-mounted tbcli at $TB_CLI_PATH"
    return
  fi

  download_tbcli
}

configure_toolbox_environment() {
  [[ -d "$IDEA_DIST_ROOT" ]] || fail "IDEA_DIST_ROOT does not exist: $IDEA_DIST_ROOT"

  python3 - <<'PY' "$TOOLBOX_ENVIRONMENT_FILE" "$IDEA_DIST_ROOT"
import json
import pathlib
import sys

environment_path = pathlib.Path(sys.argv[1])
additional_path = pathlib.Path(sys.argv[2])

payload = {
    "tools": {
        "location": [
            {"path": str(additional_path)}
        ]
    }
}

environment_path.parent.mkdir(parents=True, exist_ok=True)
environment_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY

  chown "$USERNAME:$USERNAME" "$TOOLBOX_ENVIRONMENT_FILE"
  log "Configured Toolbox additional tool path via $TOOLBOX_ENVIRONMENT_FILE -> $IDEA_DIST_ROOT"
}

log "Preparing container for user $USERNAME"
resolve_tbcli
configure_toolbox_environment
resolve_java_home
export TB_CLI_PATH TBCLI_DIR TB_JAVA_HOME USE_HOST_TBCLI HOST_TBCLI_DIR IDEA_DIST_ROOT TOOLBOX_ENVIRONMENT_FILE
log "Using TB_JAVA_HOME=$TB_JAVA_HOME"
log "Starting sshd on port 22"
/usr/sbin/sshd
python3 /opt/helpers/docker/watch_port.py &
POMERIUM_STACK_MODE="$POMERIUM_STACK_MODE" /opt/helpers/docker/agent-stack.sh start || fail "Agent stack startup failed"

log "Streaming Toolbox Agent log"
tail -F "$AGENT_LOG"

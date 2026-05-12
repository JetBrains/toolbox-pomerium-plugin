#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_INSTANCE_CONFIG_FILE="${REMOTE_INSTANCE_CONFIG_FILE:-$SCRIPT_DIR/../state/remote-instance.env}"

log_remote_common() {
  printf '[remote-common] %s\n' "$*"
}

fail_remote_common() {
  log_remote_common "ERROR: $*"
  exit 1
}

require_remote_config() {
  [[ -f "$REMOTE_INSTANCE_CONFIG_FILE" ]] || fail_remote_common "remote config not found: $REMOTE_INSTANCE_CONFIG_FILE"
  # shellcheck disable=SC1090
  source "$REMOTE_INSTANCE_CONFIG_FILE"

  : "${SSH_HOST:?SSH_HOST is required in $REMOTE_INSTANCE_CONFIG_FILE}"
  : "${SSH_USER:?SSH_USER is required in $REMOTE_INSTANCE_CONFIG_FILE}"

  SSH_PORT="${SSH_PORT:-22}"
  REMOTE_TOOLBOX_HOME="${REMOTE_TOOLBOX_HOME:-/home/$SSH_USER}"
  REMOTE_TOOLBOX_DATA_DIR="${REMOTE_TOOLBOX_DATA_DIR:-$REMOTE_TOOLBOX_HOME/.local/share/JetBrains/Toolbox}"
  REMOTE_TOOLBOX_CACHE_DIR="${REMOTE_TOOLBOX_CACHE_DIR:-$REMOTE_TOOLBOX_HOME/.cache/JetBrains/Toolbox-CLI-dist}"
  TBCLI_VERSION="${TBCLI_VERSION:-3.5.0.73530}"
  REMOTE_TBCLI_DIR="${REMOTE_TBCLI_DIR:-$REMOTE_TOOLBOX_CACHE_DIR/tbcli-$TBCLI_VERSION}"
  REMOTE_TBCLI_PATH="${REMOTE_TBCLI_PATH:-$REMOTE_TBCLI_DIR/bin/tbcli}"
  REMOTE_JOIN_LINK_COMMAND="${REMOTE_JOIN_LINK_COMMAND:-}"
  REMOTE_IDEA_LOG_ROOTS="${REMOTE_IDEA_LOG_ROOTS:-/home/$SSH_USER/.local/share/JetBrains/Toolbox/apps/intellij-idea:/home/$SSH_USER/.cache/JetBrains:/home/$SSH_USER:/root:/opt}"
  TB_JAVA_HOME="${TB_JAVA_HOME:-}"
  SSH_KEY_PATH="${SSH_KEY_PATH:-}"
  REMOTE_HAS_INTERNET="${REMOTE_HAS_INTERNET:-yes}"
  LOCAL_TBCLI_ARCHIVE_PATH="${LOCAL_TBCLI_ARCHIVE_PATH:-}"
  LOCAL_TBCLI_CACHE_DIR="${LOCAL_TBCLI_CACHE_DIR:-$SCRIPT_DIR/../state/.cache}"
}

ssh_base() {
  local args=(
    ssh
    -p "$SSH_PORT"
    -o BatchMode=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
  )
  if [[ -n "${SSH_KEY_PATH:-}" ]]; then
    args+=(-i "$SSH_KEY_PATH")
  fi
  args+=("$SSH_USER@$SSH_HOST")
  printf '%q ' "${args[@]}"
}

ssh_run() {
  require_remote_config
  local args=(
    ssh
    -p "$SSH_PORT"
    -o BatchMode=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
  )
  if [[ -n "${SSH_KEY_PATH:-}" ]]; then
    args+=(-i "$SSH_KEY_PATH")
  fi
  args+=("$SSH_USER@$SSH_HOST" "$@")
  "${args[@]}"
}

ssh_bash_script() {
  require_remote_config
  local script_content="$1"
  local args=(
    ssh
    -p "$SSH_PORT"
    -o BatchMode=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
  )
  if [[ -n "${SSH_KEY_PATH:-}" ]]; then
    args+=(-i "$SSH_KEY_PATH")
  fi
  args+=("$SSH_USER@$SSH_HOST" "bash -s")
  printf '%s\n' "$script_content" | "${args[@]}"
}

scp_to_remote() {
  require_remote_config
  local source_path="$1"
  local target_path="$2"
  local args=(
    scp
    -P "$SSH_PORT"
    -o BatchMode=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
  )
  if [[ -n "${SSH_KEY_PATH:-}" ]]; then
    args+=(-i "$SSH_KEY_PATH")
  fi
  args+=("$source_path" "$SSH_USER@$SSH_HOST:$target_path")
  "${args[@]}"
}

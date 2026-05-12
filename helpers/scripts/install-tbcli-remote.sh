#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/remote-common.sh"

log() {
  printf '[install-tbcli-remote] %s\n' "$*"
}

require_remote_config

prepare_local_archive() {
  local archive_path="${LOCAL_TBCLI_ARCHIVE_PATH:-}"
  if [[ -n "$archive_path" ]]; then
    [[ -f "$archive_path" ]] || {
      printf '[install-tbcli-remote] ERROR: local tbcli archive not found: %s\n' "$archive_path" >&2
      exit 1
    }
    printf '%s\n' "$archive_path"
    return
  fi

  mkdir -p "$LOCAL_TBCLI_CACHE_DIR"
  archive_path="$LOCAL_TBCLI_CACHE_DIR/tbcli-$TBCLI_VERSION.tar.gz"
  if [[ ! -f "$archive_path" ]]; then
    log "Downloading tbcli locally because remote internet is disabled"
    curl -fsSL "https://download.jetbrains.com/toolbox/cli/tbcli-$TBCLI_VERSION.tar.gz" -o "$archive_path"
  fi
  printf '%s\n' "$archive_path"
}

log "Installing tbcli on ${SSH_USER}@${SSH_HOST}:${SSH_PORT}"
if [[ "$REMOTE_HAS_INTERNET" != "yes" ]]; then
  local_archive="$(prepare_local_archive)"
  log "Uploading tbcli archive to remote host"
  ssh_run mkdir -p "$REMOTE_TOOLBOX_CACHE_DIR"
  scp_to_remote "$local_archive" "$REMOTE_TOOLBOX_CACHE_DIR/tbcli-$TBCLI_VERSION.tar.gz"
fi

remote_script="$(cat <<EOF
set -euo pipefail

REMOTE_TOOLBOX_HOME=$(python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$REMOTE_TOOLBOX_HOME")
REMOTE_TOOLBOX_DATA_DIR=$(python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$REMOTE_TOOLBOX_DATA_DIR")
REMOTE_TOOLBOX_CACHE_DIR=$(python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$REMOTE_TOOLBOX_CACHE_DIR")
TBCLI_VERSION=$(python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$TBCLI_VERSION")
REMOTE_TBCLI_DIR=$(python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$REMOTE_TBCLI_DIR")
REMOTE_TBCLI_PATH=$(python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$REMOTE_TBCLI_PATH")
TB_JAVA_HOME=$(python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$TB_JAVA_HOME")
REMOTE_HAS_INTERNET=$(python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$REMOTE_HAS_INTERNET")

mkdir -p "\$REMOTE_TOOLBOX_DATA_DIR" "\$REMOTE_TOOLBOX_CACHE_DIR"

if [[ ! -x "\$REMOTE_TBCLI_PATH" ]]; then
  archive="\$REMOTE_TOOLBOX_CACHE_DIR/tbcli-\$TBCLI_VERSION.tar.gz"
  if [[ "\$REMOTE_HAS_INTERNET" == "yes" ]]; then
    curl -fsSL "https://download.jetbrains.com/toolbox/cli/tbcli-\$TBCLI_VERSION.tar.gz" -o "\$archive"
  elif [[ ! -f "\$archive" ]]; then
    echo "remote internet is disabled and archive is missing: \$archive" >&2
    exit 1
  fi
  rm -rf "\$REMOTE_TBCLI_DIR"
  mkdir -p "\$REMOTE_TBCLI_DIR"
  tar -xzf "\$archive" -C "\$REMOTE_TBCLI_DIR" --strip-components 1
fi

if [[ -n "\$TB_JAVA_HOME" ]]; then
  export TB_JAVA_HOME
fi

if ! command -v java >/dev/null 2>&1 && [[ -z "\${TB_JAVA_HOME:-}" ]]; then
  echo "java is not available and TB_JAVA_HOME is empty" >&2
  exit 1
fi

"\$REMOTE_TBCLI_PATH" --version
EOF
)"
ssh_bash_script "$remote_script"

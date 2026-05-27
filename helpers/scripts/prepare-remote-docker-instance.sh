#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REMOTE_ENV_FILE="${REMOTE_INSTANCE_CONFIG_FILE:-$SCRIPT_DIR/../state/remote-instance.env}"
REMOTE_COMPOSE_FILE="${REMOTE_TEST_COMPOSE_FILE:-}"
REMOTE_KEY_PATH="${REMOTE_TEST_KEY_PATH:-}"

log() {
  printf '[prepare-remote-docker-instance] %s\n' "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

[[ -n "$REMOTE_COMPOSE_FILE" ]] || fail "REMOTE_TEST_COMPOSE_FILE is not set. Point it to the temporary toolbox-agent compose file if you want to use this test helper."
[[ -n "$REMOTE_KEY_PATH" ]] || fail "REMOTE_TEST_KEY_PATH is not set. Point it to the temporary SSH key if you want to use this test helper."
[[ -f "$REMOTE_COMPOSE_FILE" ]] || fail "compose file not found: $REMOTE_COMPOSE_FILE"
[[ -f "$REMOTE_KEY_PATH" ]] || fail "SSH key not found: $REMOTE_KEY_PATH"

chmod 600 "$REMOTE_KEY_PATH"

log "Starting toolbox-agent test container"
docker compose -f "$REMOTE_COMPOSE_FILE" up -d toolbox-agent

cat >"$REMOTE_ENV_FILE" <<EOF
SSH_HOST='127.0.0.1'
SSH_PORT='2200'
SSH_USER='dev'
SSH_KEY_PATH='$REMOTE_KEY_PATH'

REMOTE_TOOLBOX_HOME='/home/dev'
REMOTE_TOOLBOX_DATA_DIR='/home/dev/.local/share/JetBrains/Toolbox'
REMOTE_TOOLBOX_CACHE_DIR='/home/dev/.cache/JetBrains/Toolbox-CLI-dist'

TBCLI_VERSION='3.6.0.84134'
TB_JAVA_HOME=''

REMOTE_JOIN_LINK_COMMAND=''
REMOTE_IDEA_LOG_ROOTS='/home/dev/.local/share/JetBrains/Toolbox/apps/intellij-idea:/home/dev/.cache/JetBrains:/home/dev:/root:/opt'
EOF

log "Wrote remote config to $REMOTE_ENV_FILE"
printf '\n'
printf 'Next steps:\n'
printf '  cd %s\n' "$SCRIPT_DIR"
printf '  ./install-tbcli-remote.sh\n'
printf '  ./write-link-defaults-remote.sh\n'

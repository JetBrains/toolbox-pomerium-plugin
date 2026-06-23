#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULTS_FILE="${1:-$SCRIPT_DIR/../state/link-helper.defaults.real.env}"
MANAGE_LOCAL_ENV_FILE="${MANAGE_LOCAL_ENV_FILE:-$SCRIPT_DIR/../state/manage.local.env}"
DEV_LOCAL_ENV_FILE="${DEV_LOCAL_ENV_FILE:-$SCRIPT_DIR/../state/dev.local.env}"
TOOLBOX_DEV_ENV_FILE="${TOOLBOX_DEV_ENV_FILE:-$SCRIPT_DIR/../state/toolbox-dev.local.env}"
LOCAL_IDEA_ENV_FILE="${LOCAL_IDEA_ENV_FILE:-$SCRIPT_DIR/../state/local-idea.local.env}"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/remote-common.sh"

if [[ -f "$MANAGE_LOCAL_ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$MANAGE_LOCAL_ENV_FILE"
fi
if [[ -f "$DEV_LOCAL_ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$DEV_LOCAL_ENV_FILE"
fi
if [[ -f "$TOOLBOX_DEV_ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$TOOLBOX_DEV_ENV_FILE"
fi
if [[ -f "$LOCAL_IDEA_ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$LOCAL_IDEA_ENV_FILE"
fi

log() {
  printf '[write-link-defaults-remote] %s\n' "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

quote_shell() {
  python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$1"
}

defaults_get() {
  local defaults_input="$1"
  local key="$2"
  python3 - <<'PY' "$key"
import shlex
import sys

key = sys.argv[1]
for raw_line in sys.stdin.read().splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    current_key, value = line.split("=", 1)
    current_key = current_key.strip()
    if current_key != key:
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
else:
    print("")
PY
<<<"$defaults_input"
}

normalize_backend_route() {
  local route="$1"
  python3 - <<'PY' "$route"
import sys
from urllib.parse import urlparse, urlunparse

route = sys.argv[1]
if not route:
    print(route)
    raise SystemExit(0)

parsed = urlparse(route)
if parsed.hostname == "backend.localhost" and parsed.port == 443 and parsed.scheme in {"tcp", "https"}:
    parsed = parsed._replace(scheme="https", netloc="backend.localhost:443")
    print(urlunparse(parsed))
else:
    print(route)
PY
}

normalize_connection_key() {
  local connection_key="$1"
  local target_build="$2"
  python3 - <<'PY' "$connection_key" "$target_build"
import sys
from urllib.parse import parse_qsl, urlencode, urlparse, urlunparse

connection_key = sys.argv[1]
target_build = sys.argv[2]

prefix, sep, fragment = connection_key.partition("#")
parsed_prefix = urlparse(prefix)
if parsed_prefix.hostname in {"0.0.0.0", "backend.localhost"} and parsed_prefix.port == 5990:
    prefix = urlunparse(parsed_prefix._replace(scheme="https", netloc="backend.localhost:5990"))

if not sep:
    print(prefix)
    raise SystemExit(0)

pairs = parse_qsl(fragment, keep_blank_values=True)
updated = False
normalized = []
for key, value in pairs:
    if key == "cb":
        normalized.append((key, target_build))
        updated = True
    else:
        normalized.append((key, value))

if not updated:
    normalized.append(("cb", target_build))

print(prefix + "#" + urlencode(normalized))
PY
}

parse_link_field() {
  local link="$1"
  local field="$2"
  python3 - <<'PY' "$link" "$field"
import sys
import urllib.parse

parsed = urllib.parse.urlparse(sys.argv[1])
field = sys.argv[2]
value = ""
for chunk in parsed.fragment.split("&"):
    if "=" not in chunk:
        continue
    key, raw_value = chunk.split("=", 1)
    if key == field:
        value = urllib.parse.unquote(raw_value)
        break
print(value)
PY
}

json_get() {
  local json_input="$1"
  local key="$2"
  python3 -c 'import json,sys; data=json.load(sys.stdin); value=data
for part in sys.argv[1].split("."):
    value=value[part]
print(value if not isinstance(value, (dict,list)) else json.dumps(value, ensure_ascii=False))' "$key" <<<"$json_input"
}

require_remote_config

[[ -x "$SCRIPT_DIR/install-tbcli-remote.sh" ]] || fail "install-tbcli-remote.sh not found or not executable"

existing_defaults="$(cat "$DEFAULTS_FILE" 2>/dev/null || true)"

CLIENT_POMERIUM_ROUTE="https://backend.localhost:443"
POMERIUM_PORT="443"
POMERIUM_INSTANCE=""
DISPLAY_NAME=""
PROJECT_PATH="${PROJECT_PATH:-${CONTAINER_PROJECT_DIR:-}}"
TOOLBOX_MODE="${TOOLBOX_MODE:-toolbox}"
AGENT_POMERIUM_ROUTE="https://agent.localhost:443"
TARGET_CONNECTION_BUILD="${CONNECTION_KEY_BUILD:-261.24374.151}"
CONNECTION_KEY="https://backend.localhost:5990#jt=ca7cd969-f4dc-4d58-bdad-3ab4f3f9e8d6&p=IU&fp=E80F9EA7A46A357ED269F7F9F7E628F0A70BB6251A69E96F86DB658A96029140&cb=${TARGET_CONNECTION_BUILD}&newUi=true&jb=21.0.10b1163.110"
AGENT_AUTH=""
AGENT_TCP_LISTEN_ON_PORT="44000"
BACKEND_FORWARD_PORT=""
if [[ -n "$existing_defaults" ]]; then
  CLIENT_POMERIUM_ROUTE="$(defaults_get "$existing_defaults" "CLIENT_POMERIUM_ROUTE" 2>/dev/null || printf '%s\n' "$CLIENT_POMERIUM_ROUTE")"
  POMERIUM_PORT="$(defaults_get "$existing_defaults" "POMERIUM_PORT" 2>/dev/null || printf '%s\n' "$POMERIUM_PORT")"
  POMERIUM_INSTANCE="$(defaults_get "$existing_defaults" "POMERIUM_INSTANCE" 2>/dev/null || printf '%s\n' "$POMERIUM_INSTANCE")"
  DISPLAY_NAME="$(defaults_get "$existing_defaults" "DISPLAY_NAME" 2>/dev/null || printf '%s\n' "$DISPLAY_NAME")"
  PROJECT_PATH="$(defaults_get "$existing_defaults" "PROJECT_PATH" 2>/dev/null || printf '%s\n' "$PROJECT_PATH")"
  TOOLBOX_MODE="$(defaults_get "$existing_defaults" "TOOLBOX_MODE" 2>/dev/null || printf '%s\n' "$TOOLBOX_MODE")"
  AGENT_POMERIUM_ROUTE="$(defaults_get "$existing_defaults" "AGENT_POMERIUM_ROUTE" 2>/dev/null || printf '%s\n' "$AGENT_POMERIUM_ROUTE")"
  CONNECTION_KEY="$(defaults_get "$existing_defaults" "CONNECTION_KEY" 2>/dev/null || printf '%s\n' "$CONNECTION_KEY")"
  AGENT_AUTH="$(defaults_get "$existing_defaults" "AGENT_AUTH" 2>/dev/null || printf '%s\n' "$AGENT_AUTH")"
  AGENT_TCP_LISTEN_ON_PORT="$(defaults_get "$existing_defaults" "AGENT_TCP_LISTEN_ON_PORT" 2>/dev/null || printf '%s\n' "$AGENT_TCP_LISTEN_ON_PORT")"
  BACKEND_FORWARD_PORT="$(defaults_get "$existing_defaults" "BACKEND_FORWARD_PORT" 2>/dev/null || printf '%s\n' "$BACKEND_FORWARD_PORT")"
fi

if [[ "$TOOLBOX_MODE" == "toolbox" && -z "$BACKEND_FORWARD_PORT" ]]; then
  BACKEND_FORWARD_PORT="5990"
fi

[[ -n "$CLIENT_POMERIUM_ROUTE" ]] || CLIENT_POMERIUM_ROUTE="https://backend.localhost:443"
[[ -n "$POMERIUM_PORT" ]] || POMERIUM_PORT="443"
[[ -n "$AGENT_POMERIUM_ROUTE" ]] || DISPLAY_NAME=""
AGENT_POMERIUM_ROUTE="https://agent.localhost:443"
CLIENT_POMERIUM_ROUTE="$(normalize_backend_route "$CLIENT_POMERIUM_ROUTE")"
[[ -n "$CONNECTION_KEY" ]] || CONNECTION_KEY="https://backend.localhost:5990#jt=ca7cd969-f4dc-4d58-bdad-3ab4f3f9e8d6&p=IU&fp=E80F9EA7A46A357ED269F7F9F7E628F0A70BB6251A69E96F86DB658A96029140&cb=${TARGET_CONNECTION_BUILD}&newUi=true&jb=21.0.10b1163.110"
CONNECTION_KEY="$(normalize_connection_key "$CONNECTION_KEY" "$TARGET_CONNECTION_BUILD")"
log "Ensuring tbcli is installed on remote host"
"$SCRIPT_DIR/install-tbcli-remote.sh"

log "Restarting remote tbcli agent"
remote_start_script=$(cat <<EOF
set -euo pipefail
REMOTE_TOOLBOX_DATA_DIR=$(quote_shell "$REMOTE_TOOLBOX_DATA_DIR")
REMOTE_TBCLI_PATH=$(quote_shell "$REMOTE_TBCLI_PATH")
TB_JAVA_HOME=$(quote_shell "$TB_JAVA_HOME")
AGENT_TCP_LISTEN_ON_PORT=$(quote_shell "$AGENT_TCP_LISTEN_ON_PORT")

mkdir -p "$REMOTE_TOOLBOX_DATA_DIR"
: > "$REMOTE_TOOLBOX_DATA_DIR/agent.log"
pkill -f 'com.jetbrains.toolbox.MainKt agent' 2>/dev/null || true
pkill -f "$REMOTE_TBCLI_PATH" 2>/dev/null || true
for _ in \$(seq 1 20); do
  if ! pgrep -f 'com.jetbrains.toolbox.MainKt agent' >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

if [[ -n "$TB_JAVA_HOME" ]]; then
  export TB_JAVA_HOME
fi

if [[ -n "$AGENT_TCP_LISTEN_ON_PORT" ]]; then
  nohup "$REMOTE_TBCLI_PATH" agent --address 0.0.0.0 --port "$AGENT_TCP_LISTEN_ON_PORT" >> "$REMOTE_TOOLBOX_DATA_DIR/agent.log" 2>&1 < /dev/null &
else
  nohup "$REMOTE_TBCLI_PATH" agent >> "$REMOTE_TOOLBOX_DATA_DIR/agent.log" 2>&1 < /dev/null &
fi
EOF
)
ssh_bash_script "$remote_start_script"

log "Waiting for remote ~RESULT"
remote_wait_script=$(cat <<EOF
set -euo pipefail
REMOTE_TOOLBOX_DATA_DIR=$(quote_shell "$REMOTE_TOOLBOX_DATA_DIR")
for _ in \$(seq 1 120); do
  if grep -q '~RESULT:' "$REMOTE_TOOLBOX_DATA_DIR/agent.log" 2>/dev/null; then
    exit 0
  fi
  sleep 0.5
done
exit 1
EOF
)
ssh_bash_script "$remote_wait_script" || fail "remote agent did not emit ~RESULT"

log "Reading remote agent metadata"
remote_json_script=$(cat <<EOF
set -euo pipefail
REMOTE_TOOLBOX_DATA_DIR=$(quote_shell "$REMOTE_TOOLBOX_DATA_DIR")
tr -d '\000' < "$REMOTE_TOOLBOX_DATA_DIR/agent.log" \
  | grep -a -o '~RESULT:[[:space:]]*{.*}' \
  | tail -n 1 \
  | sed 's/^~RESULT:[[:space:]]*//'
EOF
)
json_output="$(ssh_bash_script "$remote_json_script" 2>/dev/null || true)"
[[ -n "$json_output" ]] || fail "failed to read remote agent metadata"

AGENT_AUTH="$(json_get "$json_output" "authToken" 2>/dev/null || printf '%s\n' "$AGENT_AUTH")"

log "Reading remote join link"
remote_link=""
if [[ -n "$REMOTE_JOIN_LINK_COMMAND" ]]; then
  remote_link="$(ssh_run bash -lc "$REMOTE_JOIN_LINK_COMMAND" 2>/dev/null || true)"
else
  remote_link_script=$(cat <<EOF
set -euo pipefail
REMOTE_IDEA_LOG_ROOTS=$(quote_shell "$REMOTE_IDEA_LOG_ROOTS")
tmp_file=\$(mktemp)
trap 'rm -f "\$tmp_file"' EXIT
IFS=':' read -r -a roots <<< "$REMOTE_IDEA_LOG_ROOTS"
for root in "\${roots[@]}"; do
  [[ -d "\$root" ]] || continue
  find "\$root" -type f -name idea.log -print >> "\$tmp_file" 2>/dev/null || true
done
[[ -s "\$tmp_file" ]] || exit 1

while IFS= read -r log_path; do
  grep -E 'New connection link received:|Join link:' "\$log_path" 2>/dev/null || true
done < <(xargs ls -1t < "\$tmp_file" 2>/dev/null || cat "\$tmp_file") \
  | tail -n 1 \
  | sed -E 's/^.*(New connection link received:|Join link:)[[:space:]]*//'
EOF
)
  remote_link="$(ssh_bash_script "$remote_link_script" 2>/dev/null || true)"
fi

if [[ -n "$remote_link" ]]; then
  CONNECTION_KEY="$remote_link"
fi

generated_link="jetbrains://remote-dev/jetbrains.toolbox.pomerium/new-environment#clientPomeriumRoute=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$CLIENT_POMERIUM_ROUTE")&connectionKey=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$CONNECTION_KEY")&pomeriumPort=$POMERIUM_PORT"
if [[ -n "$POMERIUM_INSTANCE" ]]; then
  generated_link="${generated_link}&pomeriumInstance=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$POMERIUM_INSTANCE")"
fi
if [[ -n "$DISPLAY_NAME" ]]; then
  generated_link="${generated_link}&displayName=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$DISPLAY_NAME")"
fi
if [[ -n "$PROJECT_PATH" ]]; then
  generated_link="${generated_link}&projectPath=$PROJECT_PATH"
fi
generated_link="${generated_link}&agentPomeriumRoute=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$AGENT_POMERIUM_ROUTE")&agentAuth=$AGENT_AUTH"

CLIENT_POMERIUM_ROUTE="$(parse_link_field "$generated_link" "clientPomeriumRoute" 2>/dev/null || printf '%s\n' "$CLIENT_POMERIUM_ROUTE")"
POMERIUM_PORT="$(parse_link_field "$generated_link" "pomeriumPort" 2>/dev/null || printf '%s\n' "$POMERIUM_PORT")"
POMERIUM_INSTANCE="$(parse_link_field "$generated_link" "pomeriumInstance" 2>/dev/null || printf '%s\n' "$POMERIUM_INSTANCE")"
DISPLAY_NAME="$(parse_link_field "$generated_link" "displayName" 2>/dev/null || printf '%s\n' "$DISPLAY_NAME")"
PROJECT_PATH="$(parse_link_field "$generated_link" "projectPath" 2>/dev/null || printf '%s\n' "$PROJECT_PATH")"
AGENT_POMERIUM_ROUTE="$(parse_link_field "$generated_link" "agentPomeriumRoute" 2>/dev/null || printf '%s\n' "$AGENT_POMERIUM_ROUTE")"
CONNECTION_KEY="$(parse_link_field "$generated_link" "connectionKey" 2>/dev/null || printf '%s\n' "$CONNECTION_KEY")"
AGENT_AUTH="$(parse_link_field "$generated_link" "agentAuth" 2>/dev/null || printf '%s\n' "$AGENT_AUTH")"

cat >"$DEFAULTS_FILE" <<EOF
TOOLBOX_MODE=$(quote_shell "$TOOLBOX_MODE")
CLIENT_POMERIUM_ROUTE=$(quote_shell "$CLIENT_POMERIUM_ROUTE")
POMERIUM_PORT=$(quote_shell "$POMERIUM_PORT")
POMERIUM_INSTANCE=$(quote_shell "$POMERIUM_INSTANCE")
DISPLAY_NAME=$(quote_shell "$DISPLAY_NAME")
PROJECT_PATH=$(quote_shell "$PROJECT_PATH")
AGENT_POMERIUM_ROUTE=$(quote_shell "$AGENT_POMERIUM_ROUTE")
CONNECTION_KEY=$(quote_shell "$CONNECTION_KEY")
AGENT_AUTH=$(quote_shell "$AGENT_AUTH")
AGENT_TCP_LISTEN_ON_PORT=$(quote_shell "$AGENT_TCP_LISTEN_ON_PORT")
BACKEND_FORWARD_PORT=$(quote_shell "$BACKEND_FORWARD_PORT")
EOF

log "Wrote defaults to $DEFAULTS_FILE"
printf '%s\n' "$generated_link"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULTS_FILE="${1:-$SCRIPT_DIR/../state/link-helper.defaults.real.env}"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/remote-common.sh"

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

POMERIUM_ROUTE="tcp+https://agent.localhost:443"
POMERIUM_PORT="443"
POMERIUM_INSTANCE=""
AGENT_CONNECTION_URL="https://agent.localhost:443"
CONNECTION_KEY="tcp://0.0.0.0:5990#jt=ca7cd969-f4dc-4d58-bdad-3ab4f3f9e8d6&p=IU&fp=E80F9EA7A46A357ED269F7F9F7E628F0A70BB6251A69E96F86DB658A96029140&cb=253.32098.37&newUi=true&jb=21.0.10b1163.110"
AGENT_AUTH=""
AGENT_TCP_LISTEN_ON_PORT=""
BACKEND_FORWARD_PORT="5990"

if [[ -n "$existing_defaults" ]]; then
  POMERIUM_ROUTE="$(defaults_get "$existing_defaults" "POMERIUM_ROUTE" 2>/dev/null || printf '%s\n' "$POMERIUM_ROUTE")"
  POMERIUM_PORT="$(defaults_get "$existing_defaults" "POMERIUM_PORT" 2>/dev/null || printf '%s\n' "$POMERIUM_PORT")"
  POMERIUM_INSTANCE="$(defaults_get "$existing_defaults" "POMERIUM_INSTANCE" 2>/dev/null || printf '%s\n' "$POMERIUM_INSTANCE")"
  AGENT_CONNECTION_URL="$(defaults_get "$existing_defaults" "AGENT_CONNECTION_URL" 2>/dev/null || printf '%s\n' "$AGENT_CONNECTION_URL")"
  CONNECTION_KEY="$(defaults_get "$existing_defaults" "CONNECTION_KEY" 2>/dev/null || printf '%s\n' "$CONNECTION_KEY")"
  AGENT_AUTH="$(defaults_get "$existing_defaults" "AGENT_AUTH" 2>/dev/null || printf '%s\n' "$AGENT_AUTH")"
  AGENT_TCP_LISTEN_ON_PORT="$(defaults_get "$existing_defaults" "AGENT_TCP_LISTEN_ON_PORT" 2>/dev/null || printf '%s\n' "$AGENT_TCP_LISTEN_ON_PORT")"
  BACKEND_FORWARD_PORT="$(defaults_get "$existing_defaults" "BACKEND_FORWARD_PORT" 2>/dev/null || printf '%s\n' "$BACKEND_FORWARD_PORT")"
fi

[[ -n "$POMERIUM_ROUTE" ]] || POMERIUM_ROUTE="tcp+https://agent.localhost:443"
[[ -n "$POMERIUM_PORT" ]] || POMERIUM_PORT="443"
[[ -n "$AGENT_CONNECTION_URL" ]] || AGENT_CONNECTION_URL="https://agent.localhost:443"
[[ -n "$CONNECTION_KEY" ]] || CONNECTION_KEY="tcp://0.0.0.0:5990#jt=ca7cd969-f4dc-4d58-bdad-3ab4f3f9e8d6&p=IU&fp=E80F9EA7A46A357ED269F7F9F7E628F0A70BB6251A69E96F86DB658A96029140&cb=253.32098.37&newUi=true&jb=21.0.10b1163.110"

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
  nohup "$REMOTE_TBCLI_PATH" agent --tcp-listen-on-port="$AGENT_TCP_LISTEN_ON_PORT" >> "$REMOTE_TOOLBOX_DATA_DIR/agent.log" 2>&1 < /dev/null &
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

generated_link="jetbrains://remote-dev/jetbrains.toolbox.pomerium/new-environment#pomeriumRoute=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$POMERIUM_ROUTE")&connectionKey=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$CONNECTION_KEY")&pomeriumPort=$POMERIUM_PORT"
if [[ -n "$POMERIUM_INSTANCE" ]]; then
  generated_link="${generated_link}&pomeriumInstance=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$POMERIUM_INSTANCE")"
fi
generated_link="${generated_link}&agentConnectionUrl=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$AGENT_CONNECTION_URL")&agentAuth=$AGENT_AUTH"

POMERIUM_ROUTE="$(parse_link_field "$generated_link" "pomeriumRoute" 2>/dev/null || printf '%s\n' "$POMERIUM_ROUTE")"
POMERIUM_PORT="$(parse_link_field "$generated_link" "pomeriumPort" 2>/dev/null || printf '%s\n' "$POMERIUM_PORT")"
POMERIUM_INSTANCE="$(parse_link_field "$generated_link" "pomeriumInstance" 2>/dev/null || printf '%s\n' "$POMERIUM_INSTANCE")"
AGENT_CONNECTION_URL="$(parse_link_field "$generated_link" "agentConnectionUrl" 2>/dev/null || printf '%s\n' "$AGENT_CONNECTION_URL")"
CONNECTION_KEY="$(parse_link_field "$generated_link" "connectionKey" 2>/dev/null || printf '%s\n' "$CONNECTION_KEY")"
AGENT_AUTH="$(parse_link_field "$generated_link" "agentAuth" 2>/dev/null || printf '%s\n' "$AGENT_AUTH")"

cat >"$DEFAULTS_FILE" <<EOF
POMERIUM_ROUTE=$(quote_shell "$POMERIUM_ROUTE")
POMERIUM_PORT=$(quote_shell "$POMERIUM_PORT")
POMERIUM_INSTANCE=$(quote_shell "$POMERIUM_INSTANCE")
AGENT_CONNECTION_URL=$(quote_shell "$AGENT_CONNECTION_URL")
CONNECTION_KEY=$(quote_shell "$CONNECTION_KEY")
AGENT_AUTH=$(quote_shell "$AGENT_AUTH")
AGENT_TCP_LISTEN_ON_PORT=$(quote_shell "$AGENT_TCP_LISTEN_ON_PORT")
BACKEND_FORWARD_PORT=$(quote_shell "$BACKEND_FORWARD_PORT")
EOF

log "Wrote defaults to $DEFAULTS_FILE"
printf '%s\n' "$generated_link"

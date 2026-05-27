#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANAGE_SH="$SCRIPT_DIR/manage.sh"
DEFAULTS_FILE="${LINK_HELPER_DEFAULTS_FILE:-$SCRIPT_DIR/../state/link-helper.defaults.real.env}"

log() {
  printf '[link-helper] %s\n' "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

require_manage() {
  [[ -x "$MANAGE_SH" ]] || fail "manage.sh not found or not executable: $MANAGE_SH"
}

load_defaults_file() {
  python3 - <<'PY' "$DEFAULTS_FILE"
import pathlib
import shlex
import sys

path = pathlib.Path(sys.argv[1])
keys = [
    "CLIENT_POMERIUM_ROUTE",
    "POMERIUM_PORT",
    "POMERIUM_INSTANCE",
    "DISPLAY_NAME",
    "AGENT_CONNECTION_URL",
    "CONNECTION_KEY",
    "AGENT_AUTH",
    "AGENT_TCP_LISTEN_ON_PORT",
    "AGENT_FORWARD_PORT",
    "BACKEND_FORWARD_PORT",
]
values = {k: "" for k in keys}

for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, value = line.split("=", 1)
    key = key.strip()
    if key not in values:
        continue
    value = value.strip()
    if not value:
        values[key] = ""
        continue
    try:
        parts = shlex.split(value, posix=True)
        values[key] = " ".join(parts)
    except ValueError:
        values[key] = value.strip("\"'")

for key in keys:
    print(f"{key}={values[key]}")
PY
}

prompt_default() {
  local prompt="$1"
  local default_value="${2:-}"
  local answer
  if [[ -n "$default_value" ]]; then
    read -r -p "$prompt [$default_value]: " answer
    printf '%s\n' "${answer:-$default_value}"
  else
    read -r -p "$prompt: " answer
    printf '%s\n' "$answer"
  fi
}

prompt_yes_no() {
  local prompt="$1"
  local default_answer="${2:-y}"
  local answer
  local hint="Y/n"
  if [[ "$default_answer" == "n" ]]; then
    hint="y/N"
  fi
  read -r -p "$prompt [$hint]: " answer
  answer="${answer:-$default_answer}"
  [[ "$answer" =~ ^[Yy]$ ]]
}

urlencode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

json_get() {
  local json_input="$1"
  local key="$2"
  python3 -c 'import json,sys; data=json.load(sys.stdin); value=data
for part in sys.argv[1].split("."):
    value=value[part]
print(value if not isinstance(value, (dict,list)) else json.dumps(value, ensure_ascii=False))' "$key" <<<"$json_input"
}

generate_link() {
  local client_pomerium_route="$1"
  local pomerium_port="$2"
  local pomerium_instance="$3"
  local display_name="$4"
  local agent_connection_url="$5"
  local connection_key_raw="$6"
  local agent_auth="$7"

  local client_pomerium_route_encoded agent_connection_url_encoded connection_key_encoded
  client_pomerium_route_encoded="$(urlencode "$client_pomerium_route")"
  agent_connection_url_encoded="$(urlencode "$agent_connection_url")"
  connection_key_encoded="$(urlencode "$connection_key_raw")"

  local link
  link="jetbrains://remote-dev/jetbrains.toolbox.pomerium/new-environment#clientPomeriumRoute=${client_pomerium_route_encoded}&connectionKey=${connection_key_encoded}&pomeriumPort=${pomerium_port}"
  if [[ -n "$pomerium_instance" ]]; then
    link="${link}&pomeriumInstance=$(urlencode "$pomerium_instance")"
  fi
  if [[ -n "$display_name" ]]; then
    link="${link}&displayName=$(urlencode "$display_name")"
  fi
  link="${link}&agentConnectionUrl=${agent_connection_url_encoded}&agentAuth=${agent_auth}"
  printf '%s\n' "$link"
}

main() {
  require_manage
  [[ -f "$DEFAULTS_FILE" ]] || fail "defaults file not found: $DEFAULTS_FILE"

  local defaults_line
  while IFS= read -r defaults_line; do
    case "$defaults_line" in
      CLIENT_POMERIUM_ROUTE=*) CLIENT_POMERIUM_ROUTE="${defaults_line#CLIENT_POMERIUM_ROUTE=}" ;;
      POMERIUM_PORT=*) POMERIUM_PORT="${defaults_line#POMERIUM_PORT=}" ;;
      POMERIUM_INSTANCE=*) POMERIUM_INSTANCE="${defaults_line#POMERIUM_INSTANCE=}" ;;
      DISPLAY_NAME=*) DISPLAY_NAME="${defaults_line#DISPLAY_NAME=}" ;;
      AGENT_CONNECTION_URL=*) AGENT_CONNECTION_URL="${defaults_line#AGENT_CONNECTION_URL=}" ;;
      CONNECTION_KEY=*) CONNECTION_KEY="${defaults_line#CONNECTION_KEY=}" ;;
      AGENT_AUTH=*) AGENT_AUTH="${defaults_line#AGENT_AUTH=}" ;;
      AGENT_TCP_LISTEN_ON_PORT=*) AGENT_TCP_LISTEN_ON_PORT="${defaults_line#AGENT_TCP_LISTEN_ON_PORT=}" ;;
      AGENT_FORWARD_PORT=*) AGENT_FORWARD_PORT="${defaults_line#AGENT_FORWARD_PORT=}" ;;
      BACKEND_FORWARD_PORT=*) BACKEND_FORWARD_PORT="${defaults_line#BACKEND_FORWARD_PORT=}" ;;
    esac
  done < <(load_defaults_file)

  local json_output=""
  if json_output="$("$MANAGE_SH" print-json 2>/dev/null)"; then
    log "Detected running agent metadata"
  else
    log "Could not read agent metadata via manage.sh print-json"
  fi

  local agent_auth_default=""
  if [[ -n "$json_output" ]]; then
    agent_auth_default="$(json_get "$json_output" "agent_auth" 2>/dev/null || true)"
  fi

  local client_pomerium_route_default="${CLIENT_POMERIUM_ROUTE:-tcp://backend.localhost:443}"
  local pomerium_port_default="${POMERIUM_PORT:-443}"
  local pomerium_instance_default="${POMERIUM_INSTANCE:-}"
  local display_name_default="${DISPLAY_NAME:-}"
  local agent_url_default="${AGENT_CONNECTION_URL:-https://agent.localhost:443}"
  local connection_key_default="${CONNECTION_KEY:-tcp://0.0.0.0:5990#jt=ca7cd969-f4dc-4d58-bdad-3ab4f3f9e8d6&p=IU&fp=E80F9EA7A46A357ED269F7F9F7E628F0A70BB6251A69E96F86DB658A96029140&cb=253.32098.37&newUi=true&jb=21.0.10b1163.110}"
  local agent_auth_file_default="${AGENT_AUTH:-}"
  local agent_port_default="${AGENT_TCP_LISTEN_ON_PORT:-}"
  local agent_forward_port_default="${AGENT_FORWARD_PORT:-}"
  local backend_forward_port_default="${BACKEND_FORWARD_PORT:-5990}"

  if [[ -n "$agent_auth_file_default" ]]; then
    agent_auth_default="$agent_auth_file_default"
  fi

  printf '\n'
  log "We are filling the deep link fields"
  printf '  route: clientPomeriumRoute, pomeriumPort, pomeriumInstance (optional)\n'
  printf '  identity: displayName (optional)\n'
  printf '  backend: connectionKey\n'
  printf '  agent: agentConnectionUrl, agentAuth\n'
  printf '  runtime: agent tcp port, agent forwarder port, backend relay port (optional)\n'
  printf '\n'

  local client_pomerium_route pomerium_port pomerium_instance display_name agent_connection_url connection_key_raw agent_auth agent_tcp_listen_on_port agent_forward_port backend_forward_port
  client_pomerium_route="$(prompt_default "clientPomeriumRoute" "$client_pomerium_route_default")"
  pomerium_port="$(prompt_default "pomeriumPort" "$pomerium_port_default")"
  pomerium_instance="$(prompt_default "pomeriumInstance (optional, leave empty if not needed)" "$pomerium_instance_default")"
  display_name="$(prompt_default "displayName (optional, label shown in Toolbox)" "$display_name_default")"
  agent_connection_url="$(prompt_default "agentConnectionUrl" "$agent_url_default")"
  connection_key_raw="$(prompt_default "connectionKey" "$connection_key_default")"
  agent_auth="$(prompt_default "agentAuth" "$agent_auth_default")"
  agent_tcp_listen_on_port="$(prompt_default "agentTcpListenOnPort (optional, leave empty for automatic)" "$agent_port_default")"
  agent_forward_port="$(prompt_default "agentForwardPort (optional, leave empty to disable)" "$agent_forward_port_default")"
  backend_forward_port="$(prompt_default "backendRelayPort (optional, leave empty to disable)" "$backend_forward_port_default")"

  local link
  link="$(generate_link "$client_pomerium_route" "$pomerium_port" "$pomerium_instance" "$display_name" "$agent_connection_url" "$connection_key_raw" "$agent_auth")"

  printf '\n'
  log "Summary"
  printf '  defaults file: %s\n' "$DEFAULTS_FILE"
  printf '  clientPomeriumRoute: %s\n' "$client_pomerium_route"
  if [[ -n "$pomerium_instance" ]]; then
    printf '  pomeriumInstance: %s\n' "$pomerium_instance"
  fi
  printf '  displayName: %s\n' "${display_name:-<empty>}"
  printf '  agentConnectionUrl: %s\n' "$agent_connection_url"
  printf '  connectionKey: %s\n' "$connection_key_raw"
  printf '  agentAuth: %s\n' "${agent_auth:-<empty>}"
  printf '  agentTcpListenOnPort: %s\n' "${agent_tcp_listen_on_port:-<automatic>}"
  printf '  agentForwardPort: %s\n' "${agent_forward_port:-<disabled>}"
  printf '  backendRelayPort: %s\n' "${backend_forward_port:-<disabled>}"
  printf '\n'
  cat >"$DEFAULTS_FILE" <<EOF
CLIENT_POMERIUM_ROUTE=$(python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$client_pomerium_route")
POMERIUM_PORT=$(python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$pomerium_port")
POMERIUM_INSTANCE=$(python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$pomerium_instance")
DISPLAY_NAME=$(python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$display_name")
AGENT_CONNECTION_URL=$(python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$agent_connection_url")
CONNECTION_KEY=$(python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$connection_key_raw")
AGENT_AUTH=$(python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$agent_auth")
AGENT_TCP_LISTEN_ON_PORT=$(python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$agent_tcp_listen_on_port")
AGENT_FORWARD_PORT=$(python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$agent_forward_port")
BACKEND_FORWARD_PORT=$(python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$backend_forward_port")
EOF
  log "Updated defaults file"
  log "Generated link"
  printf '%s\n' "$link"
}

main "$@"

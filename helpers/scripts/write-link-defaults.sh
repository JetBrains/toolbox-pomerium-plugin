#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANAGE_SH="$SCRIPT_DIR/manage.sh"
OUTPUT_FILE="${1:-$SCRIPT_DIR/../state/link-helper.defaults.real.env}"
MANAGE_LOCAL_ENV_FILE="${MANAGE_LOCAL_ENV_FILE:-$SCRIPT_DIR/../state/manage.local.env}"
DEV_LOCAL_ENV_FILE="${DEV_LOCAL_ENV_FILE:-$SCRIPT_DIR/../state/dev.local.env}"
TOOLBOX_DEV_ENV_FILE="${TOOLBOX_DEV_ENV_FILE:-$SCRIPT_DIR/../state/toolbox-dev.local.env}"
LOCAL_IDEA_ENV_FILE="${LOCAL_IDEA_ENV_FILE:-$SCRIPT_DIR/../state/local-idea.local.env}"

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
  printf '[write-link-defaults] %s\n' "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

[[ -x "$MANAGE_SH" ]] || fail "manage.sh not found or not executable: $MANAGE_SH"

ensure_docker() {
  if ! docker info >/dev/null 2>&1; then
    fail "Docker is not available"
  fi
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

ensure_docker

log "Refreshing real stack"
"$MANAGE_SH" recreate >/dev/null

log "Reading live agent metadata"
json_output="$("$MANAGE_SH" print-json 2>/dev/null || true)"
log "Reading live generated link"
existing_link="$("$MANAGE_SH" print-link 2>/dev/null || true)"
existing_defaults="$(cat "$OUTPUT_FILE" 2>/dev/null || true)"

json_get() {
  local json_input="$1"
  local key="$2"
  python3 -c 'import json,sys; data=json.load(sys.stdin); value=data
for part in sys.argv[1].split("."):
    value=value[part]
print(value if not isinstance(value, (dict,list)) else json.dumps(value, ensure_ascii=False))' "$key" <<<"$json_input"
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
        parts = shlex.split(value, posix=True)
        print(" ".join(parts))
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

CLIENT_POMERIUM_ROUTE="https://backend.localhost:443"
POMERIUM_PORT="443"
POMERIUM_INSTANCE=""
DISPLAY_NAME=""
TOOLBOX_MODE="${TOOLBOX_MODE:-toolbox}"
AGENT_POMERIUM_ROUTE="https://agent.localhost:443"
TARGET_CONNECTION_BUILD="${CONNECTION_KEY_BUILD:-261.24374.151}"
CONNECTION_KEY="https://backend.localhost:5990#jt=ca7cd969-f4dc-4d58-bdad-3ab4f3f9e8d6&p=IU&fp=E80F9EA7A46A357ED269F7F9F7E628F0A70BB6251A69E96F86DB658A96029140&cb=${TARGET_CONNECTION_BUILD}&newUi=true&jb=21.0.10b1163.110"
PROJECT_PATH="${PROJECT_PATH:-${CONTAINER_PROJECT_DIR:-/home/dev/projects/test_project}}"
AGENT_AUTH=""
AGENT_TCP_LISTEN_ON_PORT="44000"
AGENT_FORWARD_PORT=""
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
  AGENT_FORWARD_PORT="$(defaults_get "$existing_defaults" "AGENT_FORWARD_PORT" 2>/dev/null || printf '%s\n' "$AGENT_FORWARD_PORT")"
  BACKEND_FORWARD_PORT="$(defaults_get "$existing_defaults" "BACKEND_FORWARD_PORT" 2>/dev/null || printf '%s\n' "$BACKEND_FORWARD_PORT")"
fi

if [[ "$TOOLBOX_MODE" == "toolbox" && -z "$BACKEND_FORWARD_PORT" ]]; then
  BACKEND_FORWARD_PORT="5990"
fi

if [[ -n "$existing_link" ]]; then
  CLIENT_POMERIUM_ROUTE="$(parse_link_field "$existing_link" "clientPomeriumRoute" 2>/dev/null || printf '%s\n' "$CLIENT_POMERIUM_ROUTE")"
  POMERIUM_PORT="$(parse_link_field "$existing_link" "pomeriumPort" 2>/dev/null || printf '%s\n' "$POMERIUM_PORT")"
  POMERIUM_INSTANCE="$(parse_link_field "$existing_link" "pomeriumInstance" 2>/dev/null || printf '%s\n' "$POMERIUM_INSTANCE")"
  DISPLAY_NAME="$(parse_link_field "$existing_link" "displayName" 2>/dev/null || printf '%s\n' "$DISPLAY_NAME")"
  PROJECT_PATH="$(parse_link_field "$existing_link" "projectPath" 2>/dev/null || printf '%s\n' "$PROJECT_PATH")"
  AGENT_POMERIUM_ROUTE="$(parse_link_field "$existing_link" "agentPomeriumRoute" 2>/dev/null || printf '%s\n' "$AGENT_POMERIUM_ROUTE")"
  CONNECTION_KEY="$(parse_link_field "$existing_link" "connectionKey" 2>/dev/null || printf '%s\n' "$CONNECTION_KEY")"
  AGENT_AUTH="$(parse_link_field "$existing_link" "agentAuth" 2>/dev/null || printf '%s\n' "$AGENT_AUTH")"
fi

if [[ -n "$json_output" ]]; then
  AGENT_AUTH="$(json_get "$json_output" "agent_auth" 2>/dev/null || printf '%s\n' "$AGENT_AUTH")"
fi

CLIENT_POMERIUM_ROUTE="$(normalize_backend_route "$CLIENT_POMERIUM_ROUTE")"
CONNECTION_KEY="$(normalize_connection_key "$CONNECTION_KEY" "$TARGET_CONNECTION_BUILD")"
quote_shell() {
  python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$1"
}

cat >"$OUTPUT_FILE" <<EOF
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
AGENT_FORWARD_PORT=$(quote_shell "$AGENT_FORWARD_PORT")
BACKEND_FORWARD_PORT=$(quote_shell "$BACKEND_FORWARD_PORT")
EOF

log "Wrote defaults to $OUTPUT_FILE"

#!/usr/bin/env bash
set -euo pipefail

USERNAME="${USERNAME:-dev}"
TBCLI_VERSION="${TBCLI_VERSION:-3.5.0.84344}"
TOOLBOX_HOME="${TOOLBOX_HOME:-/home/$USERNAME}"
TOOLBOX_MODE="${TOOLBOX_MODE:-toolbox}"
TOOLBOX_DATA_DIR="${TOOLBOX_DATA_DIR:-$TOOLBOX_HOME/.local/share/JetBrains/Toolbox}"
TOOLBOX_CACHE_DIR="${TOOLBOX_CACHE_DIR:-$TOOLBOX_HOME/.cache/JetBrains/Toolbox-CLI-dist}"
IDEA_DIST_ROOT="${IDEA_DIST_ROOT:-/opt/idea-dist}"
USE_HOST_TBCLI="${USE_HOST_TBCLI:-1}"
HOST_TBCLI_DIR="${HOST_TBCLI_DIR:-/opt/helpers/host-tbcli}"
TBCLI_DIR="${TBCLI_DIR:-$TOOLBOX_CACHE_DIR/tbcli-$TBCLI_VERSION}"
TB_CLI_PATH="${TB_CLI_PATH:-$TBCLI_DIR/bin/tbcli}"
TB_JAVA_HOME="${TB_JAVA_HOME:-${JAVA_HOME:-}}"
PORT_FILE="$TOOLBOX_DATA_DIR/.port"
AGENT_LOG="$TOOLBOX_DATA_DIR/agent.log"
AGENT_INFO="$TOOLBOX_DATA_DIR/agent-info.json"
FORWARD_AGENT_INFO="$TOOLBOX_DATA_DIR/forward-agent.json"
FORWARD_5990_INFO="$TOOLBOX_DATA_DIR/forward-5990.json"
LINK_FILE="$TOOLBOX_DATA_DIR/jetbrains-link.txt"
RUNTIME_DEFAULTS_FILE="${RUNTIME_DEFAULTS_FILE:-/opt/helpers/state/link-helper.defaults.real.env}"
DISPLAY_NAME_STATE_FILE="${DISPLAY_NAME_STATE_FILE:-$TOOLBOX_DATA_DIR/.display-name}"
CONNECTION_KEY_BUILD="${CONNECTION_KEY_BUILD:-261.24374.151}"
DISPLAY_NAME_OVERRIDE="${DISPLAY_NAME_OVERRIDE:-}"
PROJECT_PATH="${PROJECT_PATH:-${CONTAINER_PROJECT_DIR:-/home/dev/projects/test_project}}"

CLIENT_POMERIUM_ROUTE="${CLIENT_POMERIUM_ROUTE:-}"
CONNECTION_KEY="${CONNECTION_KEY:-https%3A%2F%2Fbackend.localhost%3A5990%23jt%3Dca7cd969-f4dc-4d58-bdad-3ab4f3f9e8d6%26p%3DIU%26fp%3DE80F9EA7A46A357ED269F7F9F7E628F0A70BB6251A69E96F86DB658A96029140%26cb%3D${CONNECTION_KEY_BUILD}%26newUi%3Dtrue%26jb%3D21.0.10b1163.110}"
POMERIUM_PORT="${POMERIUM_PORT:-}"
DISPLAY_NAME="${DISPLAY_NAME:-}"
AGENT_POMERIUM_ROUTE="${AGENT_POMERIUM_ROUTE:-}"
POMERIUM_STACK_MODE="${POMERIUM_STACK_MODE:-mock}"
# Toolbox mode keeps using the bridge-only setup by default.
# Toolbox-dev can opt into direct 0.0.0.0:44000 via TOOLBOX_MODE=toolbox-dev.
AGENT_TCP_LISTEN_ON_PORT="${AGENT_TCP_LISTEN_ON_PORT-}"
AGENT_FORWARD_PORT="${AGENT_FORWARD_PORT:-44000}"
BACKEND_FORWARD_PORT="${BACKEND_FORWARD_PORT:-5990}"
log() {
  printf '[helpers-upstream] %s\n' "$*"
}

apply_pomerium_mode_defaults() {
  case "$POMERIUM_STACK_MODE" in
    real)
      : "${CLIENT_POMERIUM_ROUTE:=https%3A%2F%2Fbackend.localhost%3A443}"
      : "${POMERIUM_PORT:=443}"
      : "${AGENT_POMERIUM_ROUTE:=https%3A%2F%2Fagent.localhost%3A443}"
      ;;
    *)
      : "${CLIENT_POMERIUM_ROUTE:=https%3A%2F%2Fbackend.localhost%3A443}"
      : "${POMERIUM_PORT:=443}"
      : "${AGENT_POMERIUM_ROUTE:=https%3A%2F%2Flocalhost%3A44000}"
      ;;
  esac
}

generate_display_name() {
  python3 - <<'PY'
import secrets
print(f"Pomerium Dev {secrets.token_hex(3)}")
PY
}

load_display_name_state() {
  [[ -f "$DISPLAY_NAME_STATE_FILE" ]] || return 0

  local cached_display_name=""
  IFS= read -r cached_display_name < "$DISPLAY_NAME_STATE_FILE" || true
  if [[ -n "$cached_display_name" ]]; then
    DISPLAY_NAME="$cached_display_name"
  fi
}

save_display_name_state() {
  [[ -n "${DISPLAY_NAME:-}" ]] || return 0

  mkdir -p "$(dirname "$DISPLAY_NAME_STATE_FILE")"
  printf '%s\n' "$DISPLAY_NAME" > "$DISPLAY_NAME_STATE_FILE"
}

save_display_name_defaults() {
  [[ -n "${DISPLAY_NAME:-}" ]] || return 0

  local defaults_dir
  defaults_dir="$(dirname "$RUNTIME_DEFAULTS_FILE")"

  if [[ -e "$RUNTIME_DEFAULTS_FILE" ]]; then
    [[ -w "$RUNTIME_DEFAULTS_FILE" ]] || return 0
  else
    [[ -d "$defaults_dir" ]] || return 0
    [[ -w "$defaults_dir" ]] || return 0
  fi

  python3 - <<'PY' "$RUNTIME_DEFAULTS_FILE" "$DISPLAY_NAME"
import pathlib
import shlex
import sys

path = pathlib.Path(sys.argv[1])
display_name = sys.argv[2]
line_value = f"DISPLAY_NAME={shlex.quote(display_name)}"

lines = []
if path.exists():
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()

updated = False
for index, line in enumerate(lines):
    if line.lstrip().startswith("DISPLAY_NAME="):
        lines[index] = line_value
        updated = True
        break

if not updated:
    lines.append(line_value)

path.parent.mkdir(parents=True, exist_ok=True)
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

ensure_display_name() {
  if [[ -z "${DISPLAY_NAME:-}" ]]; then
    load_display_name_state
  fi

  if [[ -z "${DISPLAY_NAME:-}" ]]; then
    DISPLAY_NAME="$(generate_display_name)"
    save_display_name_state
    save_display_name_defaults
  fi
}

apply_display_name_override() {
  if [[ -n "${DISPLAY_NAME_OVERRIDE:-}" ]]; then
    DISPLAY_NAME="$DISPLAY_NAME_OVERRIDE"
  fi
}

load_runtime_defaults() {
  [[ -f "$RUNTIME_DEFAULTS_FILE" ]] || return 0
  while IFS= read -r defaults_line; do
    case "$defaults_line" in
      AGENT_TCP_LISTEN_ON_PORT=*) AGENT_TCP_LISTEN_ON_PORT="${defaults_line#AGENT_TCP_LISTEN_ON_PORT=}" ;;
      AGENT_FORWARD_PORT=*) AGENT_FORWARD_PORT="${defaults_line#AGENT_FORWARD_PORT=}" ;;
      BACKEND_FORWARD_PORT=*) BACKEND_FORWARD_PORT="${defaults_line#BACKEND_FORWARD_PORT=}" ;;
      DISPLAY_NAME=*) DISPLAY_NAME="${defaults_line#DISPLAY_NAME=}" ;;
      PROJECT_PATH=*)
        if [[ -n "${defaults_line#PROJECT_PATH=}" ]]; then
          PROJECT_PATH="${defaults_line#PROJECT_PATH=}"
        fi
        ;;
    esac
  done < <(python3 - <<'PY' "$RUNTIME_DEFAULTS_FILE"
import pathlib
import shlex
import sys

path = pathlib.Path(sys.argv[1])
keys = ["AGENT_TCP_LISTEN_ON_PORT", "AGENT_FORWARD_PORT", "BACKEND_FORWARD_PORT", "DISPLAY_NAME", "PROJECT_PATH"]
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
        values[key] = " ".join(shlex.split(value, posix=True))
    except ValueError:
        values[key] = value.strip("\"'")

for key in keys:
    print(f"{key}={values[key]}")
PY
)

  if [[ "$TOOLBOX_MODE" == "toolbox" ]]; then
    AGENT_TCP_LISTEN_ON_PORT=""
    AGENT_FORWARD_PORT="44000"
    BACKEND_FORWARD_PORT="5990"
  fi
}

apply_toolbox_mode_overrides() {
  case "$TOOLBOX_MODE" in
    toolbox)
      unset AGENT_TCP_LISTEN_ON_PORT || true
      AGENT_TCP_LISTEN_ON_PORT=""
      AGENT_FORWARD_PORT="44000"
      BACKEND_FORWARD_PORT="5990"
      ;;
    toolbox-dev|*)
      : "${AGENT_TCP_LISTEN_ON_PORT:=44000}"
      AGENT_FORWARD_PORT=""
      BACKEND_FORWARD_PORT=""
      ;;
  esac

  PORT_FILE="$TOOLBOX_DATA_DIR/.port"
  AGENT_LOG="$TOOLBOX_DATA_DIR/agent.log"
  AGENT_INFO="$TOOLBOX_DATA_DIR/agent-info.json"
  FORWARD_AGENT_INFO="$TOOLBOX_DATA_DIR/forward-agent.json"
  FORWARD_5990_INFO="$TOOLBOX_DATA_DIR/forward-5990.json"
  LINK_FILE="$TOOLBOX_DATA_DIR/jetbrains-link.txt"
  DISPLAY_NAME_STATE_FILE="$TOOLBOX_DATA_DIR/.display-name"
}

fail() {
  log "ERROR: $*"
  if [[ -f "$AGENT_LOG" ]]; then
    log "Last agent log lines:"
    tail -n 200 "$AGENT_LOG" || true
  fi
  exit 1
}

resolve_tbcli() {
  if [[ "$USE_HOST_TBCLI" == "1" ]]; then
    TBCLI_DIR="$HOST_TBCLI_DIR"
    TB_CLI_PATH="$TBCLI_DIR/bin/tbcli"
    [[ -x "$TB_CLI_PATH" ]] || fail "host-mounted tbcli was requested but not found at $TB_CLI_PATH"
    return
  fi

  [[ -x "$TB_CLI_PATH" ]] || fail "tbcli is not available at $TB_CLI_PATH"
}

fix_ownership() {
  chown -R "$USERNAME:$USERNAME" "$TOOLBOX_HOME"
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

kill_background() {
  local pid_file="$1"
  if [[ -f "$pid_file" ]]; then
    local pid
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      sleep 0.2
    fi
  fi
  rm -f "$pid_file"
}

stop_stack() {
  log "Stopping forwarder and Toolbox Agent"
  kill_background "$FORWARD_AGENT_INFO.pid"
  kill_background "$FORWARD_5990_INFO.pid"

  pkill -f "/opt/helpers/docker/bridge.py --target-host 127.0.0.1" 2>/dev/null || true
  pkill -f "$TB_CLI_PATH agent" 2>/dev/null || true
  rm -f "$PORT_FILE" "$AGENT_INFO" "$FORWARD_AGENT_INFO" "$FORWARD_5990_INFO" "$LINK_FILE"
  fix_ownership
}

start_agent() {
  rm -f "$PORT_FILE" "$AGENT_INFO" "$FORWARD_AGENT_INFO" "$FORWARD_5990_INFO" "$LINK_FILE"
  : > "$AGENT_LOG"
  fix_ownership

  log "Starting Toolbox Agent via $TB_CLI_PATH"
  local agent_args="agent"
  if [[ -n "$AGENT_TCP_LISTEN_ON_PORT" ]]; then
    agent_args="$agent_args --address 0.0.0.0 --port $AGENT_TCP_LISTEN_ON_PORT"
  fi
  su - "$USERNAME" -c \
    "export TB_CLI_PATH='$TB_CLI_PATH'; export TB_JAVA_HOME='$TB_JAVA_HOME'; nohup '$TB_CLI_PATH' $agent_args >> '$AGENT_LOG' 2>&1 < /dev/null &"
}

wait_for_result() {
  log "Waiting for ~RESULT line in $AGENT_LOG"
  for _ in $(seq 1 120); do
    if python3 - <<'PY' "$AGENT_LOG" "$AGENT_INFO"
import json
import sys

log_path, out_path = sys.argv[1], sys.argv[2]
prefix = "~RESULT:"
result = None

with open(log_path, "r", encoding="utf-8", errors="replace") as f:
    for line in f:
        if line.startswith(prefix):
            result = line[len(prefix):].strip()

if result is None:
    raise SystemExit(1)

payload = json.loads(result)
with open(out_path, "w", encoding="utf-8") as out:
    json.dump(payload, out, ensure_ascii=True)
PY
    then
      fix_ownership
      log "Agent result detected in log"
      return 0
    fi
    sleep 0.5
  done
  return 1
}

start_agent_forwarder() {
  local agent_port
  agent_port="$(python3 -c 'import json,sys; payload=json.load(open(sys.argv[1])); listen_on=payload.get("rpcListenOn") or payload.get("listenOn") or {}; print(listen_on["port"])' "$AGENT_INFO")"

  if [[ -z "$AGENT_FORWARD_PORT" ]]; then
    if [[ "$agent_port" != "44000" ]]; then
      fail "Agent forwarder is disabled, but Toolbox Agent listens on $agent_port. Set AGENT_TCP_LISTEN_ON_PORT=44000 or enable AGENT_FORWARD_PORT=44000."
    fi
    log "Agent forwarder disabled; Toolbox Agent listens directly on 44000"
    python3 - <<'PY' "$FORWARD_AGENT_INFO"
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as out:
    json.dump({"listen_host": "0.0.0.0", "listen_port": 44000, "target_host": "127.0.0.1", "target_port": 44000, "mode": "direct"}, out)
PY
    fix_ownership
    return 0
  fi

  if [[ "$agent_port" == "$AGENT_FORWARD_PORT" ]]; then
    log "Skipping agent forwarder on $AGENT_FORWARD_PORT because Toolbox Agent already listens on that port"
    python3 - <<'PY' "$FORWARD_AGENT_INFO" "$AGENT_FORWARD_PORT"
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as out:
    json.dump({"listen_host": "0.0.0.0", "listen_port": int(sys.argv[2]), "target_host": "127.0.0.1", "target_port": int(sys.argv[2]), "mode": "direct"}, out)
PY
    fix_ownership
    return 0
  fi

  log "Starting agent forwarder $AGENT_FORWARD_PORT -> $agent_port"
  python3 /opt/helpers/docker/bridge.py     --target-host 127.0.0.1     --target-port "$agent_port"     --listen-host 0.0.0.0     --listen-port "$AGENT_FORWARD_PORT"     --info-file "$FORWARD_AGENT_INFO" &
  echo $! > "$FORWARD_AGENT_INFO.pid"
  fix_ownership
}

start_backend_forwarder() {
  if [[ -z "$BACKEND_FORWARD_PORT" ]]; then
    log "Skipping backend relay because BACKEND_FORWARD_PORT is empty"
    return 0
  fi

  local container_ip
  container_ip="$(python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
    try:
        sock.connect(("8.8.8.8", 80))
        print(sock.getsockname()[0])
    except OSError:
        print("127.0.0.1")
PY
)"

  log "Starting backend relay $container_ip:$BACKEND_FORWARD_PORT -> 127.0.0.1:5990"
  python3 /opt/helpers/docker/bridge.py \
    --target-host 127.0.0.1 \
    --target-port 5990 \
    --listen-host "$container_ip" \
    --listen-port "$BACKEND_FORWARD_PORT" \
    --info-file "$FORWARD_5990_INFO" &
  echo $! > "$FORWARD_5990_INFO.pid"
  fix_ownership
}

agent_forward_target_is_reachable() {
  [[ -s "$FORWARD_AGENT_INFO" ]] || return 1
  [[ -s "$AGENT_INFO" ]] || return 1
  python3 - <<'PY' "$FORWARD_AGENT_INFO" "$AGENT_INFO"
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    payload = json.load(f)
with open(sys.argv[2], encoding="utf-8") as f:
    agent = json.load(f)

listen_on = agent.get("rpcListenOn") or agent.get("listenOn") or {}
agent_port = int(listen_on.get("port") or 0)
target_port = int(payload.get("target_port") or payload.get("listen_port") or 0)

# Do not open a probe connection to Toolbox Agent here. The agent expects the
# first bytes on every TCP connection to be the auth token, so an empty probe can
# block the agent-side accept loop and break the real handshake.
if agent_port <= 0 or target_port != agent_port:
    raise SystemExit(1)
PY
}

ensure_agent_stack_ready() {
  if agent_forward_target_is_reachable; then
    return 0
  fi

  log "Agent forward target is not reachable; restarting stack to refresh agentAuth and forwarder"
  stop_stack
  start_stack
}

print_outputs() {
  apply_pomerium_mode_defaults
  load_runtime_defaults
  apply_toolbox_mode_overrides
  apply_display_name_override
  ensure_display_name
  ensure_agent_stack_ready
  python3 - <<'PY' "$AGENT_INFO" "$FORWARD_AGENT_INFO" "$TBCLI_VERSION" "$TB_CLI_PATH" "$PORT_FILE" "$LINK_FILE" "$CLIENT_POMERIUM_ROUTE" "$CONNECTION_KEY" "$POMERIUM_PORT" "$DISPLAY_NAME" "$AGENT_POMERIUM_ROUTE" "$PROJECT_PATH"
import json
import sys
from urllib.parse import quote

agent = json.load(open(sys.argv[1], encoding="utf-8"))
forward = json.load(open(sys.argv[2], encoding="utf-8"))
link_path = sys.argv[6]
agent_auth = agent.get("authToken") or ""

link = (
    "jetbrains://remote-dev/jetbrains.toolbox.pomerium/new-environment"
    f"#clientPomeriumRoute={sys.argv[7]}"
    f"&connectionKey={sys.argv[8]}"
    f"&pomeriumPort={sys.argv[9]}"
)
if sys.argv[10]:
    link += f"&displayName={quote(sys.argv[10], safe='')}"
if sys.argv[12]:
    link += f"&projectPath={sys.argv[12]}"
link += (
    f"&agentPomeriumRoute={sys.argv[11]}"
    f"&agentAuth={agent_auth}"
)

payload = {
    "display_name": sys.argv[10],
    "tbcli_version": sys.argv[3],
    "tb_cli_path": sys.argv[4],
    "agent_endpoint_file": sys.argv[5],
    "agent_listen_on": agent.get("rpcListenOn") or agent.get("listenOn"),
    "agent_port": (agent.get("rpcListenOn") or agent.get("listenOn"))["port"],
    "agent_auth": agent.get("authToken"),
    "agent_forward": {
        "host": forward["listen_host"],
        "port": forward["listen_port"],
        "mode": forward.get("mode", "forwarded"),
    },
    "project_path": sys.argv[12],
    "jetbrains_link": link,
}

with open(link_path, "w", encoding="utf-8") as f:
    f.write(link)
    f.write("\n")

print(json.dumps(payload, ensure_ascii=True), flush=True)
print(link, flush=True)
PY
  fix_ownership
}

print_link_only() {
  apply_pomerium_mode_defaults
  load_runtime_defaults
  apply_toolbox_mode_overrides
  apply_display_name_override
  ensure_display_name
  ensure_agent_stack_ready
  python3 - <<'PY' "$AGENT_INFO" "$LINK_FILE" "$CLIENT_POMERIUM_ROUTE" "$CONNECTION_KEY" "$POMERIUM_PORT" "$DISPLAY_NAME" "$AGENT_POMERIUM_ROUTE" "$PROJECT_PATH"
import json
import sys
from urllib.parse import quote

agent = json.load(open(sys.argv[1], encoding="utf-8"))
link_path = sys.argv[2]
agent_auth = agent.get("authToken") or ""

link = (
    "jetbrains://remote-dev/jetbrains.toolbox.pomerium/new-environment"
    f"#clientPomeriumRoute={sys.argv[3]}"
    f"&connectionKey={sys.argv[4]}"
    f"&pomeriumPort={sys.argv[5]}"
)
if sys.argv[6]:
    link += f"&displayName={quote(sys.argv[6], safe='')}"
if sys.argv[8]:
    link += f"&projectPath={sys.argv[8]}"
link += (
    f"&agentPomeriumRoute={sys.argv[7]}"
    f"&agentAuth={agent_auth}"
)

with open(link_path, "w", encoding="utf-8") as f:
    f.write(link)
    f.write("\n")

print(link, flush=True)
PY
  fix_ownership
}

start_stack() {
  resolve_tbcli
  apply_pomerium_mode_defaults
  load_runtime_defaults
  apply_toolbox_mode_overrides
  ensure_display_name
  resolve_java_home
  log "Using TB_JAVA_HOME=$TB_JAVA_HOME"
  log "Toolbox mode=$TOOLBOX_MODE dataDir=$TOOLBOX_DATA_DIR"
  log "Using tbcli at $TB_CLI_PATH"
  log "Toolbox additional tool path=$IDEA_DIST_ROOT"
  log "Pomerium stack mode=$POMERIUM_STACK_MODE clientRoute=$CLIENT_POMERIUM_ROUTE"
  if [[ -n "$AGENT_TCP_LISTEN_ON_PORT" ]]; then
    log "Toolbox Agent fixed tcp listen port=$AGENT_TCP_LISTEN_ON_PORT"
  else
    log "Toolbox Agent tcp listen port=automatic"
  fi
  if [[ -n "$AGENT_FORWARD_PORT" ]]; then
    log "Agent forwarder port=$AGENT_FORWARD_PORT"
  else
    log "Agent forwarder disabled"
  fi
  if [[ -n "$BACKEND_FORWARD_PORT" ]]; then
    log "Backend relay port=$BACKEND_FORWARD_PORT"
  else
    log "Backend relay disabled; expecting IDE to listen directly on helpers-upstream:5990"
  fi
  start_agent
  wait_for_result || fail "Agent did not emit ~RESULT"
  start_agent_forwarder
  start_backend_forwarder

  log "Waiting for forwarder metadata"
  for _ in $(seq 1 40); do
    [[ -s "$FORWARD_AGENT_INFO" ]] || { sleep 0.25; continue; }
    if [[ -n "$BACKEND_FORWARD_PORT" ]]; then
      [[ -s "$FORWARD_5990_INFO" ]] || { sleep 0.25; continue; }
    fi
    break
    sleep 0.25
  done

  if [[ ! -s "$FORWARD_AGENT_INFO" ]]; then
    fail "Agent forwarder metadata was not produced"
  fi
  if [[ -n "$BACKEND_FORWARD_PORT" ]] && [[ ! -s "$FORWARD_5990_INFO" ]]; then
    fail "Backend relay metadata was not produced"
  fi

  log "Stack startup complete"
  log "Use 'agent-stack.sh print-json' or 'agent-stack.sh print-link' to inspect live connection details explicitly"
}

resolve_tbcli

case "${1:-start}" in
  start)
    start_stack
    ;;
  stop)
    stop_stack
    ;;
  restart)
    stop_stack
    start_stack
    ;;
  print-link)
    print_link_only
    ;;
  print-json)
    print_outputs
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|print-link|print-json}" >&2
    exit 1
    ;;
esac

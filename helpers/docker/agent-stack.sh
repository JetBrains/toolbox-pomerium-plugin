#!/usr/bin/env bash
set -euo pipefail

USERNAME="${USERNAME:-dev}"
TBCLI_VERSION="${TBCLI_VERSION:-3.5.0.73530}"
TOOLBOX_HOME="${TOOLBOX_HOME:-/home/$USERNAME}"
TOOLBOX_DATA_DIR="${TOOLBOX_DATA_DIR:-$TOOLBOX_HOME/.local/share/JetBrains/Toolbox}"
TOOLBOX_CACHE_DIR="${TOOLBOX_CACHE_DIR:-$TOOLBOX_HOME/.cache/JetBrains/Toolbox-CLI-dist}"
TBCLI_DIR="$TOOLBOX_CACHE_DIR/tbcli-$TBCLI_VERSION"
TB_CLI_PATH="${TB_CLI_PATH:-$TBCLI_DIR/bin/tbcli}"
TB_JAVA_HOME="${TB_JAVA_HOME:-${JAVA_HOME:-}}"
PORT_FILE="$TOOLBOX_DATA_DIR/.port"
AGENT_LOG="$TOOLBOX_DATA_DIR/agent.log"
AGENT_INFO="$TOOLBOX_DATA_DIR/agent-info.json"
FORWARD_AGENT_INFO="$TOOLBOX_DATA_DIR/forward-agent.json"
FORWARD_5990_INFO="$TOOLBOX_DATA_DIR/forward-5990.json"
LINK_FILE="$TOOLBOX_DATA_DIR/jetbrains-link.txt"
RUNTIME_DEFAULTS_FILE="${RUNTIME_DEFAULTS_FILE:-/opt/helpers/state/link-helper.defaults.real.env}"

CLIENT_POMERIUM_ROUTE="${CLIENT_POMERIUM_ROUTE:-}"
CONNECTION_KEY="${CONNECTION_KEY:-tcp%3A%2F%2F0.0.0.0%3A5990%23jt%3Dca7cd969-f4dc-4d58-bdad-3ab4f3f9e8d6%26p%3DIU%26fp%3DE80F9EA7A46A357ED269F7F9F7E628F0A70BB6251A69E96F86DB658A96029140%26cb%3D253.32098.37%26newUi%3Dtrue%26jb%3D21.0.10b1163.110}"
POMERIUM_PORT="${POMERIUM_PORT:-}"
DISPLAY_NAME="${DISPLAY_NAME:-}"
AGENT_CONNECTION_URL="${AGENT_CONNECTION_URL:-}"
POMERIUM_STACK_MODE="${POMERIUM_STACK_MODE:-mock}"
AGENT_TCP_LISTEN_ON_PORT="${AGENT_TCP_LISTEN_ON_PORT:-}"
AGENT_FORWARD_PORT="${AGENT_FORWARD_PORT:-44000}"
BACKEND_FORWARD_PORT="${BACKEND_FORWARD_PORT:-5990}"

log() {
  printf '[helpers-upstream] %s\n' "$*"
}

apply_pomerium_mode_defaults() {
  case "$POMERIUM_STACK_MODE" in
    real)
      : "${CLIENT_POMERIUM_ROUTE:=tcp%3A%2F%2Fbackend.localhost%3A443}"
      : "${POMERIUM_PORT:=443}"
      : "${AGENT_CONNECTION_URL:=https%3A%2F%2Fagent.localhost%3A443}"
      ;;
    *)
      : "${CLIENT_POMERIUM_ROUTE:=tcp%3A%2F%2Fbackend.localhost%3A443}"
      : "${POMERIUM_PORT:=443}"
      : "${AGENT_CONNECTION_URL:=https%3A%2F%2Flocalhost%3A44000}"
      ;;
  esac
}

load_runtime_defaults() {
  [[ -f "$RUNTIME_DEFAULTS_FILE" ]] || return 0

  while IFS= read -r defaults_line; do
    case "$defaults_line" in
      AGENT_TCP_LISTEN_ON_PORT=*) AGENT_TCP_LISTEN_ON_PORT="${defaults_line#AGENT_TCP_LISTEN_ON_PORT=}" ;;
      AGENT_FORWARD_PORT=*) AGENT_FORWARD_PORT="${defaults_line#AGENT_FORWARD_PORT=}" ;;
      DISPLAY_NAME=*) DISPLAY_NAME="${defaults_line#DISPLAY_NAME=}" ;;
      BACKEND_FORWARD_PORT=*) BACKEND_FORWARD_PORT="${defaults_line#BACKEND_FORWARD_PORT=}" ;;
    esac
  done < <(python3 - <<'PY' "$RUNTIME_DEFAULTS_FILE"
import pathlib
import shlex
import sys

path = pathlib.Path(sys.argv[1])
keys = ["AGENT_TCP_LISTEN_ON_PORT", "AGENT_FORWARD_PORT", "BACKEND_FORWARD_PORT", "DISPLAY_NAME"]
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
}

fail() {
  log "ERROR: $*"
  if [[ -f "$AGENT_LOG" ]]; then
    log "Last agent log lines:"
    tail -n 200 "$AGENT_LOG" || true
  fi
  exit 1
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
    agent_args="agent --tcp-listen-on-port=$AGENT_TCP_LISTEN_ON_PORT"
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
  agent_port="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["listenOn"]["port"])' "$AGENT_INFO")"

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
start_forwarder_5990() {
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

  log "Starting raw forwarder $container_ip:$BACKEND_FORWARD_PORT -> 127.0.0.1:5990"
  python3 /opt/helpers/docker/bridge.py \
    --target-host 127.0.0.1 \
    --target-port 5990 \
    --listen-host "$container_ip" \
    --listen-port "$BACKEND_FORWARD_PORT" \
    --info-file "$FORWARD_5990_INFO" &
  echo $! > "$FORWARD_5990_INFO.pid"
  fix_ownership
}

print_outputs() {
  apply_pomerium_mode_defaults
  python3 - <<'PY' "$AGENT_INFO" "$FORWARD_AGENT_INFO" "$TBCLI_VERSION" "$TB_CLI_PATH" "$PORT_FILE" "$LINK_FILE" "$CLIENT_POMERIUM_ROUTE" "$CONNECTION_KEY" "$POMERIUM_PORT" "$DISPLAY_NAME" "$AGENT_CONNECTION_URL"
import json
import sys

agent = json.load(open(sys.argv[1], encoding="utf-8"))
forward = json.load(open(sys.argv[2], encoding="utf-8"))
link_path = sys.argv[6]

link = (
    "jetbrains://remote-dev/jetbrains.toolbox.pomerium/new-environment"
    f"#clientPomeriumRoute={sys.argv[7]}"
    f"&connectionKey={sys.argv[8]}"
    f"&pomeriumPort={sys.argv[9]}"
)
if sys.argv[10]:
    link += f"&displayName={sys.argv[10]}"
link += (
    f"&agentConnectionUrl={sys.argv[11]}"
    f"&agentAuth={agent.get('authToken', '')}"
)

payload = {
    "display_name": sys.argv[10],
    "tbcli_version": sys.argv[3],
    "tb_cli_path": sys.argv[4],
    "agent_endpoint_file": sys.argv[5],
    "agent_listen_on": agent["listenOn"],
    "agent_port": agent["listenOn"]["port"],
    "agent_auth": agent.get("authToken"),
    "agent_forward": {
        "host": forward["listen_host"],
        "port": forward["listen_port"],
        "mode": forward.get("mode", "forwarded"),
    },
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
  python3 - <<'PY' "$AGENT_INFO" "$LINK_FILE" "$CLIENT_POMERIUM_ROUTE" "$CONNECTION_KEY" "$POMERIUM_PORT" "$DISPLAY_NAME" "$AGENT_CONNECTION_URL"
import json
import sys

agent = json.load(open(sys.argv[1], encoding="utf-8"))
link_path = sys.argv[2]

link = (
    "jetbrains://remote-dev/jetbrains.toolbox.pomerium/new-environment"
    f"#clientPomeriumRoute={sys.argv[3]}"
    f"&connectionKey={sys.argv[4]}"
    f"&pomeriumPort={sys.argv[5]}"
)
if sys.argv[6]:
    link += f"&displayName={sys.argv[6]}"
link += (
    f"&agentConnectionUrl={sys.argv[7]}"
    f"&agentAuth={agent.get('authToken', '')}"
)

with open(link_path, "w", encoding="utf-8") as f:
    f.write(link)
    f.write("\n")

print(link, flush=True)
PY
  fix_ownership
}

start_stack() {
  apply_pomerium_mode_defaults
  load_runtime_defaults
  resolve_java_home
  log "Using TB_JAVA_HOME=$TB_JAVA_HOME"
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
    log "Backend relay disabled"
  fi
  start_agent
  wait_for_result || fail "Agent did not emit ~RESULT"
  start_agent_forwarder
  start_forwarder_5990

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
    fail "Forwarder on 5990 did not start"
  fi

  log "Stack startup complete"
  log "Use 'agent-stack.sh print-json' or 'agent-stack.sh print-link' to inspect live connection details explicitly"
}

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

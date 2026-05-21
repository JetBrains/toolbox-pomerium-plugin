#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASSWORD="${PASSWORD:-dev}"
POMERIUM_COMPOSE_FILE="${POMERIUM_COMPOSE_FILE:-$SCRIPT_DIR/../docker/docker-compose.pomerium.yml}"
COMPOSE_SERVICE="${COMPOSE_SERVICE:-helpers-upstream}"
HOST_FRONTEND_LOGS_DIR="${HOST_FRONTEND_LOGS_DIR:-$HOME/Library/Logs/JetBrains/IntelliJIdea2025.3/frontend}"
HOST_TOOLBOX_LOGS_DIR="${HOST_TOOLBOX_LOGS_DIR:-$HOME/Library/Logs/JetBrains/Toolbox}"

usage() {
  cat <<'EOF'
Usage:
  ./manage.sh recreate
  ./manage.sh restart-agent
  ./manage.sh stop-agent
  ./manage.sh logs
  ./manage.sh print-client-log-path
  ./manage.sh print-client-link
  ./manage.sh print-host-client-log-path
  ./manage.sh print-host-client-link
  ./manage.sh print-host-toolbox-tunnel-lines [--with-paths]
  ./manage.sh find-join-link [--with-paths]
  ./manage.sh print-link
  ./manage.sh print-json
  ./manage.sh check-current-link
  ./manage.sh check-connect [agent|backend]
  ./manage.sh check-auth <auth> [port]
  ./manage.sh check-auth '<jetbrains://...>'
  ./manage.sh check-auth-wrong [<jetbrains://...>]
  ./manage.sh probe-raw <auth> [port]
  ./manage.sh probe-raw '<jetbrains://...>' [port]
  ./manage.sh probe-current-link [connect-target]
  ./manage.sh probe-connect '<jetbrains://...>' [connect-target]
  ./manage.sh compare-current-link [raw-port] [connect-target]
  ./manage.sh clear-pomerium-jwt
  ./manage.sh shell
  ./manage.sh help
EOF
}

compose() {
  docker compose -f "$POMERIUM_COMPOSE_FILE" "$@"
}

REAL_SERVICES="helpers-upstream keycloak verify real-pomerium"

ensure_compose_file() {
  if [[ ! -f "$POMERIUM_COMPOSE_FILE" ]]; then
    echo "[manage] compose file not found: $POMERIUM_COMPOSE_FILE" >&2
    exit 1
  fi
}

build_image() {
  ensure_compose_file
  compose build "$COMPOSE_SERVICE"
}

start_services() {
  ensure_compose_file
  compose rm -sf mock-pomerium >/dev/null 2>&1 || true
  compose up -d --force-recreate $REAL_SERVICES
}

show_outputs() {
  ensure_compose_file
  compose logs --tail 200 $REAL_SERVICES
}

recreate() {
  build_image
  start_services
  echo "[manage] waiting for real stack startup output"
  wait_for_agent_info || true
  show_outputs
}

restart_agent() {
  ensure_compose_file
  compose exec -T -e POMERIUM_STACK_MODE="real" "$COMPOSE_SERVICE" bash -lc '/opt/helpers/docker/agent-stack.sh restart'
  echo "[manage] recent container logs"
  show_outputs
}

wait_for_agent_info() {
  ensure_compose_file
  local attempt
  for attempt in $(seq 1 60); do
    if compose exec -T "$COMPOSE_SERVICE" bash -lc 'test -s /home/dev/.local/share/JetBrains/Toolbox/agent-info.json' >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  echo "[manage] agent-info.json did not appear in time" >&2
  return 1
}

stop_agent() {
  ensure_compose_file
  compose exec -T "$COMPOSE_SERVICE" bash -lc '/opt/helpers/docker/agent-stack.sh stop'
  echo "[manage] recent container logs"
  show_outputs
}

raw_print_link() {
  ensure_compose_file
  wait_for_agent_info
  compose exec -T -e POMERIUM_STACK_MODE="real" "$COMPOSE_SERVICE" bash -lc '/opt/helpers/docker/agent-stack.sh print-link'
}

print_json() {
  ensure_compose_file
  wait_for_agent_info
  compose exec -T -e POMERIUM_STACK_MODE="real" "$COMPOSE_SERVICE" bash -lc '/opt/helpers/docker/agent-stack.sh print-json'
}

restart_agent_quiet() {
  ensure_compose_file
  compose exec -T -e POMERIUM_STACK_MODE="real" "$COMPOSE_SERVICE" bash -lc '/opt/helpers/docker/agent-stack.sh restart' >/dev/null
}

host_latest_client_log_path() {
  python3 -c '
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).expanduser()
if not root.exists() or not root.is_dir():
    raise SystemExit(1)

dirs = [p for p in root.iterdir() if p.is_dir()]
if not dirs:
    raise SystemExit(1)

dirs.sort(key=lambda p: p.stat().st_ctime, reverse=True)
for directory in dirs:
    idea_log = directory / "idea.log"
    if idea_log.is_file():
        print(idea_log)
        raise SystemExit(0)

raise SystemExit(1)
' "$HOST_FRONTEND_LOGS_DIR"
}

host_client_link() {
  python3 -c '
import pathlib
import sys

markers = [
    "New connection link received:",
    "Join link:",
]
root = pathlib.Path(sys.argv[1]).expanduser()
if not root.exists() or not root.is_dir():
    raise SystemExit(1)

dirs = [p for p in root.iterdir() if p.is_dir()]
if not dirs:
    raise SystemExit(1)

dirs.sort(key=lambda p: p.stat().st_ctime, reverse=True)
for directory in dirs:
    idea_log = directory / "idea.log"
    if not idea_log.is_file():
        continue
    try:
        lines = idea_log.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        continue
    for line in reversed(lines):
        for marker in markers:
            if marker in line:
                print(line.split(marker, 1)[1].strip())
                raise SystemExit(0)

raise SystemExit(1)
' "$HOST_FRONTEND_LOGS_DIR"
}

print_link() {
  local link
  link="$(raw_print_link)"
  printf '%s\n' "$link"
}

print_client_log_path() {
  ensure_compose_file
  compose exec -T "$COMPOSE_SERVICE" python3 -c '
import pathlib
import sys

roots = [
    pathlib.Path("/home/dev/.local/share/JetBrains/Toolbox/apps/intellij-idea"),
    pathlib.Path("/home/dev/.cache/JetBrains"),
    pathlib.Path("/home/dev"),
    pathlib.Path("/root"),
    pathlib.Path("/opt"),
]

idea_logs = []
for root in roots:
    if not root.exists():
        continue
    for path in root.rglob("idea.log"):
        try:
            if path.is_file():
                idea_logs.append(path)
        except OSError:
            pass

if not idea_logs:
    print("FAIL: idea.log not found", file=sys.stderr)
    raise SystemExit(1)

idea_logs.sort(key=lambda p: p.stat().st_mtime, reverse=True)
print(idea_logs[0])
'
}

print_client_link() {
  ensure_compose_file
  compose exec -T "$COMPOSE_SERVICE" python3 -c '
import pathlib
import sys

markers = [
    "New connection link received:",
    "Join link:",
]
roots = [
    pathlib.Path("/home/dev/.local/share/JetBrains/Toolbox/apps/intellij-idea"),
    pathlib.Path("/home/dev/.cache/JetBrains"),
    pathlib.Path("/home/dev"),
    pathlib.Path("/root"),
    pathlib.Path("/opt"),
]

idea_logs = []
for root in roots:
    if not root.exists():
        continue
    for path in root.rglob("idea.log"):
        try:
            if path.is_file():
                idea_logs.append(path)
        except OSError:
            pass

if not idea_logs:
    print("FAIL: idea.log not found", file=sys.stderr)
    raise SystemExit(1)

idea_logs.sort(key=lambda p: p.stat().st_mtime, reverse=True)

for log_path in idea_logs:
    try:
        lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        continue
    for line in reversed(lines):
        for marker in markers:
            if marker in line:
                print(line.split(marker, 1)[1].strip())
                raise SystemExit(0)

print("FAIL: connection link not found in idea.log", file=sys.stderr)
raise SystemExit(1)
'
}

print_host_client_log_path() {
  if ! host_latest_client_log_path; then
    echo "FAIL: host idea.log not found under $HOST_FRONTEND_LOGS_DIR" >&2
    return 1
  fi
}

print_host_client_link() {
  if ! host_client_link; then
    echo "FAIL: host connection link not found under $HOST_FRONTEND_LOGS_DIR" >&2
    return 1
  fi
}

print_host_toolbox_tunnel_lines() {
  local with_paths="false"
  if [[ "${1:-}" == "--with-paths" ]]; then
    with_paths="true"
  elif [[ -n "${1:-}" ]]; then
    echo "Usage: ./manage.sh print-host-toolbox-tunnel-lines [--with-paths]" >&2
    return 1
  fi

  python3 - <<'PY' "$HOST_TOOLBOX_LOGS_DIR" "$with_paths"
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).expanduser()
with_paths = sys.argv[2] == "true"
patterns = [
    "Starting local tunnel on 127.0.0.1:",
    "Starting tunnel to remote address:",
]

if not root.exists() or not root.is_dir():
    print(f"FAIL: Toolbox logs dir not found: {root}", file=sys.stderr)
    raise SystemExit(1)

log_files = []
for path in root.rglob("*.log"):
    try:
        if path.is_file():
            log_files.append(path)
    except OSError:
        pass

if not log_files:
    print(f"FAIL: no Toolbox log files found under {root}", file=sys.stderr)
    raise SystemExit(1)

results = {}
for log_path in sorted(log_files, key=lambda p: p.stat().st_mtime):
    try:
        lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        continue
    for line in lines:
        for pattern in patterns:
            if pattern in line:
                results[pattern] = (line[line.index(pattern):].strip(), str(log_path))

found_any = False
for pattern in patterns:
    value = results.get(pattern)
    label = "local-tunnel-line" if "local tunnel" in pattern else "remote-tunnel-line"
    if value is None:
        print(f"{label}: <not found>")
        continue
    found_any = True
    line, log_path = value
    print(f"{label}: {line}")
    if with_paths:
        path_label = "local-tunnel-log-path" if "local tunnel" in pattern else "remote-tunnel-log-path"
        print(f"{path_label}: {log_path}")

if not found_any:
    print("FAIL: tunnel lines not found in Toolbox logs", file=sys.stderr)
    raise SystemExit(1)
PY
}

find_join_link() {
  local with_paths="false"
  if [[ "${1:-}" == "--with-paths" ]]; then
    with_paths="true"
  elif [[ -n "${1:-}" ]]; then
    echo "Usage: ./manage.sh find-join-link [--with-paths]" >&2
    return 1
  fi

  local found_any="false"
  local client_link=""
  local client_log_path=""
  local host_link=""
  local host_log_path=""

  if client_link="$(print_client_link 2>/dev/null)"; then
    found_any="true"
    echo "container-link: $client_link"
    echo "container-source: container"
    if [[ "$with_paths" == "true" ]] && client_log_path="$(print_client_log_path 2>/dev/null)"; then
      echo "container-log-path: $client_log_path"
    fi
  else
    echo "container-link: <not found>"
  fi

  if host_link="$(print_host_client_link 2>/dev/null)"; then
    found_any="true"
    echo "host-link: $host_link"
    echo "host-source: host"
    if [[ "$with_paths" == "true" ]] && host_log_path="$(print_host_client_log_path 2>/dev/null)"; then
      echo "host-log-path: $host_log_path"
    fi
  else
    echo "host-link: <not found>"
  fi

  if [[ "$found_any" != "true" ]]; then
    echo "FAIL: no join link found in container or host logs" >&2
    return 1
  fi
}

check_current_link() {
  local link
  link="$(print_link)"

  local parsed
  parsed="$(python3 - <<'PY' "$link"
import sys
import urllib.parse

link = sys.argv[1]
parsed = urllib.parse.urlparse(link)
fragment = urllib.parse.parse_qs(parsed.fragment, keep_blank_values=True)

client_pomerium_route = fragment.get("clientPomeriumRoute", [""])[0]
agent_connection_url = fragment.get("agentConnectionUrl", [""])[0]
agent_auth = fragment.get("agentAuth", [""])[0]

missing = []
if not client_pomerium_route:
    missing.append("clientPomeriumRoute")
if not agent_connection_url:
    missing.append("agentConnectionUrl")
if not agent_auth:
    missing.append("agentAuth")

if missing:
    print(f"FAIL: real link is missing fields: {', '.join(missing)}")
    raise SystemExit(2)

decoded = urllib.parse.unquote(agent_connection_url)
agent_url = urllib.parse.urlparse(decoded)
host = agent_url.hostname
port = agent_url.port or 443

if not host:
    print("FAIL: agentConnectionUrl does not contain a host")
    raise SystemExit(3)

connect_host = "127.0.0.1" if host.endswith(".localhost") or host == "localhost" else host
print(f"{connect_host}\t{host}\t{port}")
PY
)"

  local connect_host sni_host port
  IFS=$'\t' read -r connect_host sni_host port <<<"$parsed"

  local output
  if ! output="$(openssl s_client -connect "${connect_host}:${port}" -servername "$sni_host" </dev/null 2>&1)"; then
    printf '%s\n' "$output"
    return 1
  fi

  if ! grep -q "CONNECTED" <<<"$output"; then
    printf '%s\n' "$output"
    echo "FAIL: openssl did not report a successful TCP/TLS connection" >&2
    return 1
  fi

  echo "OK: real link fields are present and TLS handshake succeeded on ${connect_host}:${port} with SNI ${sni_host}"
  grep -m 1 '^depth=0 ' <<<"$output" || true
}

probe_current_link() {
  local link
  link="$(print_link)"
  probe_connect "$link" "${1:-agent.localhost:443}"
}

probe_raw() {
  local auth_or_link="${1:-}"
  local port="${2:-44000}"

  if [[ -z "$auth_or_link" ]]; then
    echo "Usage: ./manage.sh probe-raw <auth> [port]" >&2
    echo "   or: ./manage.sh probe-raw '<jetbrains://...>' [port]" >&2
    return 1
  fi

  python3 - <<'PY' "$auth_or_link" "$port"
import json
import socket
import sys
import urllib.parse

auth_or_link = sys.argv[1]
port = int(sys.argv[2])
host = "127.0.0.1"

if auth_or_link.startswith("jetbrains://"):
    parsed = urllib.parse.urlparse(auth_or_link)
    fragment = urllib.parse.parse_qs(parsed.fragment, keep_blank_values=True)
    auth = fragment.get("agentAuth", [""])[0]
    if not auth:
        print("FAIL: link does not contain agentAuth")
        raise SystemExit(2)
else:
    auth = auth_or_link

print(f"endpoint=tcp://{host}:{port}")
print(f"auth_length={len(auth)}")

sock = socket.create_connection((host, port), timeout=5)
sock.settimeout(3)
sock.sendall(auth.encode("utf-8"))

chunks = []
try:
    while True:
        data = sock.recv(4096)
        if not data:
            break
        chunks.append(data)
except (TimeoutError, socket.timeout):
    pass
finally:
    sock.close()

payload = b"".join(chunks)
print("=== Agent payload summary ===")
print(f"bytes={len(payload)}")
print(f"repr={payload[:200]!r}")
print("=== Agent payload text ===")
if payload:
    text = payload.decode("utf-8", errors="replace")
    print(text)
    try:
        obj = json.loads(text)
        serialized = json.dumps(obj, ensure_ascii=False)
        if "hello" in serialized:
            print("RESULT: received JSON payload containing 'hello'")
        else:
            print("RESULT: received JSON payload, but it does not contain 'hello'")
    except Exception:
        print("RESULT: received non-JSON payload")
else:
    print("")
    print("RESULT: auth sent, no payload received before timeout/EOF")
PY
}

check_auth() {
  local auth_or_link="${1:-}"
  local port="${2:-44000}"

  if [[ -z "$auth_or_link" ]]; then
    echo "Usage: ./manage.sh check-auth <auth> [port]" >&2
    echo "   or: ./manage.sh check-auth '<jetbrains://...>'" >&2
    exit 1
  fi

  python3 - <<'PY' "$auth_or_link" "$port"
import socket
import ssl
import sys
import urllib.parse

auth_or_link = sys.argv[1]
default_port = int(sys.argv[2])
host = "127.0.0.1"
scheme = "tcp"

if auth_or_link.startswith("jetbrains://"):
    parsed = urllib.parse.urlparse(auth_or_link)
    fragment = urllib.parse.parse_qs(parsed.fragment, keep_blank_values=True)

    auth = fragment.get("agentAuth", [""])[0]
    if not auth:
        print("FAIL: link does not contain agentAuth")
        raise SystemExit(2)

    agent_connection_url = fragment.get("agentConnectionUrl", [""])[0]
    if agent_connection_url:
        parsed_agent_url = urllib.parse.urlparse(urllib.parse.unquote(agent_connection_url))
        scheme = (parsed_agent_url.scheme or "tcp").lower()
        host = parsed_agent_url.hostname or host
        port = parsed_agent_url.port or default_port
    else:
        port = default_port
else:
    auth = auth_or_link
    port = default_port

auth = auth.encode("utf-8")
connect_host = "localhost" if host.endswith(".localhost") or host == "localhost" else host

raw_sock = socket.create_connection((connect_host, port), timeout=5)
if scheme == "https":
    context = ssl._create_unverified_context()
    sock = context.wrap_socket(raw_sock, server_hostname=host)
else:
    sock = raw_sock

sock.settimeout(2)
sock.sendall(auth)

try:
    data = sock.recv(4096)
except socket.timeout:
    data = b""
finally:
    sock.close()

payload = data.decode("utf-8", errors="replace").strip()
if payload == "NAUTH":
    if scheme == "https":
        print(f"FAIL: agent rejected auth with NAUTH on {connect_host}:{port} with SNI {host}")
    else:
        print(f"FAIL: agent rejected auth with NAUTH on {host}:{port}")
    raise SystemExit(3)

if payload:
    if scheme == "https":
        print(f"OK: connected and received payload after auth on {connect_host}:{port} with SNI {host}")
    else:
        print(f"OK: connected and received payload after auth on {host}:{port}")
    print(payload)
    raise SystemExit(0)

if scheme == "https":
    print(f"OK: connected and sent auth to {connect_host}:{port} with SNI {host}")
else:
    print(f"OK: connected and sent auth to {host}:{port}")
print("NOTE: according to the real agent contract, sending the auth token alone does not guarantee an immediate hello response.")
PY
}
check_auth_wrong() {
  local link="${1:-}"

  if [[ -z "$link" ]]; then
    link="$(print_link)"
  fi

  python3 - <<'PY' "$link"
import socket
import ssl
import sys
import urllib.parse

link = sys.argv[1].strip()
if not link.startswith("jetbrains://"):
    print("FAIL: expected a jetbrains:// link")
    raise SystemExit(2)

parsed = urllib.parse.urlparse(link)
fragment = urllib.parse.parse_qs(parsed.fragment, keep_blank_values=True)
agent_connection_url = fragment.get("agentConnectionUrl", [""])[0]
if not agent_connection_url:
    print("FAIL: link does not contain agentConnectionUrl")
    raise SystemExit(3)

parsed_agent_url = urllib.parse.urlparse(urllib.parse.unquote(agent_connection_url))
host = parsed_agent_url.hostname or "127.0.0.1"
port = parsed_agent_url.port or 44000
scheme = (parsed_agent_url.scheme or "tcp").lower()
wrong_auth = b"wrong-auth-token"
connect_host = "localhost" if host.endswith(".localhost") or host == "localhost" else host

raw_sock = socket.create_connection((connect_host, port), timeout=5)
if scheme == "https":
    context = ssl._create_unverified_context()
    sock = context.wrap_socket(raw_sock, server_hostname=host)
else:
    sock = raw_sock

sock.settimeout(2)
sock.sendall(wrong_auth)

try:
    data = sock.recv(4096)
except socket.timeout:
    data = b""
finally:
    sock.close()

payload = data.decode("utf-8", errors="replace").strip()
if payload == "NAUTH":
    if scheme == "https":
        print(f"OK: wrong auth was rejected with NAUTH on {connect_host}:{port} with SNI {host}")
    else:
        print(f"OK: wrong auth was rejected with NAUTH on {host}:{port}")
    raise SystemExit(0)

if not payload:
    print("FAIL: wrong-auth probe did not receive NAUTH")
    raise SystemExit(4)

print("FAIL: wrong-auth probe received an unexpected payload")
print(payload)
raise SystemExit(5)
PY
}

probe_connect() {
  local link="${1:-}"
  local connect_target="${2:-agent.localhost:443}"

  if [[ -z "$link" ]]; then
    echo "Usage: ./manage.sh probe-connect '<jetbrains://...>' [connect-target]" >&2
    return 1
  fi

  python3 "$SCRIPT_DIR/py-check.py" --link "$link" --connect-target "$connect_target"
}

compare_current_link() {
  local raw_port="${1:-44000}"
  local connect_target="${2:-agent.localhost:443}"
  local link
  link="$(print_link)"

  echo "===== RAW TCP ====="
  probe_raw "$link" "$raw_port"
  echo
  echo "===== POMERIUM ROUTE ====="
  probe_connect "$link" "$connect_target"
}

clear_pomerium_jwt() {
  python3 - <<'PY'
import subprocess
import sys

service = "Toolbox"
account = (
    "jetbrains.toolbox.pomerium-Pomerium instance authenticate.localhost"
    "--NZfvY_b8z28Ka7f1bl3bJmWLy6Sot4d0Jupk6ygcFQ="
)

result = subprocess.run(
    ["security", "delete-generic-password", "-s", service, "-a", account],
    capture_output=True,
    text=True,
)

if result.returncode == 0:
    print("OK: deleted cached Pomerium JWT from macOS keychain")
    raise SystemExit(0)

stderr = (result.stderr or "").strip()
if "could not be found" in stderr.lower():
    print("OK: cached Pomerium JWT was already absent from macOS keychain")
    raise SystemExit(0)

print("FAIL: could not delete cached Pomerium JWT", file=sys.stderr)
if stderr:
    print(stderr, file=sys.stderr)
raise SystemExit(result.returncode or 1)
PY
}

shell_into() {
  ensure_compose_file
  compose exec "$COMPOSE_SERVICE" bash
}

check_connect() {
  local target="${1:-agent}"
  local route_host route_port sni_host

  case "$target" in
    agent)
      route_host="agent.localhost"
      route_port="443"
      sni_host="agent.localhost"
      ;;
    backend)
      route_host="backend.localhost"
      route_port="443"
      sni_host="backend.localhost"
      ;;
    *)
      echo "Usage: ./manage.sh check-connect [agent|backend]" >&2
      return 1
      ;;
  esac

  python3 - <<'PY' "$route_host" "$route_port" "$sni_host"
import socket
import ssl
import sys

route_host = sys.argv[1]
route_port = sys.argv[2]
sni_host = sys.argv[3]
token = "dev-token"

request = (
    f"CONNECT {route_host}:{route_port} HTTP/1.1\r\n"
    f"Host: {route_host}:{route_port}\r\n"
    f"Authorization: Pomerium {token}\r\n"
    "\r\n"
).encode("utf-8")

ctx = ssl._create_unverified_context()
raw = socket.create_connection(("127.0.0.1", 443), timeout=5)
sock = ctx.wrap_socket(raw, server_hostname=sni_host)
sock.settimeout(5)
sock.sendall(request)
response = sock.recv(4096).decode("utf-8", errors="replace")
sock.close()

print(response.strip())

if "200" not in response.splitlines()[0]:
    raise SystemExit(1)
PY
}

case "${1:-}" in
  recreate)
    recreate
    ;;
  restart-agent)
    restart_agent
    ;;
  stop-agent)
    stop_agent
    ;;
  logs)
    show_outputs
    ;;
  print-client-log-path)
    print_client_log_path
    ;;
  print-client-link)
    print_client_link
    ;;
  print-host-client-log-path)
    print_host_client_log_path
    ;;
  print-host-client-link)
    print_host_client_link
    ;;
  print-host-toolbox-tunnel-lines)
    shift
    print_host_toolbox_tunnel_lines "${1:-}"
    ;;
  find-join-link)
    shift
    find_join_link "${1:-}"
    ;;
  print-link)
    print_link
    ;;
  print-json)
    print_json
    ;;
  check-current-link)
    check_current_link
    ;;
  check-connect)
    check_connect "${2:-agent}"
    ;;
  check-auth)
    shift
    check_auth "${1:-}" "${2:-44000}"
    ;;
  check-auth-wrong)
    shift
    check_auth_wrong "${1:-}"
    ;;
  probe-raw)
    shift
    probe_raw "${1:-}" "${2:-44000}"
    ;;
  probe-current-link)
    shift
    probe_current_link "${1:-agent.localhost:443}"
    ;;
  probe-connect)
    shift
    probe_connect "${1:-}" "${2:-agent.localhost:443}"
    ;;
  compare-current-link)
    shift
    compare_current_link "${1:-44000}" "${2:-agent.localhost:443}"
    ;;
  clear-pomerium-jwt)
    clear_pomerium_jwt
    ;;
  shell)
    shell_into
    ;;
  help)
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac

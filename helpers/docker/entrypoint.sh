#!/usr/bin/env bash
set -euo pipefail

USERNAME="${USERNAME:-dev}"
PASSWORD="${PASSWORD:-dev}"
TBCLI_VERSION="${TBCLI_VERSION:-3.5.0.84344}"
TBCLI_PLATFORM_SUFFIX="${TBCLI_PLATFORM_SUFFIX:-}"
TOOLBOX_HOME="${TOOLBOX_HOME:-/home/$USERNAME}"
TOOLBOX_MODE="${TOOLBOX_MODE:-toolbox}"
TOOLBOX_DATA_DIR="${TOOLBOX_DATA_DIR:-$TOOLBOX_HOME/.local/share/JetBrains/Toolbox}"
TOOLBOX_COMPAT_DATA_DIR="${TOOLBOX_COMPAT_DATA_DIR:-$TOOLBOX_HOME/.local/share/JetBrains/Toolbox-Dev}"
TOOLBOX_CACHE_DIR="${TOOLBOX_CACHE_DIR:-$TOOLBOX_HOME/.cache/JetBrains/Toolbox-CLI-dist}"
IDEA_DIST_ROOT="${IDEA_DIST_ROOT:-/opt/idea-dist}"
HOST_IDEA_DIST_ROOT="${HOST_IDEA_DIST_ROOT:-/opt/helpers/host-idea-dist}"
HOST_IDEA_DIST_MODE="${HOST_IDEA_DIST_MODE:-}"
HOST_IDEA_DIST_SOURCE_NAME="${HOST_IDEA_DIST_SOURCE_NAME:-}"
HOST_IDEA_DIST_BASE_DIR_NAME="${HOST_IDEA_DIST_BASE_DIR_NAME:-}"
HOST_PROJECT_ROOT="${HOST_PROJECT_ROOT:-/opt/helpers/host-project}"
HOST_PROJECT_SOURCE_NAME="${HOST_PROJECT_SOURCE_NAME:-}"
CONTAINER_PROJECT_DIR="${CONTAINER_PROJECT_DIR:-$TOOLBOX_HOME/projects/test_project}"
USE_HOST_TBCLI="${USE_HOST_TBCLI:-1}"
HOST_TBCLI_DIR="${HOST_TBCLI_DIR:-/opt/helpers/host-tbcli}"
TBCLI_DIR="${TBCLI_DIR:-$TOOLBOX_CACHE_DIR/tbcli-$TBCLI_VERSION}"
TB_CLI_PATH="${TB_CLI_PATH:-$TBCLI_DIR/bin/tbcli}"
TB_JAVA_HOME="${TB_JAVA_HOME:-$JAVA_HOME}"
POMERIUM_STACK_MODE="${POMERIUM_STACK_MODE:-real}"
AGENT_LOG="$TOOLBOX_DATA_DIR/agent.log"
TOOLBOX_ENVIRONMENT_FILE="$TOOLBOX_DATA_DIR/environment.json"
TOOLBOX_PREINSTALLED_DIR="$TOOLBOX_DATA_DIR/preinstalled"
TOOLBOX_PREINSTALLED_FILE="$TOOLBOX_PREINSTALLED_DIR/toolbox-idea.json"
TOOLBOX_COMPAT_ENVIRONMENT_FILE="$TOOLBOX_COMPAT_DATA_DIR/environment.json"
TOOLBOX_COMPAT_PREINSTALLED_DIR="$TOOLBOX_COMPAT_DATA_DIR/preinstalled"
TOOLBOX_COMPAT_PREINSTALLED_FILE="$TOOLBOX_COMPAT_PREINSTALLED_DIR/toolbox-idea.json"
TOOLBOX_ENTERPRISE_CONFIG_FILE="$TOOLBOX_DATA_DIR/enterprise-config.json"
TOOLBOX_COMPAT_ENTERPRISE_CONFIG_FILE="$TOOLBOX_COMPAT_DATA_DIR/enterprise-config.json"
TOOLBOX_IDEA_INSTALLATION_ROOT=""
STAGED_ENTERPRISE_CONFIG_SOURCE=""
SKIP_TOOLBOX_ENTERPRISE_CONFIG="${SKIP_TOOLBOX_ENTERPRISE_CONFIG:-0}"

if [[ "$TOOLBOX_MODE" == "toolbox" ]]; then
  SKIP_TOOLBOX_ENTERPRISE_CONFIG="1"
fi

log() {
  printf '[helpers-upstream] %s\n' "$*"
}

fail() {
  log "ERROR: $*"
  if [[ -f "$AGENT_LOG" ]]; then
    log "Last agent log lines:"
    tail -n 200 "$AGENT_LOG" || true
  fi
  exit 1
}

materialize_idea_distribution() {
  mkdir -p "$IDEA_DIST_ROOT"

  if find "$IDEA_DIST_ROOT" -name product-info.json -print -quit 2>/dev/null | grep -q .; then
    log "IDE distribution already materialized under $IDEA_DIST_ROOT"
    return 0
  fi

  log "Materializing IDE distribution into $IDEA_DIST_ROOT"
  find "$IDEA_DIST_ROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

  case "$HOST_IDEA_DIST_MODE" in
    dir)
      [[ -d "$HOST_IDEA_DIST_ROOT" ]] || fail "Mounted IDEA dist root does not exist: $HOST_IDEA_DIST_ROOT"
      [[ -n "$HOST_IDEA_DIST_SOURCE_NAME" ]] || fail "HOST_IDEA_DIST_SOURCE_NAME is empty for dir mode"

      if [[ -n "$HOST_IDEA_DIST_BASE_DIR_NAME" ]] && [[ -d "$HOST_IDEA_DIST_ROOT/$HOST_IDEA_DIST_BASE_DIR_NAME" ]]; then
        cp -a "$HOST_IDEA_DIST_ROOT/$HOST_IDEA_DIST_BASE_DIR_NAME/." "$IDEA_DIST_ROOT/"
      fi

      [[ -d "$HOST_IDEA_DIST_ROOT/$HOST_IDEA_DIST_SOURCE_NAME" ]] || fail "Mounted IDEA dist dir is missing: $HOST_IDEA_DIST_ROOT/$HOST_IDEA_DIST_SOURCE_NAME"
      cp -a "$HOST_IDEA_DIST_ROOT/$HOST_IDEA_DIST_SOURCE_NAME/." "$IDEA_DIST_ROOT/"
      ;;
    archive)
      [[ -d "$HOST_IDEA_DIST_ROOT" ]] || fail "Mounted IDEA dist root does not exist: $HOST_IDEA_DIST_ROOT"
      [[ -n "$HOST_IDEA_DIST_SOURCE_NAME" ]] || fail "HOST_IDEA_DIST_SOURCE_NAME is empty for archive mode"

      local archive="$HOST_IDEA_DIST_ROOT/$HOST_IDEA_DIST_SOURCE_NAME"
      [[ -f "$archive" ]] || fail "Mounted IDEA dist archive is missing: $archive"

      case "$archive" in
        *.tar.gz)
          tar -xzf "$archive" -C "$IDEA_DIST_ROOT"
          ;;
        *.sit)
          unzip -q "$archive" -d "$IDEA_DIST_ROOT"
          ;;
        *)
          fail "Unsupported IDEA archive format: $archive"
          ;;
      esac
      ;;
    *)
      fail "Unsupported IDEA dist source mode: ${HOST_IDEA_DIST_MODE:-<empty>}"
      ;;
  esac

  find "$IDEA_DIST_ROOT" -name product-info.json -print -quit 2>/dev/null | grep -q . \
    || fail "IDE distribution was materialized, but product-info.json was not found under $IDEA_DIST_ROOT"
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

resolve_idea_installation_root() {
  [[ -d "$IDEA_DIST_ROOT" ]] || fail "IDEA_DIST_ROOT does not exist: $IDEA_DIST_ROOT"

  TOOLBOX_IDEA_INSTALLATION_ROOT="$(python3 - <<'PY' "$IDEA_DIST_ROOT"
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
candidates = []

direct_product_info = root / "product-info.json"
if direct_product_info.is_file():
    candidates.append(root)

for product_info in root.rglob("product-info.json"):
    parent = product_info.parent
    if parent not in candidates:
        candidates.append(parent)

for candidate in candidates:
    product_info = candidate / "product-info.json"
    bin_dir = candidate / "bin"
    lib_dir = candidate / "lib"
    if not (product_info.is_file() and bin_dir.is_dir() and lib_dir.is_dir()):
        continue
    try:
        payload = json.loads(product_info.read_text(encoding="utf-8"))
    except Exception:
        continue
    if payload.get("productCode"):
        print(candidate)
        raise SystemExit(0)

raise SystemExit(1)
PY
)" || fail "Could not resolve IDE installation root under $IDEA_DIST_ROOT"

  log "Resolved IDE installation root: $TOOLBOX_IDEA_INSTALLATION_ROOT"
}

copy_host_project() {
  if [[ -z "$HOST_PROJECT_SOURCE_NAME" ]]; then
    log "No host project copy was requested"
    return 0
  fi

  [[ -d "$HOST_PROJECT_ROOT" ]] || fail "Mounted host project root does not exist: $HOST_PROJECT_ROOT"
  [[ -d "$HOST_PROJECT_ROOT/$HOST_PROJECT_SOURCE_NAME" ]] || fail "Mounted host project dir is missing: $HOST_PROJECT_ROOT/$HOST_PROJECT_SOURCE_NAME"

  mkdir -p "$(dirname "$CONTAINER_PROJECT_DIR")"
  rm -rf "$CONTAINER_PROJECT_DIR"
  cp -a "$HOST_PROJECT_ROOT/$HOST_PROJECT_SOURCE_NAME" "$CONTAINER_PROJECT_DIR"
  chown -R "$USERNAME:$USERNAME" "$CONTAINER_PROJECT_DIR"
  log "Copied host project from $HOST_PROJECT_ROOT/$HOST_PROJECT_SOURCE_NAME to $CONTAINER_PROJECT_DIR"
}

configure_toolbox_enterprise_config() {
  if [[ "$SKIP_TOOLBOX_ENTERPRISE_CONFIG" == "1" ]]; then
    log "Skipping enterprise-config.json installation"
    return 0
  fi

  if [[ -z "${STAGED_ENTERPRISE_CONFIG_SOURCE:-}" ]]; then
    log "No staged enterprise-config.json was provided"
    return 0
  fi

  [[ -f "$STAGED_ENTERPRISE_CONFIG_SOURCE" ]] || fail "Staged enterprise config is missing: $STAGED_ENTERPRISE_CONFIG_SOURCE"

  install -D -m 0644 "$STAGED_ENTERPRISE_CONFIG_SOURCE" "$TOOLBOX_ENTERPRISE_CONFIG_FILE"
  install -D -m 0644 "$STAGED_ENTERPRISE_CONFIG_SOURCE" "$TOOLBOX_COMPAT_ENTERPRISE_CONFIG_FILE"
  chown "$USERNAME:$USERNAME" "$TOOLBOX_ENTERPRISE_CONFIG_FILE" "$TOOLBOX_COMPAT_ENTERPRISE_CONFIG_FILE"
  log "Installed enterprise config to $TOOLBOX_ENTERPRISE_CONFIG_FILE and $TOOLBOX_COMPAT_ENTERPRISE_CONFIG_FILE"
}

mkdir -p "$TOOLBOX_DATA_DIR" "$TOOLBOX_COMPAT_DATA_DIR" "$TOOLBOX_CACHE_DIR"
chown -R "$USERNAME:$USERNAME" "$TOOLBOX_HOME"
echo "$USERNAME:$PASSWORD" | chpasswd

download_tbcli() {
  if [[ -x "$TB_CLI_PATH" ]]; then
    log "tbcli already present at $TB_CLI_PATH"
    return
  fi

  if [[ -z "$TBCLI_PLATFORM_SUFFIX" ]]; then
    case "$(uname -m)" in
      aarch64|arm64)
        TBCLI_PLATFORM_SUFFIX="linux-aarch64"
        ;;
      x86_64|amd64)
        TBCLI_PLATFORM_SUFFIX="linux-x64"
        ;;
      *)
        fail "Unsupported Linux architecture for tbcli download: $(uname -m)"
        ;;
    esac
  fi

  local archive="$TOOLBOX_CACHE_DIR/tbcli-$TBCLI_PLATFORM_SUFFIX-$TBCLI_VERSION.tar.gz"
  local url="https://download.jetbrains.com/toolbox/agent/tbcli-$TBCLI_PLATFORM_SUFFIX-$TBCLI_VERSION.tar.gz"
  log "Downloading tbcli $TBCLI_VERSION from JetBrains $url"
  curl -fsSL "$url" -o "$archive"
  rm -rf "$TBCLI_DIR"
  mkdir -p "$TBCLI_DIR"
  tar -xzf "$archive" -C "$TBCLI_DIR" --strip-components 1
  chown -R "$USERNAME:$USERNAME" "$TOOLBOX_CACHE_DIR"
  log "tbcli extracted to $TBCLI_DIR"
}

resolve_tbcli() {
  if [[ "$USE_HOST_TBCLI" == "1" ]]; then
    TBCLI_DIR="$HOST_TBCLI_DIR"
    TB_CLI_PATH="$TBCLI_DIR/bin/tbcli"
    [[ -x "$TB_CLI_PATH" ]] || fail "host-mounted tbcli was requested but not found at $TB_CLI_PATH"
    log "Using host-mounted tbcli at $TB_CLI_PATH"
    return
  fi

  download_tbcli
}

configure_toolbox_environment() {
  [[ -n "${TOOLBOX_IDEA_INSTALLATION_ROOT:-}" ]] || fail "IDE installation root is not resolved"

  python3 - <<'PY' "$TOOLBOX_ENVIRONMENT_FILE" "$TOOLBOX_COMPAT_ENVIRONMENT_FILE" "$TOOLBOX_IDEA_INSTALLATION_ROOT"
import json
import pathlib
import sys

environment_paths = [pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])]
additional_path = pathlib.Path(sys.argv[3])

payload = {
    "tools": {
        "location": [
            {
                "path": str(additional_path),
                "levels": 4
            }
        ]
    }
}

for environment_path in environment_paths:
    environment_path.parent.mkdir(parents=True, exist_ok=True)
    environment_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY

  chown "$USERNAME:$USERNAME" "$TOOLBOX_ENVIRONMENT_FILE" "$TOOLBOX_COMPAT_ENVIRONMENT_FILE"
  log "Configured Toolbox additional tool path via $TOOLBOX_ENVIRONMENT_FILE and $TOOLBOX_COMPAT_ENVIRONMENT_FILE -> $TOOLBOX_IDEA_INSTALLATION_ROOT"
}

configure_toolbox_preinstalled() {
  [[ -n "${TOOLBOX_IDEA_INSTALLATION_ROOT:-}" ]] || fail "IDE installation root is not resolved"

  python3 - <<'PY' "$TOOLBOX_PREINSTALLED_FILE" "$TOOLBOX_COMPAT_PREINSTALLED_FILE" "$TOOLBOX_IDEA_INSTALLATION_ROOT"
import json
import pathlib
import sys

preinstalled_paths = [pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])]
installation_directory = pathlib.Path(sys.argv[3])

payload = {
    "installationDirectory": str(installation_directory)
}

for preinstalled_path in preinstalled_paths:
    preinstalled_path.parent.mkdir(parents=True, exist_ok=True)
    preinstalled_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY

  chown -R "$USERNAME:$USERNAME" "$TOOLBOX_PREINSTALLED_DIR" "$TOOLBOX_COMPAT_PREINSTALLED_DIR"
  log "Configured Toolbox preinstalled tool via $TOOLBOX_PREINSTALLED_FILE and $TOOLBOX_COMPAT_PREINSTALLED_FILE -> $TOOLBOX_IDEA_INSTALLATION_ROOT"
}

log "Preparing container for user $USERNAME"
resolve_tbcli
materialize_idea_distribution
resolve_idea_installation_root
copy_host_project
configure_toolbox_enterprise_config
configure_toolbox_environment
configure_toolbox_preinstalled
resolve_java_home
export TB_CLI_PATH TBCLI_DIR TB_JAVA_HOME USE_HOST_TBCLI HOST_TBCLI_DIR IDEA_DIST_ROOT TOOLBOX_IDEA_INSTALLATION_ROOT TOOLBOX_ENVIRONMENT_FILE TOOLBOX_PREINSTALLED_FILE TOOLBOX_COMPAT_DATA_DIR TOOLBOX_COMPAT_ENVIRONMENT_FILE TOOLBOX_COMPAT_PREINSTALLED_FILE TOOLBOX_ENTERPRISE_CONFIG_FILE TOOLBOX_COMPAT_ENTERPRISE_CONFIG_FILE SKIP_TOOLBOX_ENTERPRISE_CONFIG CONTAINER_PROJECT_DIR
log "Using TB_JAVA_HOME=$TB_JAVA_HOME"
log "Starting sshd on port 22"
/usr/sbin/sshd
python3 /opt/helpers/docker/watch_port.py &
POMERIUM_STACK_MODE="$POMERIUM_STACK_MODE" /opt/helpers/docker/agent-stack.sh start || fail "Agent stack startup failed"

log "Streaming Toolbox Agent log"
tail -F "$AGENT_LOG"

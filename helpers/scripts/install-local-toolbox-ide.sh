#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

LOCAL_TOOLBOX_IDE_DIST_DIR="${LOCAL_TOOLBOX_IDE_DIST_DIR:-}"
LOCAL_TOOLBOX_APP_SOURCE_PATH="${LOCAL_TOOLBOX_APP_SOURCE_PATH:-}"
LOCAL_TOOLBOX_APPS_ROOT="${LOCAL_TOOLBOX_APPS_ROOT:-$HOME/Library/Application Support/JetBrains/Toolbox/apps}"
LOCAL_TOOLBOX_PREINSTALLED_DIR="${LOCAL_TOOLBOX_PREINSTALLED_DIR:-$HOME/Library/Application Support/JetBrains/Toolbox/preinstalled}"
LOCAL_TOOLBOX_PREINSTALLED_FILE="${LOCAL_TOOLBOX_PREINSTALLED_FILE:-$LOCAL_TOOLBOX_PREINSTALLED_DIR/source-idea.json}"
LOCAL_TOOLBOX_ENVIRONMENT_FILE="${LOCAL_TOOLBOX_ENVIRONMENT_FILE:-$HOME/Library/Application Support/JetBrains/Toolbox/environment.json}"

log() {
  printf '[install-local-toolbox-ide] %s\n' "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

usage() {
  cat <<EOF
Usage:
  ./install-local-toolbox-ide.sh copy-from-toolbox
  ./install-local-toolbox-ide.sh install-from-toolbox
  ./install-local-toolbox-ide.sh install
  ./install-local-toolbox-ide.sh remove
  ./install-local-toolbox-ide.sh status
  ./install-local-toolbox-ide.sh help

Defaults:
  local env file:      $MANAGE_LOCAL_ENV_FILE
  IDE dist dir:        $LOCAL_TOOLBOX_IDE_DIST_DIR
  Toolbox app source:  ${LOCAL_TOOLBOX_APP_SOURCE_PATH:-auto-discover in $LOCAL_TOOLBOX_APPS_ROOT}
  preinstalled file:   $LOCAL_TOOLBOX_PREINSTALLED_FILE
  environment file:    $LOCAL_TOOLBOX_ENVIRONMENT_FILE
EOF
}

ensure_ide_dist() {
  [[ -n "$LOCAL_TOOLBOX_IDE_DIST_DIR" ]] || fail "LOCAL_TOOLBOX_IDE_DIST_DIR is required. Set it in helpers/state/local-idea.local.env."
  [[ -d "$LOCAL_TOOLBOX_IDE_DIST_DIR" ]] || fail "IDE dist dir does not exist: $LOCAL_TOOLBOX_IDE_DIST_DIR"
  [[ -d "$LOCAL_TOOLBOX_IDE_DIST_DIR/bin" ]] || fail "IDE dist dir does not look valid (missing bin): $LOCAL_TOOLBOX_IDE_DIST_DIR"
}

resolve_toolbox_app_source() {
  local resolved_path="${LOCAL_TOOLBOX_APP_SOURCE_PATH:-}"

  if [[ -n "$resolved_path" ]]; then
    [[ -d "$resolved_path" ]] || fail "Configured Toolbox app source does not exist: $resolved_path"
  else
    resolved_path="$(python3 - <<'PY' "$LOCAL_TOOLBOX_APPS_ROOT"
import pathlib
import sys

apps_root = pathlib.Path(sys.argv[1]).expanduser()
if not apps_root.is_dir():
    raise SystemExit(1)

patterns = [
    "IDEA-U/ch-*/*/IntelliJ IDEA*.app",
    "IDEA-U/ch-*/*/*.app",
]

candidates = []
for pattern in patterns:
    for path in apps_root.glob(pattern):
        contents = path / "Contents"
        info_plist = contents / "Info.plist"
        if not info_plist.is_file():
            continue
        try:
            candidates.append((path.stat().st_mtime, path))
        except OSError:
            pass

if not candidates:
    raise SystemExit(1)

candidates.sort(reverse=True)
print(candidates[0][1])
PY
)" || fail "Could not auto-discover IntelliJ IDEA app under $LOCAL_TOOLBOX_APPS_ROOT"
  fi

  [[ -d "$resolved_path/Contents" ]] || fail "Toolbox app source does not look valid (missing Contents): $resolved_path"
  printf '%s\n' "$resolved_path"
}

copy_from_toolbox() {
  local source_app_path="$1"

  python3 - <<'PY' "$source_app_path" "$LOCAL_TOOLBOX_IDE_DIST_DIR"
import pathlib
import shutil
import sys

source_app = pathlib.Path(sys.argv[1]).expanduser()
target_dir = pathlib.Path(sys.argv[2]).expanduser()
source_contents = source_app / "Contents"

if not source_contents.is_dir():
    raise SystemExit(f"Toolbox app source is invalid: {source_app}")

target_dir.parent.mkdir(parents=True, exist_ok=True)
if target_dir.exists():
    shutil.rmtree(target_dir)

shutil.copytree(source_contents, target_dir, symlinks=True)
print(target_dir)
PY

  log "Copied Toolbox app dist to: $LOCAL_TOOLBOX_IDE_DIST_DIR"
}

write_preinstalled_file() {
  mkdir -p "$LOCAL_TOOLBOX_PREINSTALLED_DIR"

  python3 - <<'PY' "$LOCAL_TOOLBOX_PREINSTALLED_FILE" "$LOCAL_TOOLBOX_IDE_DIST_DIR"
import json
import pathlib
import sys

output_path = pathlib.Path(sys.argv[1]).expanduser()
installation_directory = pathlib.Path(sys.argv[2]).expanduser()

payload = {
    "installationDirectory": str(installation_directory)
}

output_path.parent.mkdir(parents=True, exist_ok=True)
output_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY

  log "Wrote preinstalled file: $LOCAL_TOOLBOX_PREINSTALLED_FILE"
}

write_environment_file() {
  python3 - <<'PY' "$LOCAL_TOOLBOX_ENVIRONMENT_FILE" "$LOCAL_TOOLBOX_IDE_DIST_DIR"
import json
import pathlib
import sys

environment_path = pathlib.Path(sys.argv[1]).expanduser()
additional_path = str(pathlib.Path(sys.argv[2]).expanduser())

payload = {}
if environment_path.exists():
    try:
        payload = json.loads(environment_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        payload = {}

tools = payload.setdefault("tools", {})
locations = tools.setdefault("location", [])
filtered = [entry for entry in locations if entry.get("path") != additional_path]
filtered.append({"path": additional_path})
tools["location"] = filtered

environment_path.parent.mkdir(parents=True, exist_ok=True)
environment_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY

  log "Updated environment file: $LOCAL_TOOLBOX_ENVIRONMENT_FILE"
}

remove_preinstalled_file() {
  if [[ -f "$LOCAL_TOOLBOX_PREINSTALLED_FILE" ]]; then
    rm -f "$LOCAL_TOOLBOX_PREINSTALLED_FILE"
    log "Removed preinstalled file: $LOCAL_TOOLBOX_PREINSTALLED_FILE"
  else
    log "Preinstalled file is already absent"
  fi
}

remove_environment_path() {
  python3 - <<'PY' "$LOCAL_TOOLBOX_ENVIRONMENT_FILE" "$LOCAL_TOOLBOX_IDE_DIST_DIR"
import json
import pathlib
import sys

environment_path = pathlib.Path(sys.argv[1]).expanduser()
additional_path = str(pathlib.Path(sys.argv[2]).expanduser())

if not environment_path.exists():
    raise SystemExit(0)

payload = json.loads(environment_path.read_text(encoding="utf-8"))
tools = payload.get("tools")
if not isinstance(tools, dict):
    raise SystemExit(0)

locations = tools.get("location")
if not isinstance(locations, list):
    raise SystemExit(0)

filtered = [entry for entry in locations if entry.get("path") != additional_path]
tools["location"] = filtered
environment_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY

  log "Removed IDE path from environment file if it was present"
}

print_status() {
  python3 - <<'PY' "$LOCAL_TOOLBOX_PREINSTALLED_FILE" "$LOCAL_TOOLBOX_ENVIRONMENT_FILE" "$LOCAL_TOOLBOX_IDE_DIST_DIR"
import json
import pathlib
import sys

preinstalled_path = pathlib.Path(sys.argv[1]).expanduser()
environment_path = pathlib.Path(sys.argv[2]).expanduser()
idea_path = str(pathlib.Path(sys.argv[3]).expanduser())

print(f"ide_dist_exists={'yes' if pathlib.Path(idea_path).is_dir() else 'no'}")
print(f"preinstalled_file_exists={'yes' if preinstalled_path.is_file() else 'no'}")
if preinstalled_path.is_file():
    print(preinstalled_path.read_text(encoding='utf-8').strip())

print(f"environment_file_exists={'yes' if environment_path.is_file() else 'no'}")
if environment_path.is_file():
    payload = json.loads(environment_path.read_text(encoding='utf-8'))
    locations = payload.get('tools', {}).get('location', [])
    has_path = any(entry.get('path') == idea_path for entry in locations if isinstance(entry, dict))
    print(f"environment_contains_idea_path={'yes' if has_path else 'no'}")
PY
}

install_local_ide() {
  ensure_ide_dist
  write_preinstalled_file
  write_environment_file
  log "Registered local IDE dist for Toolbox: $LOCAL_TOOLBOX_IDE_DIST_DIR"
}

copy_local_ide_from_toolbox() {
  local source_app_path=""
  source_app_path="$(resolve_toolbox_app_source)"
  copy_from_toolbox "$source_app_path"
}

install_local_ide_from_toolbox() {
  copy_local_ide_from_toolbox
  install_local_ide
}

remove_local_ide() {
  remove_preinstalled_file
  remove_environment_path
}

case "${1:-help}" in
  copy-from-toolbox)
    shift
    [[ $# -eq 0 ]] || fail "copy-from-toolbox does not accept arguments"
    copy_local_ide_from_toolbox
    ;;
  install-from-toolbox)
    shift
    [[ $# -eq 0 ]] || fail "install-from-toolbox does not accept arguments"
    install_local_ide_from_toolbox
    ;;
  install)
    shift
    [[ $# -eq 0 ]] || fail "install does not accept arguments"
    install_local_ide
    ;;
  remove)
    shift
    [[ $# -eq 0 ]] || fail "remove does not accept arguments"
    remove_local_ide
    ;;
  status)
    shift
    [[ $# -eq 0 ]] || fail "status does not accept arguments"
    print_status
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

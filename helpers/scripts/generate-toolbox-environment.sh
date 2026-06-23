#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_OUTPUT="$SCRIPT_DIR/../state/toolbox-environment.json"
DEFAULT_IDE_PATH="/opt/idea-dist"

prompt() {
  local label="$1"
  local default_value="$2"
  local value

  if [[ -n "$default_value" ]]; then
    read -r -p "$label [$default_value]: " value
    printf '%s\n' "${value:-$default_value}"
  else
    read -r -p "$label: " value
    printf '%s\n' "$value"
  fi
}

confirm() {
  local label="$1"
  local value

  read -r -p "$label [y/N]: " value
  case "$value" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

output_path="${1:-}"
if [[ -z "$output_path" ]]; then
  output_path="$(prompt "Output environment.json path" "$DEFAULT_OUTPUT")"
fi

paths=()
while true; do
  ide_path="$(prompt "IDE distribution path as seen by Toolbox/upstream" "$DEFAULT_IDE_PATH")"
  if [[ -z "$ide_path" ]]; then
    echo "IDE path cannot be empty" >&2
    continue
  fi

  if [[ ! -e "$ide_path/product-info.json" ]] && ! find "$ide_path" -name product-info.json -print -quit 2>/dev/null | grep -q .; then
    if ! confirm "product-info.json was not found under '$ide_path'. Add this path anyway?"; then
      continue
    fi
  fi

  paths+=("$ide_path")
  confirm "Add another IDE path?" || break
done

python3 - <<'PY' "$output_path" "${paths[@]}"
import json
import pathlib
import sys

output = pathlib.Path(sys.argv[1]).expanduser()
paths = sys.argv[2:]

payload = {
    "tools": {
        "location": [{"path": path} for path in paths]
    }
}

output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
print(output)
PY

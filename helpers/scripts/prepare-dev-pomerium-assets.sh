#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POMERIUM_REAL_DIR="$SCRIPT_DIR/../pomerium/real"
CERTS_DIR="$POMERIUM_REAL_DIR/certs"
TEMPLATE_PATH="$POMERIUM_REAL_DIR/config.template.yaml"
CONFIG_PATH="$POMERIUM_REAL_DIR/config.yaml"
ENV_PATH="$SCRIPT_DIR/../state/pomerium-real.local.env"

log() {
  printf '[prepare-dev-pomerium-assets] %s\n' "$*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf '[prepare-dev-pomerium-assets] ERROR: required command not found: %s\n' "$1" >&2
    exit 1
  }
}

random_urlsafe() {
  python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
}

base64_no_wrap() {
  openssl base64 -A
}

ensure_env_file() {
  if [[ -f "$ENV_PATH" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_PATH"
  fi

  : "${POMERIUM_SHARED_SECRET:=$(random_urlsafe)}"
  : "${POMERIUM_COOKIE_SECRET:=$(random_urlsafe)}"
  : "${POMERIUM_IDP_CLIENT_SECRET:=toolbox-pomerium-local-secret}"

  if [[ -z "${POMERIUM_SIGNING_KEY:-}" ]]; then
    POMERIUM_SIGNING_KEY="$(openssl ecparam -name prime256v1 -genkey -noout | base64_no_wrap)"
  fi

  cat > "$ENV_PATH" <<EOF_ENV
POMERIUM_SHARED_SECRET='${POMERIUM_SHARED_SECRET}'
POMERIUM_COOKIE_SECRET='${POMERIUM_COOKIE_SECRET}'
POMERIUM_SIGNING_KEY='${POMERIUM_SIGNING_KEY}'
POMERIUM_IDP_CLIENT_SECRET='${POMERIUM_IDP_CLIENT_SECRET}'
EOF_ENV
}

generate_config() {
  python3 - <<'PY' "$TEMPLATE_PATH" "$CONFIG_PATH"
import os
import re
import sys
from pathlib import Path

template = Path(sys.argv[1]).read_text()
out = re.sub(r'\$\{([A-Z0-9_]+)\}', lambda m: os.environ[m.group(1)], template)
Path(sys.argv[2]).write_text(out)
PY
}

generate_certs() {
  require_cmd mkcert
  mkdir -p "$CERTS_DIR"
  mkcert -install >/dev/null
  mkcert \
    -cert-file "$CERTS_DIR/localhost.pomerium.io.pem" \
    -key-file "$CERTS_DIR/localhost.pomerium.io-key.pem" \
    localhost.pomerium.io \
    authenticate.localhost.pomerium.io \
    verify.localhost.pomerium.io \
    backend.localhost.pomerium.io \
    agent.localhost.pomerium.io \
    authenticate.localhost \
    verify.localhost \
    backend.localhost \
    agent.localhost \
    localhost \
    127.0.0.1 >/dev/null
  cp "$(mkcert -CAROOT)/rootCA.pem" "$CERTS_DIR/mkcert-rootCA.pem"
}

main() {
  require_cmd python3
  require_cmd openssl
  [[ -f "$TEMPLATE_PATH" ]] || {
    printf '[prepare-dev-pomerium-assets] ERROR: template not found: %s\n' "$TEMPLATE_PATH" >&2
    exit 1
  }

  ensure_env_file
  export POMERIUM_SHARED_SECRET POMERIUM_COOKIE_SECRET POMERIUM_SIGNING_KEY POMERIUM_IDP_CLIENT_SECRET
  generate_config
  generate_certs

  log "Wrote $CONFIG_PATH"
  log "Wrote $ENV_PATH"
  log "Wrote certs into $CERTS_DIR"
}

main "$@"

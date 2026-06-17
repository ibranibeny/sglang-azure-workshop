#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 00-genkey.sh  (requirement #5 / FR-008)
# Generate — or rotate — the secret API key that protects the endpoint.
#
#   ./00-genkey.sh            Generate a key only if one does not exist yet.
#   ./00-genkey.sh --rotate   Overwrite the existing key with a fresh one.
#
# The key is written to $API_KEY_FILE (deploy/.secrets/api_key), which is
# git-ignored. The key value is never printed to stdout (FR-011).
# After rotating, re-run ./05-run-sglang.sh to apply it (restarts Caddy only).
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

command -v openssl >/dev/null || die "openssl not found. Install it to generate a key."

ROTATE=0
[[ "${1:-}" == "--rotate" ]] && ROTATE=1

mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

if [[ -f "$API_KEY_FILE" && "$ROTATE" -eq 0 ]]; then
  warn "API key already exists at $API_KEY_FILE. Use --rotate to replace it."
  log "Existing key kept. (value not shown)"
  exit 0
fi

# 32 bytes -> 64 hex chars (256-bit secret).
NEW_KEY="$(openssl rand -hex 32)"
umask 177
printf '%s' "$NEW_KEY" > "$API_KEY_FILE"
chmod 600 "$API_KEY_FILE"
unset NEW_KEY

if [[ "$ROTATE" -eq 1 ]]; then
  log "API key rotated. Re-run ./05-run-sglang.sh to apply (Caddy restarts; VM untouched)."
else
  log "API key generated at $API_KEY_FILE (value not shown; mode 600)."
fi
log "Load it into your shell with:  export API_KEY=\$(cat \"$API_KEY_FILE\")"

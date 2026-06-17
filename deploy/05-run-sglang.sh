#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 05-run-sglang.sh
# Launch (or restart) the secured SGLang endpoint on the VM:
#   - SGLang container serving Qwen3.6-27B across both H100 GPUs, bound to
#     loopback only (never exposed directly).
#   - Caddy container terminating TLS (HTTPS) and enforcing the secret API key,
#     reverse-proxying authenticated traffic to SGLang.
# Uses 'az vm run-command' so no SSH session is required.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" >/dev/null 2>&1 \
  || die "VM '$VM_NAME' does not exist. Run ./01-deploy.sh first."

# --- Preflight: secrets ----------------------------------------------------
[[ -f "$API_KEY_FILE" ]] || die "No API key found at $API_KEY_FILE. Run ./00-genkey.sh first."
[[ -n "$API_KEY" ]] || die "API_KEY is empty. Run ./00-genkey.sh (or export API_KEY)."
[[ -z "$HF_TOKEN" ]] && warn "HF_TOKEN is empty. If '$MODEL_PATH' is gated, the model download will fail. Export HF_TOKEN and re-run."

# Resolve the public IP up front: the self-signed certificate needs it in its
# SAN list, and 'az network public-ip show' works regardless of VM power state
# (the IP is Standard/Static).
PUBLIC_IP=$(az network public-ip show -g "$RESOURCE_GROUP" -n "$PUBLIC_IP_NAME" --query ipAddress -o tsv)
[[ -n "$PUBLIC_IP" ]] || die "Could not resolve public IP '$PUBLIC_IP_NAME'. Run ./01-deploy.sh first."

# --- Render the Caddyfile from the template --------------------------------
if [[ -n "$TLS_DOMAIN" ]]; then
  log "TLS mode: Let's Encrypt for domain '$TLS_DOMAIN'."
  SITE_ADDRESS="$TLS_DOMAIN"
  TLS_LINE=""
  SELF_SIGNED=0
  # Pin the ACME CA to Let's Encrypt production so Caddy does not fall back to
  # ZeroSSL (which requires a contact email and EAB). Let's Encrypt issues
  # without an email, so this works whether or not TLS_EMAIL is set.
  LE_CA="https://acme-v02.api.letsencrypt.org/directory"
  if [[ -n "$TLS_EMAIL" ]]; then
    GLOBAL_BLOCK=$'{\n\temail '"$TLS_EMAIL"$'\n\tacme_ca '"$LE_CA"$'\n}'
  else
    GLOBAL_BLOCK=$'{\n\tacme_ca '"$LE_CA"$'\n}'
    warn "TLS_EMAIL is empty; proceeding without an ACME contact email (Let's Encrypt allows this)."
  fi
else
  log "TLS mode: self-signed (no DNS name). Clients must trust the cert or use curl -k."
  SITE_ADDRESS=":${HTTPS_PORT}"
  # 'tls internal' cannot serve a cert when a client connects by IP (no SNI
  # hostname is sent), so Caddy aborts the handshake with a TLS internal error.
  # Use an explicit self-signed cert whose SAN includes the public IP instead;
  # it is generated on the VM (see the remote script) and served as the default
  # cert for the :443 site regardless of SNI.
  TLS_LINE="tls /etc/caddy/certs/cert.pem /etc/caddy/certs/key.pem"
  SELF_SIGNED=1
  GLOBAL_BLOCK=""
fi

RENDERED="$(sed \
  -e "s|__GLOBAL_BLOCK__|${GLOBAL_BLOCK//$'\n'/\\n}|g" \
  -e "s|__SITE_ADDRESS__|${SITE_ADDRESS}|g" \
  -e "s|__TLS_LINE__|${TLS_LINE}|g" \
  -e "s|__API_KEY__|${API_KEY}|g" \
  -e "s|__SGLANG_PORT__|${SGLANG_PORT}|g" \
  ./Caddyfile.tmpl)"
# Restore literal newlines from the global-block substitution.
RENDERED="${RENDERED//\\n/$'\n'}"
CADDYFILE_B64="$(printf '%s' "$RENDERED" | base64 | tr -d '\n')"
unset RENDERED

log "Ensuring VM is running..."
./02-start-vm.sh

# --- Remote launch script --------------------------------------------------
REMOTE_SCRIPT=$(cat <<EOF
set -e
# Wait for the NVIDIA driver to be ready (extension may still be installing).
for i in \$(seq 1 60); do
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then break; fi
  echo "waiting for GPU driver... (\$i)"; sleep 10
done
nvidia-smi || { echo "GPU driver not ready"; exit 1; }

# --- SGLang (loopback only) ---
# Leave an already-running model container in place so an API-key rotation
# (re-running this script) restarts only Caddy and does NOT reload the 27B model.
# Set FORCE_MODEL_RESTART=1 to force a model container recreate.
if [ "${FORCE_MODEL_RESTART:-0}" != "1" ] && [ "\$(docker inspect -f '{{.State.Running}}' sglang 2>/dev/null)" = "true" ]; then
  echo "SGLang container already running; leaving it in place (key rotation path)."
else
  docker pull ${SGLANG_IMAGE}
  docker rm -f sglang 2>/dev/null || true
  docker run -d --name sglang --restart unless-stopped \
    --gpus all --shm-size 32g --ipc=host \
    -p 127.0.0.1:${SGLANG_PORT}:${SGLANG_PORT} \
    -v /opt/hf-cache:/root/.cache/huggingface \
    -e HF_TOKEN=${HF_TOKEN} \
    -e SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN=1 \
    -e SGLANG_ENABLE_SPEC_V2=1 \
    -e TOKENIZERS_PARALLELISM=false \
    ${SGLANG_IMAGE} \
    python3 -m sglang.launch_server \
      --model-path ${MODEL_PATH} \
      --tp ${TP_SIZE} \
      --host 0.0.0.0 --port ${SGLANG_PORT} \
      --context-length 196608 \
      --mem-fraction-static 0.85 \
      --max-running-requests 4 \
      --chunked-prefill-size 8192 \
      --reasoning-parser qwen3 \
      --tool-call-parser qwen3_coder \
      --attention-backend fa3 \
      --sampling-backend flashinfer \
      --mamba-backend triton \
      --mamba-scheduler-strategy extra_buffer \
      --speculative-algorithm NEXTN \
      --speculative-num-steps 1 \
      --speculative-eagle-topk 1 \
      --speculative-num-draft-tokens 2 \
      --enable-metrics \
      --trust-remote-code
fi

# --- Caddy (HTTPS + API-key gateway) ---
mkdir -p /opt/caddy/data /opt/caddy/config /opt/caddy/certs
echo "${CADDYFILE_B64}" | base64 -d > /opt/caddy/Caddyfile
chmod 600 /opt/caddy/Caddyfile

# Generate a self-signed cert whose SAN covers the public IP (and loopback) so
# the TLS handshake succeeds for IP-based, no-SNI clients (curl -k, SDKs).
if [ "${SELF_SIGNED}" = "1" ]; then
  if [ ! -f /opt/caddy/certs/cert.pem ] || ! openssl x509 -checkend 86400 -noout -in /opt/caddy/certs/cert.pem >/dev/null 2>&1; then
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout /opt/caddy/certs/key.pem \
      -out /opt/caddy/certs/cert.pem \
      -days 825 -subj "/CN=${PUBLIC_IP}" \
      -addext "subjectAltName=IP:${PUBLIC_IP},IP:127.0.0.1,DNS:localhost"
    chmod 600 /opt/caddy/certs/key.pem
  fi
fi

docker pull ${CADDY_IMAGE}
docker rm -f caddy 2>/dev/null || true
docker run -d --name caddy --restart unless-stopped \
  --network host \
  -v /opt/caddy/Caddyfile:/etc/caddy/Caddyfile:ro \
  -v /opt/caddy/certs:/etc/caddy/certs:ro \
  -v /opt/caddy/data:/data \
  -v /opt/caddy/config:/config \
  ${CADDY_IMAGE}

echo "Containers started. SGLang on loopback:${SGLANG_PORT}; Caddy on :${HTTPS_PORT}."
echo "Tail model logs with: docker logs -f sglang"
EOF
)

log "Launching SGLang + Caddy on the VM (pulls images and downloads the model)..."
az vm run-command invoke \
  -g "$RESOURCE_GROUP" -n "$VM_NAME" \
  --command-id RunShellScript \
  --scripts "$REMOTE_SCRIPT" \
  --query "value[0].message" -o tsv

# PUBLIC_IP was resolved up front (above); reuse it for the endpoint host.
ENDPOINT_HOST="${TLS_DOMAIN:-$PUBLIC_IP}"

# --- Readiness wait (distinct from VM power state, FR-016) ------------------
log "Waiting for the model to finish loading (first run downloads weights; this can take many minutes)..."
READY=0
for i in $(seq 1 60); do
  CODE=$(curl -sk -o /dev/null -w '%{http_code}' "https://${ENDPOINT_HOST}:${HTTPS_PORT}/health" 2>/dev/null || true)
  if [[ "$CODE" == "200" ]]; then READY=1; break; fi
  sleep 30
done

if [[ "$READY" -eq 1 ]]; then
  log "Endpoint is READY and serving over HTTPS."
else
  warn "Readiness not confirmed yet (health check did not return 200). The model may still be loading."
  warn "Check progress on the VM with: docker logs -f sglang"
fi

log "OpenAI-compatible endpoint: https://${ENDPOINT_HOST}:${HTTPS_PORT}/v1"
log "Authenticated test (load the key first: export API_KEY=\$(cat \"$API_KEY_FILE\")):"
echo "  curl -k https://${ENDPOINT_HOST}:${HTTPS_PORT}/v1/chat/completions \\"
echo "    -H \"Authorization: Bearer \$API_KEY\" \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"$MODEL_PATH\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}'"

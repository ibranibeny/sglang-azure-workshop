#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Shared configuration for the SGLang + Qwen3.6-27B deployment on Azure.
# Edit values here, then source this file from the other scripts.
# Override any value at runtime, e.g.:  HF_TOKEN=hf_xxx ./01-deploy.sh
# ---------------------------------------------------------------------------

# --- Azure placement -------------------------------------------------------
export RESOURCE_GROUP="${RESOURCE_GROUP:-sglang-rg}"
export LOCATION="${LOCATION:-indonesiacentral}"

# --- VM -------------------------------------------------------------------
export VM_NAME="${VM_NAME:-sglang-h100}"
# 1x H100 NVL (94GB), 40 vCPUs. Chosen to fit the subscription's NCadsH100v5
# quota (40 vCPUs) in this region; a 27B model fits on a single 94GB H100.
# Exact SKU string is NC40ads (no 'i'); the 2-GPU variant is NC80adis (with 'i').
# For 2x H100 use Standard_NC80adis_H100_v5 (needs an 80-vCPU quota increase).
export VM_SIZE="${VM_SIZE:-Standard_NC40ads_H100_v5}"   # 1x H100 NVL (94GB) GPU
export ADMIN_USER="${ADMIN_USER:-azureuser}"
# Ubuntu 24.04 LTS Gen2. Run `az vm image list --offer ubuntu --all -o table` to change.
export VM_IMAGE="${VM_IMAGE:-Canonical:ubuntu-24_04-lts:server:latest}"
export OS_DISK_SIZE_GB="${OS_DISK_SIZE_GB:-512}"
# NVIDIA GPU driver extension (Microsoft.HpcCompute/NvidiaGpuDriverLinux) handler
# version, per the Microsoft Learn reference. The handler installs the latest
# compatible CUDA driver. Override only if you need a specific handler version.
# https://learn.microsoft.com/azure/virtual-machines/extensions/hpccompute-gpu-linux
export NVIDIA_EXT_VERSION="${NVIDIA_EXT_VERSION:-1.6}"

# --- Networking -----------------------------------------------------------
export VNET_NAME="${VNET_NAME:-sglang-vnet}"
export SUBNET_NAME="${SUBNET_NAME:-sglang-subnet}"
export NSG_NAME="${NSG_NAME:-sglang-nsg}"
export PUBLIC_IP_NAME="${PUBLIC_IP_NAME:-sglang-pip}"
export NIC_NAME="${NIC_NAME:-sglang-nic}"

# --- SGLang / model -------------------------------------------------------
export SGLANG_IMAGE="${SGLANG_IMAGE:-lmsysorg/sglang:latest}"
export SGLANG_PORT="${SGLANG_PORT:-30000}"   # bound to loopback only on the VM
export MODEL_PATH="${MODEL_PATH:-Qwen/Qwen3.6-35B-A3B-FP8}"
export TP_SIZE="${TP_SIZE:-1}"            # 1 GPU on NC40adis_H100_v5
# Hugging Face token (required if the model is gated). Export before running:
#   export HF_TOKEN=hf_xxxxxxxxxxxxxxxx
export HF_TOKEN="${HF_TOKEN:-}"

# --- HTTPS / API gateway (Caddy) ------------------------------------------
export HTTPS_PORT="${HTTPS_PORT:-443}"        # public TLS port (Caddy)
export CADDY_IMAGE="${CADDY_IMAGE:-caddy:2}"  # reverse proxy + TLS terminator
# Leave TLS_DOMAIN empty to use a self-signed certificate (default, no DNS
# name needed). Set it to a DNS name pointing at the public IP to switch Caddy
# to a publicly trusted Let's Encrypt certificate (TLS_EMAIL recommended).
# Configured: openai.contoso.day -> 70.153.148.66 (Cloudflare A record, DNS-only).
export TLS_DOMAIN="${TLS_DOMAIN:-openai.contoso.day}"
export TLS_EMAIL="${TLS_EMAIL:-}"

# --- Secrets --------------------------------------------------------------
# Directory holding generated secrets. MUST be git-ignored (see .gitignore).
export SECRETS_DIR="${SECRETS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.secrets}"
export API_KEY_FILE="${API_KEY_FILE:-$SECRETS_DIR/api_key}"
# API key is loaded from the secret file when present; generate it with
# ./00-genkey.sh. Override at runtime by exporting API_KEY directly.
if [[ -z "${API_KEY:-}" && -f "$API_KEY_FILE" ]]; then
  API_KEY="$(cat "$API_KEY_FILE")"
fi
export API_KEY="${API_KEY:-}"

# --- Helpers --------------------------------------------------------------
log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

# --- Azure CLI bridge for WSL behind Global Secure Access ------------------
# On corporate machines the Linux 'az' inside WSL cannot sign in: Microsoft
# Global Secure Access rewrites login.microsoftonline.com to a sentinel address
# that only the Windows host can tunnel, so every WSL-native token request fails
# with "Network is unreachable". The Windows-bundled Azure CLI is already signed
# in on the host, so we route 'az' to it through WSL interop. The bundled
# python.exe receives arguments as a clean argv array (no cmd.exe re-parsing), so
# multiline --scripts payloads and bracketed --query expressions pass through
# intact; relative file paths such as --custom-data ./cloud-init.yaml resolve
# against the Windows working directory because every script cd's into deploy/.
# Set AZ_USE_WINDOWS=0 to force the native Linux CLI on machines without GSA.
if [[ "${AZ_USE_WINDOWS:-auto}" != "0" ]] \
   && grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease 2>/dev/null; then
  _AZ_WIN_PY="${AZ_WIN_PY:-/mnt/c/Program Files/Microsoft SDKs/Azure/CLI2/python.exe}"
  if [[ -f "$_AZ_WIN_PY" ]]; then
    export AZ_WIN_PY="$_AZ_WIN_PY"
    az() { "${AZ_WIN_PY:-/mnt/c/Program Files/Microsoft SDKs/Azure/CLI2/python.exe}" -IBm azure.cli "$@"; }
    export -f az 2>/dev/null || true
    warn "Using Windows Azure CLI via WSL interop (Global Secure Access workaround). Set AZ_USE_WINDOWS=0 to disable."
  fi
fi

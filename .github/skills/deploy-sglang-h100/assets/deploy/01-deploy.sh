#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 01-deploy.sh
# Idempotent provisioning of the SGLang H100 VM.
#   - Creates the resource group, VNet/subnet, NSG (all ports open), public IP.
#   - If the VM already exists: starts it if deallocated/stopped (requirement #1).
#   - If the VM does not exist: creates it with cloud-init + NVIDIA driver.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

command -v az >/dev/null || die "Azure CLI (az) not found. Install it first."
az account show >/dev/null 2>&1 || die "Not logged in. Run 'az login'."

# --- Resource group --------------------------------------------------------
log "Ensuring resource group '$RESOURCE_GROUP' in '$LOCATION'..."
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none

# --- NSG (all ports open in + out) -----------------------------------------
log "Ensuring NSG '$NSG_NAME'..."
az network nsg create -g "$RESOURCE_GROUP" -n "$NSG_NAME" -l "$LOCATION" --output none
./03-open-nsg.sh

# --- Virtual network + subnet ---------------------------------------------
if ! az network vnet show -g "$RESOURCE_GROUP" -n "$VNET_NAME" >/dev/null 2>&1; then
  log "Creating VNet '$VNET_NAME' / subnet '$SUBNET_NAME'..."
  az network vnet create \
    -g "$RESOURCE_GROUP" -n "$VNET_NAME" -l "$LOCATION" \
    --address-prefixes 10.0.0.0/16 \
    --subnet-name "$SUBNET_NAME" --subnet-prefixes 10.0.0.0/24 \
    --output none
  az network vnet subnet update \
    -g "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" -n "$SUBNET_NAME" \
    --network-security-group "$NSG_NAME" --output none
fi

# --- If VM already exists: just (re)start it -------------------------------
if az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" >/dev/null 2>&1; then
  warn "VM '$VM_NAME' already exists. Skipping create; starting it if needed."
  ./02-start-vm.sh
  log "Done. Run ./05-run-sglang.sh to (re)launch the SGLang server."
  exit 0
fi

# --- Public IP -------------------------------------------------------------
log "Creating public IP '$PUBLIC_IP_NAME'..."
az network public-ip create \
  -g "$RESOURCE_GROUP" -n "$PUBLIC_IP_NAME" -l "$LOCATION" \
  --sku Standard --allocation-method Static --output none

# --- NIC -------------------------------------------------------------------
log "Creating NIC '$NIC_NAME'..."
az network nic create \
  -g "$RESOURCE_GROUP" -n "$NIC_NAME" -l "$LOCATION" \
  --vnet-name "$VNET_NAME" --subnet "$SUBNET_NAME" \
  --network-security-group "$NSG_NAME" \
  --public-ip-address "$PUBLIC_IP_NAME" --output none

# --- VM --------------------------------------------------------------------
log "Creating VM '$VM_NAME' ($VM_SIZE). This can take several minutes..."
az vm create \
  -g "$RESOURCE_GROUP" -n "$VM_NAME" -l "$LOCATION" \
  --size "$VM_SIZE" \
  --image "$VM_IMAGE" \
  --admin-username "$ADMIN_USER" \
  --generate-ssh-keys \
  --nics "$NIC_NAME" \
  --os-disk-size-gb "$OS_DISK_SIZE_GB" \
  --custom-data ./cloud-init.yaml \
  --output none

# --- NVIDIA GPU driver extension (idempotent) ------------------------------
# Installs the CUDA driver on the host via the Microsoft.HpcCompute
# 'NvidiaGpuDriverLinux' VM extension. Skipped if already provisioned.
# Command form follows the official Microsoft Learn reference:
# https://learn.microsoft.com/azure/virtual-machines/extensions/hpccompute-gpu-linux#deployment
EXT_STATE=$(az vm extension show \
  -g "$RESOURCE_GROUP" --vm-name "$VM_NAME" -n NvidiaGpuDriverLinux \
  --query "provisioningState" -o tsv 2>/dev/null || true)

if [[ "$EXT_STATE" == "Succeeded" ]]; then
  log "NVIDIA GPU driver extension already installed (state: $EXT_STATE). Skipping."
else
  log "Installing NVIDIA GPU driver extension (CUDA drivers)..."
  az vm extension set \
    -g "$RESOURCE_GROUP" --vm-name "$VM_NAME" \
    --name NvidiaGpuDriverLinux --publisher Microsoft.HpcCompute \
    --version "$NVIDIA_EXT_VERSION" --output none || \
    warn "Driver extension call returned non-zero; verify with 'nvidia-smi' on the VM."
fi

PUBLIC_IP=$(az network public-ip show -g "$RESOURCE_GROUP" -n "$PUBLIC_IP_NAME" --query ipAddress -o tsv)
log "VM ready. Public IP: $PUBLIC_IP"
log "Cloud-init (Docker + NVIDIA toolkit) and the GPU driver may still be finishing."
log "Next: ensure an API key exists (./00-genkey.sh), then run ./05-run-sglang.sh to start the model server."
log "OpenAI endpoint will be: https://$PUBLIC_IP:$HTTPS_PORT/v1 (HTTPS, API key required)."

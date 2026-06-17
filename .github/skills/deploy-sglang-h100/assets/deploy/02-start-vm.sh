#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 02-start-vm.sh  (requirement #1)
# Enable / allocate the VM if it is stopped or deallocated.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" >/dev/null 2>&1 \
  || die "VM '$VM_NAME' does not exist. Run ./01-deploy.sh first."

POWER=$(az vm get-instance-view -g "$RESOURCE_GROUP" -n "$VM_NAME" \
  --query "instanceView.statuses[?starts_with(code,'PowerState/')].code | [0]" -o tsv)
log "Current power state: ${POWER:-unknown}"

if [[ "$POWER" == "PowerState/running" ]]; then
  log "VM is already running. Nothing to do."
else
  log "Starting / allocating VM '$VM_NAME'..."
  az vm start -g "$RESOURCE_GROUP" -n "$VM_NAME" --output none
  log "VM started."
fi

PUBLIC_IP=$(az network public-ip show -g "$RESOURCE_GROUP" -n "$PUBLIC_IP_NAME" --query ipAddress -o tsv 2>/dev/null || true)
[[ -n "${PUBLIC_IP:-}" ]] && log "Public IP: $PUBLIC_IP"

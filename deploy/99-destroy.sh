#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 99-destroy.sh  (requirement #4)
# Tear down everything created by this deployment.
#   ./99-destroy.sh           -> delete the whole resource group (default)
#   ./99-destroy.sh --vm-only -> only deallocate the VM (stop billing for
#                                compute, keep disk/network so you can restart)
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

MODE="${1:-full}"

if [[ "$MODE" == "--vm-only" ]]; then
  log "Deallocating VM '$VM_NAME' (compute billing stops, resources kept)..."
  az vm deallocate -g "$RESOURCE_GROUP" -n "$VM_NAME" --output none
  log "VM deallocated. Restart later with ./02-start-vm.sh."
  exit 0
fi

az group show -n "$RESOURCE_GROUP" >/dev/null 2>&1 || die "Resource group '$RESOURCE_GROUP' not found."

warn "This will DELETE the entire resource group '$RESOURCE_GROUP' and ALL its resources."
read -r -p "Type the resource group name to confirm: " CONFIRM
[[ "$CONFIRM" == "$RESOURCE_GROUP" ]] || die "Confirmation did not match. Aborted."

log "Deleting resource group '$RESOURCE_GROUP'..."
az group delete -n "$RESOURCE_GROUP" --yes --no-wait
log "Deletion started (running in background). Check with: az group show -n $RESOURCE_GROUP"

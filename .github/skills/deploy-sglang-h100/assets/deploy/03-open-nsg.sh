#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 03-open-nsg.sh  (requirement #2)
# Open ALL ports, ALL protocols, inbound AND outbound on the NSG.
#
# !! SECURITY WARNING !!
# This exposes every port on the VM to the entire internet (0.0.0.0/0).
# Use only for short-lived testing. For anything real, restrict source IPs
# and limit to the ports you actually need (e.g. 22 and $SGLANG_PORT).
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

az network nsg show -g "$RESOURCE_GROUP" -n "$NSG_NAME" >/dev/null 2>&1 \
  || die "NSG '$NSG_NAME' not found. Run ./01-deploy.sh first."

warn "Opening ALL inbound and outbound ports on NSG '$NSG_NAME' (0.0.0.0/0)."

log "Creating Allow-All-Inbound rule..."
az network nsg rule create \
  -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" -n "AllowAllInbound" \
  --priority 100 --direction Inbound --access Allow \
  --protocol '*' --source-address-prefixes '*' --source-port-ranges '*' \
  --destination-address-prefixes '*' --destination-port-ranges '*' \
  --output none 2>/dev/null \
|| az network nsg rule update \
  -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" -n "AllowAllInbound" \
  --priority 100 --direction Inbound --access Allow \
  --protocol '*' --source-address-prefixes '*' --source-port-ranges '*' \
  --destination-address-prefixes '*' --destination-port-ranges '*' \
  --output none

log "Creating Allow-All-Outbound rule..."
az network nsg rule create \
  -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" -n "AllowAllOutbound" \
  --priority 100 --direction Outbound --access Allow \
  --protocol '*' --source-address-prefixes '*' --source-port-ranges '*' \
  --destination-address-prefixes '*' --destination-port-ranges '*' \
  --output none 2>/dev/null \
|| az network nsg rule update \
  -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" -n "AllowAllOutbound" \
  --priority 100 --direction Outbound --access Allow \
  --protocol '*' --source-address-prefixes '*' --source-port-ranges '*' \
  --destination-address-prefixes '*' --destination-port-ranges '*' \
  --output none

log "NSG '$NSG_NAME' now allows all inbound and outbound traffic."

#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 04-check-nsg.sh  (requirement #3)
# Inspect the NSG and verify the allow-all rules are present and effective.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

az network nsg show -g "$RESOURCE_GROUP" -n "$NSG_NAME" >/dev/null 2>&1 \
  || die "NSG '$NSG_NAME' not found. Run ./01-deploy.sh first."

log "Custom rules on NSG '$NSG_NAME':"
az network nsg rule list -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" \
  --query "sort_by([].{Name:name,Dir:direction,Access:access,Prio:priority,Proto:protocol,SrcPort:sourcePortRange,DstPort:destinationPortRange,Src:sourceAddressPrefix,Dst:destinationAddressPrefix}, &Prio)" \
  -o table

check_rule() {
  local dir="$1"
  local match
  match=$(az network nsg rule list -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" \
    --query "[?direction=='$dir' && access=='Allow' && protocol=='*' && (destinationPortRange=='*' || destinationPortRanges[0]=='*') && (sourceAddressPrefix=='*' || sourceAddressPrefixes[0]=='*')] | [0].name" -o tsv)
  if [[ -n "$match" && "$match" != "None" ]]; then
    log "OK  - $dir: allow-all rule present ('$match')."
  else
    warn "MISSING - $dir: no allow-all rule. Run ./03-open-nsg.sh to create it."
  fi
}

check_rule Inbound
check_rule Outbound

# Effective rules actually applied to the NIC (requires the VM to be running).
if az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" >/dev/null 2>&1; then
  log "Effective security rules on NIC '$NIC_NAME' (running VM only):"
  az network nic list-effective-nsg -g "$RESOURCE_GROUP" -n "$NIC_NAME" \
    --query "value[].effectiveSecurityRules[?access=='Allow' && (destinationPortRange=='0-65535' || destinationPortRange=='*')].{Name:name,Dir:direction,Access:access,DstPort:destinationPortRange}" \
    -o table 2>/dev/null \
    || warn "Could not read effective rules (VM may be deallocated)."
fi

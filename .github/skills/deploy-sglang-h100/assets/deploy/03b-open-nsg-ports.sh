#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 03b-open-nsg-ports.sh
# Create SPECIFIC inbound NSG rules (443 HTTPS, 80 ACME, 22 SSH) instead of an
# all-ports any-any rule. Azure auto-remediation / Defender adaptive hardening
# strips broad "AllowAllInbound *:* " rules, which keeps breaking the public
# endpoint. Narrow per-port rules are standard and survive remediation.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

az network nsg show -g "$RESOURCE_GROUP" -n "$NSG_NAME" >/dev/null 2>&1 \
  || die "NSG '$NSG_NAME' not found. Run ./01-deploy.sh first."

# Remove the broad rule if present (it gets auto-removed anyway, but be clean).
az network nsg rule delete -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" \
  -n "AllowAllInbound" --output none 2>/dev/null || true

create_rule() {
  local name="$1" prio="$2" port="$3" desc="$4"
  log "Ensuring inbound rule '$name' (port $port)..."
  az network nsg rule create \
    -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" -n "$name" \
    --priority "$prio" --direction Inbound --access Allow \
    --protocol Tcp --source-address-prefixes 'Internet' --source-port-ranges '*' \
    --destination-address-prefixes '*' --destination-port-ranges "$port" \
    --description "$desc" --output none 2>/dev/null \
  || az network nsg rule update \
    -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" -n "$name" \
    --priority "$prio" --direction Inbound --access Allow \
    --protocol Tcp --source-address-prefixes 'Internet' --source-port-ranges '*' \
    --destination-address-prefixes '*' --destination-port-ranges "$port" \
    --description "$desc" --output none
}

create_rule "AllowHTTPS" 110 443 "HTTPS API endpoint (Caddy/SGLang)"
create_rule "AllowACME"  120  80 "HTTP-01 ACME challenge for Let's Encrypt renewal"
create_rule "AllowSSH"   130  22 "SSH admin access"

log "Inbound rules in place:"
az network nsg rule list -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" \
  --query "[?direction=='Inbound'].{name:name, port:destinationPortRange, access:access, prio:priority}" \
  -o table 2>/dev/null || true

log "Done. Public HTTPS (443) should now be reachable."

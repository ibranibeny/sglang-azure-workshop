# Quickstart: SGLang OpenAI Endpoint for Qwen3.6-27B on Azure

End-to-end operator flow. Run all commands from the `deploy/` directory in a
Linux/WSL shell with the Azure CLI installed.

## Prerequisites

- Azure CLI installed and logged in: `az login`
- GPU quota for `Standard_NC80adis_H100_v5` in `indonesiacentral`
  (`az vm list-usage -l indonesiacentral -o table`)
- A Hugging Face token if `Qwen/Qwen3.6-27B` is gated
- `openssl` available locally (for key generation)

## 1. Configure (optional overrides)

All defaults live in `config.sh`. Override any value via environment variable:

```bash
export HF_TOKEN=hf_xxxxxxxxxxxxxxxx     # if the model is gated
# export TLS_DOMAIN=infer.example.com   # optional: switch to Let's Encrypt
# export TLS_EMAIL=you@example.com
```

## 2. Generate the API key

```bash
chmod +x *.sh
./00-genkey.sh                 # writes deploy/.secrets/api_key (git-ignored)
export API_KEY=$(cat .secrets/api_key)
```

## 3. Provision infrastructure + VM

```bash
./01-deploy.sh                 # RG, network, NSG, public IP, NIC, GPU VM, driver
# wait ~3-5 min for cloud-init (Docker + NVIDIA toolkit) and GPU driver
```

## 4. Open and verify the network

```bash
./03-open-nsg.sh               # opens ALL ports (testing-only; prints warning)
./04-check-nsg.sh              # confirms allow-all inbound + outbound, effective
```

## 5. Launch the secured endpoint

```bash
./05-run-sglang.sh             # SGLang on loopback + Caddy HTTPS/API-key on 443
```

Model download + load takes several minutes on first run. The script waits for
readiness before reporting success.

## 6. Test the endpoint

```bash
PUBLIC_IP=$(az network public-ip show -g sglang-rg -n sglang-pip --query ipAddress -o tsv)

# -k accepts the default self-signed certificate
curl -k https://$PUBLIC_IP/v1/chat/completions \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3.6-27B","messages":[{"role":"user","content":"Hello"}]}'
```

Verify auth is enforced (should return 401):

```bash
curl -k https://$PUBLIC_IP/v1/chat/completions -d '{}'        # no key -> 401
```

## 7. Rotate the API key (no VM rebuild)

```bash
./00-genkey.sh --rotate
export API_KEY=$(cat .secrets/api_key)
./05-run-sglang.sh             # re-renders Caddyfile + restarts Caddy only
```

## 8. Lifecycle management

```bash
./02-start-vm.sh               # power the VM back on after deallocation
./99-destroy.sh --vm-only      # stop compute billing, keep resources
./99-destroy.sh                # delete the entire resource group (confirms first)
```

## Validation checklist (maps to success criteria)

- [ ] Authenticated HTTPS request returns a completion (SC-001)
- [ ] Missing/invalid key returns 401; plain HTTP does not serve inference (SC-002)
- [ ] Deallocated VM restarts to serving state with one command (SC-003)
- [ ] Full teardown leaves no orphaned resources (SC-004)
- [ ] Re-running any script causes no duplicates/errors (SC-005)
- [ ] Key rotation invalidates the old key without VM rebuild (SC-006)
- [ ] `04-check-nsg.sh` correctly reports open/closed state (SC-007)
- [ ] No secret appears in any committed file (SC-008)

## Security note

`03-open-nsg.sh` opens every port to the public internet — a testing convenience
only. The endpoint stays protected because TLS + API-key auth run in Caddy and
SGLang is bound to loopback. For real use, restrict the NSG to your source IP and
only ports 22 (SSH) and 443 (HTTPS).

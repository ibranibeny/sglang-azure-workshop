# SGLang + Qwen3.6-27B on Azure — Deployment Report

**Date:** 2026-06-17
**Status:** 🟢 **LIVE & SERVING** — OpenAI-compatible endpoint is up over public HTTPS with a valid Let's Encrypt certificate, API-key auth enforced, and verified end-to-end with a real inference response.

---

## 1. Current status (honest, verified)

| Stage | Status | Evidence |
|-------|--------|----------|
| Resource group / network | ✅ Done | `sglang-rg`, VNet `sglang-vnet`, NSG `sglang-nsg` |
| H100 VM provisioned | ✅ Done | `sglang-h100`, `Standard_NC40ads_H100_v5`, `provisioningState=Succeeded` |
| Public IP allocated | ✅ Done | **`70.153.148.66`** (Standard, static) |
| Domain / DNS | ✅ Done | `openai.contoso.day` → `70.153.148.66` (Cloudflare A record, DNS-only) |
| NVIDIA GPU driver | ✅ Installed | `NvidiaGpuDriverLinux` extension, `nvidia-smi` works (H100 NVL, CUDA 13.3) |
| SGLang container | ✅ Running | loopback `127.0.0.1:30000`, GPU 77 GB / 94 GB used |
| Caddy HTTPS gateway | ✅ Running | `:443`, **Let's Encrypt** TLS + API-key enforcement |
| Model loaded → serving | ✅ Done | `"The server is fired up and ready to roll!"` |
| TLS certificate | ✅ Valid | Issuer **`Let's Encrypt` (CN=YE1)**, subject `openai.contoso.day`, valid Jun 17 → Sep 15 2026 |
| Public health (no `-k`) | ✅ 200 | `curl https://openai.contoso.day/health` → `HTTP 200` |
| Auth enforcement | ✅ 401 | request without key → `HTTP 401` |
| End-to-end inference (no `-k`) | ✅ 200 | authenticated `/v1/chat/completions` → `HTTP 200` + real model answer |

**What this means:** Everything is deployed and working. The 27B model is loaded on the H100 and answering requests. The public endpoint uses a **genuine, publicly-trusted Let's Encrypt certificate** (no `-k` needed), and the API key is enforced (unauthenticated requests get `401`).

### Verification excerpt (run from WSL, **without** `-k`)
```
=== 1) Certificate issuer / validity ===
issuer=C = US, O = Let's Encrypt, CN = YE1
subject=CN = openai.contoso.day
notBefore=Jun 17 02:31:04 2026 GMT
notAfter=Sep 15 02:31:03 2026 GMT

=== 2) Public health ===            HTTP 200
=== 3) No API key ===               HTTP 401
=== 4) Authenticated chat ===       HTTP 200  (real model response)
=== 5) Models list ===              HTTP 200  (Qwen/Qwen3.6-27B, max_model_len 262144)
```

---

## 2. How to access the deployment

### A. The OpenAI-compatible API (primary way to use it)

- **Base URL:** `https://openai.contoso.day/v1`
- **TLS:** valid **Let's Encrypt** certificate — **no `-k` needed**; works with standard HTTPS clients.
- **Auth:** every request needs `Authorization: Bearer <API_KEY>`.
- **API key location (on this machine):** `deploy/.secrets/api_key` (git-ignored, mode 600).

**Load the key (WSL):**
```bash
export API_KEY=$(cat deploy/.secrets/api_key)
```

**Chat completion test:**
```bash
curl https://openai.contoso.day/v1/chat/completions \
  -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen3.6-27B","messages":[{"role":"user","content":"Hello"}]}'
```

**Health check (no key required):**
```bash
curl https://openai.contoso.day/health
```

**List models (authenticated):**
```bash
curl https://openai.contoso.day/v1/models -H "Authorization: Bearer $API_KEY"
```

**Use from the OpenAI SDK (Python):**
```python
from openai import OpenAI
client = OpenAI(base_url="https://openai.contoso.day/v1", api_key="<API_KEY>")
resp = client.chat.completions.create(
    model="Qwen/Qwen3.6-27B",
    messages=[{"role": "user", "content": "Hello"}],
)
print(resp.choices[0].message.content)
```

> The cert is publicly trusted, so no `verify=False` / custom httpx client is required.

### B. SSH into the VM

The NSG currently allows **all inbound ports** (testing config), and the VM was created with a generated SSH key.

```bash
ssh azureuser@70.153.148.66          # or ssh azureuser@openai.contoso.day
```

- **User:** `azureuser`
- **Key:** auto-generated during `01-deploy.sh` (`--generate-ssh-keys`), stored in `~/.ssh/id_rsa` in WSL.

Useful once inside:
```bash
docker ps                      # see sglang + caddy containers
docker logs -f sglang          # watch model serving
docker logs --tail 50 caddy    # watch TLS / ACME
nvidia-smi                     # GPU memory + utilization
```

### C. Run commands without SSH (Azure run-command)

This is how the deploy scripts operate (no inbound SSH needed):
```bash
source deploy/config.sh
az vm run-command invoke -g sglang-rg -n sglang-h100 \
  --command-id RunShellScript \
  --scripts 'docker logs --tail 40 sglang'
```

> ⚠️ Note: in this WSL environment, `az` is bridged to the **Windows** Azure CLI via interop (Global Secure Access workaround). The `[WARN] Using Windows Azure CLI…` line is expected on every call.

---

## 3. Deployment facts

| Item | Value |
|------|-------|
| Subscription | `ME-MngEnvMCAP708029-benyibrani-1` (`439cf6ec-8907-40ee-bae2-7efd9656cd09`) |
| Region | `indonesiacentral` |
| Resource group | `sglang-rg` |
| VM name | `sglang-h100` |
| VM size | `Standard_NC40ads_H100_v5` (1× H100 NVL 94 GB, 40 vCPUs) |
| OS | Ubuntu 24.04 LTS (Gen2), 512 GB OS disk |
| Public IP | `70.153.148.66` (Standard, static) |
| Domain | `openai.contoso.day` (Cloudflare A record → public IP, DNS-only / proxy off) |
| Model | `Qwen/Qwen3.6-27B` (apache-2.0, **not gated**, multimodal, ~56 GB, 262K context) |
| Serving engine | `lmsysorg/sglang:latest`, tensor-parallel `--tp 1` |
| Internal port | `127.0.0.1:30000` (loopback only) |
| Gateway | Caddy v2, HTTPS `:443`, **Let's Encrypt** TLS, Bearer-key auth |

---

## 4. Security notes

- 🔴 **NSG opens ALL inbound ports to `0.0.0.0/0`** (testing-only configuration from `03-open-nsg.sh`). For anything beyond short-lived testing, restrict source IPs and limit inbound to `22` (SSH), `80` (ACME HTTP-01 renewal), and `443` (HTTPS).
- ✅ **Valid Let's Encrypt TLS** — traffic is encrypted **and** certificate-trusted (no `-k`). Caddy auto-renews the cert (keep port 80/443 open outbound + inbound for renewal).
- ✅ SGLang is bound to loopback only; it is never exposed directly — all external traffic goes through Caddy, which enforces the API key.
- ✅ API key is a 256-bit secret stored in `deploy/.secrets/api_key` (git-ignored, `chmod 600`). A request without it returns `401` (verified).

---

## 5. Cost reminder

The VM is a **1× H100** GPU instance and is **currently running (billing)**. To stop incurring compute charges when idle:
```bash
az vm deallocate -g sglang-rg -n sglang-h100   # stops billing for compute
```
To start it again later:
```bash
az vm start -g sglang-rg -n sglang-h100
bash deploy/05-run-sglang.sh                   # re-launch containers + readiness wait
```
To tear everything down:
```bash
bash deploy/99-destroy.sh
```

> Note: after a deallocate/start cycle the public IP is static and the domain still points to it, but the model must reload into VRAM (a few minutes) on restart.

---

## 6. Issues found & fixed during bring-up

1. **Caddy `tls internal` aborted the TLS handshake for IP/no-SNI clients** → switched to an explicit cert path; ultimately moved to **Let's Encrypt** using the user's domain.
2. **`Caddyfile.tmpl` comment contained literal `__GLOBAL_BLOCK__` tokens** → `sed .../g` substituted them inside the `#` comment, and the multi-line global block broke out, producing `unrecognized directive: acme_ca`. Fixed by removing the placeholder tokens from the template comments.
3. **ACME CA pinned to Let's Encrypt** (`acme_ca https://acme-v02.api.letsencrypt.org/directory`) to avoid the ZeroSSL fallback requiring a contact email.

---

*Live endpoint: `https://openai.contoso.day/v1` — OpenAI-compatible, valid Let's Encrypt TLS, API-key protected. Verified serving Qwen/Qwen3.6-27B.*

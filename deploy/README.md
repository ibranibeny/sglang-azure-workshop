# SGLang + Qwen3.6-35B-A3B-FP8 on Azure (H100)

Deploys a **secure, HTTPS, API-key-protected** OpenAI-compatible inference
server using [SGLang](https://github.com/sgl-project/sglang) serving
[`Qwen/Qwen3.6-35B-A3B-FP8`](https://huggingface.co/Qwen/Qwen3.6-35B-A3B-FP8) on a single
`Standard_NC80adis_H100_v5` VM (2× H100 NVL GPUs) in **Indonesia Central**.

A Caddy reverse proxy on the VM terminates TLS and enforces the API key; the
SGLang server itself is bound to loopback and is never exposed directly.

## Files

| File | Purpose |
|------|---------|
| `config.sh` | All configurable variables (RG, VM size, model, ports, TLS, secrets). |
| `cloud-init.yaml` | Installs Docker + NVIDIA Container Toolkit at first boot. |
| `Caddyfile.tmpl` | Template for the HTTPS + API-key gateway (rendered at launch). |
| `00-genkey.sh` | **Req #5** — generate / rotate the secret API key. |
| `01-deploy.sh` | Provision RG, network, NSG, public IP, NIC, GPU VM. Idempotent. |
| `02-start-vm.sh` | **Req #1** — start/allocate the VM if stopped or deallocated. |
| `03-open-nsg.sh` | **Req #2** — open all ports inbound **and** outbound. |
| `04-check-nsg.sh` | **Req #3** — verify the allow-all NSG rules are present/effective. |
| `05-run-sglang.sh` | Launch SGLang (loopback) + Caddy (**Req #6** HTTPS + API key, `--tp 2`). |
| `99-destroy.sh` | **Req #4** — delete everything (or `--vm-only` to just deallocate). |

## Prerequisites

- Azure CLI (`az`) installed and logged in: `az login`
- Quota for `Standard_NC80adis_H100_v5` in `indonesiacentral`
  (`az vm list-usage -l indonesiacentral -o table`).
- `openssl` locally (for API-key generation).
- A Hugging Face token if the model is gated.

## Usage

```bash
cd deploy
chmod +x *.sh

# Generate the secret API key (written to .secrets/api_key, git-ignored)
./00-genkey.sh
export API_KEY=$(cat .secrets/api_key)

# (optional) needed if the model is gated
export HF_TOKEN=hf_xxxxxxxxxxxxxxxx

./01-deploy.sh        # create infra + VM (a few minutes)
# wait ~3-5 min for cloud-init + GPU driver to finish
./03-open-nsg.sh      # open all ports (testing-only; prints a warning)
./04-check-nsg.sh     # verify NSG is fully open
./05-run-sglang.sh    # start SGLang (loopback) + Caddy (HTTPS + API key)
```

Test the endpoint (replace `<PUBLIC_IP>`; `-k` accepts the self-signed cert):

```bash
curl -k https://<PUBLIC_IP>/v1/chat/completions \
  -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen3.6-35B-A3B-FP8","messages":[{"role":"user","content":"Hello"}]}'
```

A request without a valid key returns `401 Unauthorized`. Plain HTTP to the
public address does not serve the inference API.

## HTTPS / TLS

By default Caddy issues a **self-signed** certificate (no DNS name required), so
clients must trust it or use `curl -k` / `verify=False`. To use a publicly
trusted **Let's Encrypt** certificate, point a DNS name at the VM's public IP and
set:

```bash
export TLS_DOMAIN=infer.example.com
export TLS_EMAIL=you@example.com
./05-run-sglang.sh
```

## Rotating the API key

```bash
./00-genkey.sh --rotate
export API_KEY=$(cat .secrets/api_key)
./05-run-sglang.sh        # re-renders the Caddyfile and restarts Caddy ONLY;
                          # the model container keeps running (no reload)
```

## Lifecycle

```bash
./02-start-vm.sh          # power the VM back on
./99-destroy.sh --vm-only # stop compute billing, keep resources
./99-destroy.sh           # delete the whole resource group
```

## ⚠️ Security warning

`03-open-nsg.sh` opens **every port to the entire internet (0.0.0.0/0)** as
requested. This is a **testing-only** convenience and is not the production
default. The endpoint stays protected because Caddy enforces TLS + the API key
and SGLang is bound to loopback — but for real use you should still restrict the
NSG to your source IP and only the ports you need (typically `22` for SSH and
`443` for HTTPS). Never commit the contents of `.secrets/`.

# Phase 1 Data Model: SGLang OpenAI Endpoint on Azure

This feature is infrastructure automation; "entities" are configuration objects
and deployed resources rather than persisted database records. They are modeled
here to anchor the scripts and their relationships.

## Entity: Deployment Configuration

The single authoritative set of tunable values, defined in `deploy/config.sh`
and sourced by every script. Every field is overridable via an environment
variable of the same name.

| Field | Default | Notes |
|-------|---------|-------|
| `RESOURCE_GROUP` | `sglang-rg` | Azure resource group name |
| `LOCATION` | `indonesiacentral` | Azure region |
| `VM_NAME` | `sglang-h100` | VM resource name |
| `VM_SIZE` | `Standard_NC80adis_H100_v5` | 2× H100 NVL GPU SKU |
| `ADMIN_USER` | `azureuser` | VM admin username |
| `VM_IMAGE` | `Canonical:ubuntu-24_04-lts:server:latest` | OS image |
| `OS_DISK_SIZE_GB` | `512` | OS disk size |
| `VNET_NAME` / `SUBNET_NAME` | `sglang-vnet` / `sglang-subnet` | Network |
| `NSG_NAME` | `sglang-nsg` | Network security group |
| `PUBLIC_IP_NAME` / `NIC_NAME` | `sglang-pip` / `sglang-nic` | Connectivity |
| `SGLANG_IMAGE` | `lmsysorg/sglang:latest` | Model server image |
| `SGLANG_PORT` | `30000` | Loopback-only model server port |
| `HTTPS_PORT` | `443` | Public TLS port (Caddy) |
| `MODEL_PATH` | `Qwen/Qwen3.6-27B` | Hugging Face model id |
| `TP_SIZE` | `2` | Tensor-parallel size (GPU count) |
| `CADDY_IMAGE` | `caddy:2` | Reverse proxy image |
| `TLS_DOMAIN` | `""` (empty → self-signed) | Set to enable Let's Encrypt |
| `TLS_EMAIL` | `""` | ACME contact when `TLS_DOMAIN` set |
| `HF_TOKEN` | `""` (runtime) | Secret; never committed |
| `API_KEY` | from `.secrets/api_key` | Secret; never committed |

**Validation rules**:
- `TP_SIZE` MUST equal the GPU count of `VM_SIZE` (2 for the default SKU).
- If `TLS_DOMAIN` is set, `TLS_EMAIL` SHOULD be set for ACME.
- Secret fields (`HF_TOKEN`, `API_KEY`) MUST be absent from version control.

## Entity: GPU Virtual Machine

The compute host. Lifecycle state machine:

```text
(absent) --01-deploy--> [running] --deallocate(99 --vm-only)--> [deallocated]
[deallocated] --02-start--> [running]
[running] --02-start--> [running]   (idempotent no-op)
[any] --99-destroy--> (absent, with whole resource group)
```

**Attributes**: power state (`running` / `stopped` / `deallocated`), 2× H100
GPUs, public IP association, NIC bound to the NSG-protected subnet.

## Entity: Network Security Group

Inbound/outbound rule set on the subnet/NIC. Target state for this feature:

| Rule | Direction | Access | Protocol | Ports | Source |
|------|-----------|--------|----------|-------|--------|
| `AllowAllInbound` | Inbound | Allow | `*` | `*` | `*` |
| `AllowAllOutbound` | Outbound | Allow | `*` | `*` | `*` |

**State transitions**: created closed by Azure defaults → `03-open-nsg.sh`
applies allow-all rules → `04-check-nsg.sh` reports present + effective.

## Entity: API Key (Secret)

| Attribute | Value |
|-----------|-------|
| Generation | `openssl rand -hex 32` (≥256-bit) |
| Storage | `deploy/.secrets/api_key` (git-ignored) |
| Presentation | `Authorization: Bearer <key>` on every request |
| Rotation | regenerate file → re-render Caddyfile → restart Caddy only |

## Entity: TLS Certificate / Endpoint Identity

| Mode | Trigger | Source |
|------|---------|--------|
| Self-signed (default) | `TLS_DOMAIN` empty | Caddy `tls internal` |
| CA-signed (override) | `TLS_DOMAIN` set | Caddy + Let's Encrypt (ACME) |

## Entity: Model Endpoint

The externally consumed surface.

| Attribute | Value |
|-----------|-------|
| URL | `https://<public-ip-or-domain>/v1` |
| Protocol | OpenAI Chat Completions (and `/v1/models`) |
| Auth | Bearer API key (enforced by Caddy) |
| Backend | SGLang serving `Qwen/Qwen3.6-27B`, `--tp 2`, loopback only |
| Readiness | health path returns success after model load |

## Relationships

```text
Deployment Configuration ──sourced by──> all scripts
GPU Virtual Machine ──hosts──> SGLang (loopback) + Caddy (443)
Network Security Group ──protects──> NIC ──> GPU Virtual Machine
API Key ──enforced by──> Caddy ──fronts──> Model Endpoint
TLS Certificate ──terminates HTTPS at──> Caddy
Model Endpoint ──serves──> Qwen/Qwen3.6-27B
```

# Phase 0 Research: SGLang OpenAI Endpoint on Azure

All Technical Context items were resolvable from the spec, the project
constitution, and the existing `deploy/` scripts. No `NEEDS CLARIFICATION`
markers remained. This document records the key decisions and rationale.

## Decision 1 — TLS termination + API-key auth via Caddy reverse proxy

- **Decision**: Run Caddy v2 as a container on the VM, listening on 443, with
  TLS enabled (`tls internal` self-signed by default) and a request matcher that
  rejects any request whose `Authorization: Bearer <key>` header does not match
  the secret API key. Caddy reverse-proxies authenticated traffic to the SGLang
  server bound to `127.0.0.1`.
- **Rationale**: Satisfies Principle III (HTTPS + API key, non-negotiable) with
  minimal moving parts. Caddy gives automatic self-signed certs (no DNS needed)
  and one-line header-based auth, and can later switch to Let's Encrypt by
  setting a domain. Keeping SGLang on loopback guarantees the API is never
  served unencrypted or unauthenticated even though the NSG is wide open.
- **Alternatives considered**:
  - *SGLang `--api-key` alone over HTTP* — rejected: provides auth but not TLS;
    violates the HTTPS requirement (FR-010).
  - *nginx + self-signed certs* — workable but more boilerplate (manual cert
    generation, conf templating) than Caddy's `tls internal`.
  - *Azure Application Gateway / API Management* — rejected: heavier, slower to
    provision, and over-scoped for a single-VM testing deployment.

## Decision 2 — API key generation and rotation strategy

- **Decision**: `00-genkey.sh` generates a cryptographically strong key
  (`openssl rand -hex 32`) and writes it to `deploy/.secrets/api_key`
  (git-ignored). Rotation re-runs the script (with `--rotate`) to overwrite the
  key, then `05-run-sglang.sh` re-renders the Caddyfile and restarts only the
  Caddy container — the VM is not recreated.
- **Rationale**: Satisfies FR-008 (generate + rotate without rebuilding the VM)
  and FR-011 (never committed). Local secret file keeps the flow simple and
  scriptable; restart of the proxy is fast and stateless.
- **Alternatives considered**:
  - *Azure Key Vault* — more secure for production but adds an RBAC/identity
    setup step; documented as a future hardening option, not the default.
  - *Bake key into the SGLang container env only* — rejected: rotation would
    require restarting the model server (slow, reloads weights).

## Decision 3 — HTTPS certificate approach (self-signed default)

- **Decision**: Default to Caddy's internal self-signed CA (`tls internal`)
  because the endpoint is reached by raw public IP with no DNS name. Document a
  documented override: set a domain + email in `config.sh` to switch Caddy to a
  publicly trusted Let's Encrypt certificate.
- **Rationale**: Matches the spec assumption (no DNS name available). Clients
  trust the cert or pass `-k`/`verify=False`; this is acceptable for the
  testing-oriented scope and is clearly documented.
- **Alternatives considered**:
  - *Require a DNS name up front* — rejected: adds external dependency the user
    did not provide.
  - *Skip TLS* — rejected: violates Principle III.

## Decision 4 — Open-all NSG reconciled with secure-by-default

- **Decision**: Keep `03-open-nsg.sh` opening all inbound/outbound ports (the
  user's explicit Req 2/3) but treat it strictly as a documented, warning-gated
  testing convenience. Security is preserved by the Caddy layer (TLS + key) and
  by binding SGLang to loopback, so an open port does not mean an open model.
- **Rationale**: Reconciles the literal request with constitution Principle III
  and the Security & Networking Requirements. README recommends restricting
  source ranges (SSH + 443 only) for real use.
- **Alternatives considered**:
  - *Open only 22 + 443* — safer and recommended for production, but contradicts
    the explicit Req 2; offered as a README hardening note instead of the default.

## Decision 5 — Tensor parallelism = 2 for the dual-H100 SKU

- **Decision**: Launch SGLang with `--tp 2` by default (overridable via
  `TP_SIZE`).
- **Rationale**: `Standard_NC80adis_H100_v5` exposes 2× H100 NVL GPUs; tensor
  parallelism across both is the standard way to serve a 27B model with headroom.
- **Alternatives considered**: `--tp 1` — rejected: wastes the second GPU and
  risks tighter memory for the 27B model + KV cache.

## Decision 6 — Readiness check distinct from power state

- **Decision**: Readiness is confirmed by polling the SGLang/Caddy health path
  (e.g., `GET /health` through HTTPS, or model list) until it returns success,
  separate from `az vm get-instance-view` power state.
- **Rationale**: Satisfies FR-016 — a powered-on VM is not the same as a loaded
  model; first-run model download takes minutes.

## Decision 7 — Driver + container runtime provisioning

- **Decision**: NVIDIA host driver via the `NvidiaGpuDriverLinux`
  (Microsoft.HpcCompute) VM extension; Docker + NVIDIA Container Toolkit via
  `cloud-init.yaml` at first boot; SGLang and Caddy run as Docker containers.
- **Rationale**: Matches Azure's supported GPU driver path and the existing
  `deploy/` approach; containers keep the host clean and restarts simple.
- **Alternatives considered**: Manual driver install in cloud-init — rejected:
  the VM extension is the supported, more reliable mechanism.

## Open risks (tracked, not blocking)

- GPU quota/capacity for the SKU in `indonesiacentral` must exist (operator
  responsibility; provisioning surfaces the error).
- `Qwen/Qwen3.6-27B` may be gated — requires `HF_TOKEN` at runtime.
- Self-signed TLS requires clients to trust or skip verification.

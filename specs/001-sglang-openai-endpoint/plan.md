# Implementation Plan: SGLang OpenAI-Compatible Endpoint for Qwen3.6-27B on Azure

**Branch**: `001-sglang-openai-endpoint` | **Date**: 2026-06-17 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/001-sglang-openai-endpoint/spec.md`

## Summary

Provision and operate an OpenAI-compatible inference endpoint for `Qwen/Qwen3.6-27B`,
served by SGLang on an Azure `Standard_NC80adis_H100_v5` GPU VM (2× H100 NVL) in
`indonesiacentral`, using only scripted Azure CLI automation. SGLang runs as a
Docker container bound to loopback; a Caddy reverse proxy on the same VM
terminates TLS (HTTPS) and enforces a secret API key, so the model is never
exposed unauthenticated even when the NSG is opened for testing. The deployment
provides numbered, idempotent lifecycle scripts (provision, start, open-NSG,
verify-NSG, launch, destroy) plus API-key generation/rotation — all driven from a
single central configuration source, with every `az` command aligned to the
official Microsoft Learn / Azure CLI reference.

## Technical Context

**Language/Version**: Bash (POSIX/`bash`), targeting Azure CLI `az` (2.x) on a Linux/WSL operator host

**Primary Dependencies**: Azure CLI (`az`); Docker + NVIDIA Container Toolkit (on the VM, via cloud-init); SGLang container image `lmsysorg/sglang:latest`; Caddy v2 (`caddy:2`) for the TLS + API-key gateway; `openssl` for key generation; `NvidiaGpuDriverLinux` VM extension (publisher `Microsoft.HpcCompute`, handler `1.6`) for CUDA drivers

**Storage**: Local secrets at `deploy/.secrets/` (git-ignored); persistent Hugging Face weight cache volume `/opt/hf-cache` on the VM; Caddy data/config volumes on the VM

**Testing**: `bash -n` syntax validation of all scripts; manual quickstart end-to-end validation ([quickstart.md](quickstart.md)) covering SC-001…SC-008; `curl` health/auth probes against the HTTPS endpoint

**Target Platform**: Azure Linux GPU VM (Ubuntu 24.04 LTS, Gen2) in `indonesiacentral`; operator runs scripts from WSL bash

**Project Type**: Infrastructure automation / CLI deployment (single project, `deploy/` script suite)

**Performance Goals**: Endpoint serves OpenAI chat completions from a 27B model across 2 GPUs via tensor parallelism (`--tp 2`); readiness is gated on an actual `/health` 200 over HTTPS, not VM power state (FR-016)

**Constraints**: Only `az login` may be manual (Principle I); all operations idempotent (Principle II); HTTPS-only + API key required (Principle III, NON-NEGOTIABLE); no secrets in version control (FR-011/SC-008); single central config with env override (Principle IV); every `az` command must match the official Microsoft Learn / `az` CLI reference

**Scale/Scope**: Single VM, single region; ~8 deploy scripts + config + cloud-init + Caddyfile template. No HA, autoscaling, or multi-region (out of scope per spec assumptions)

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle / Section | Requirement | Plan compliance |
|---|---|---|
| I. IaC via Azure CLI | All resources via scripted `az`; only `az login` manual | ✅ All resources created in `deploy/01-deploy.sh` and friends via `az`; no portal steps |
| II. Idempotent & Reversible | Re-runnable; start-not-recreate; full + `--vm-only` teardown | ✅ Existence checks before create; `02-start-vm.sh` no-ops when running; `99-destroy.sh` full RG delete + `--vm-only` deallocate |
| III. Secure Access (NON-NEGOTIABLE) | HTTPS only; API key required + rotatable; secrets uncommitted | ✅ Caddy TLS + `Bearer` key; SGLang on loopback; `00-genkey.sh` generate/rotate; `.gitignore` excludes `.secrets/` |
| IV. Single Source of Config | One config file every script sources; env-overridable | ✅ `deploy/config.sh` with `${VAR:-default}` pattern; image/tag/SKU/ports centralized |
| V. Verifiability & Observability | Inspectable NSG, queryable power state, health path; timestamped logs | ✅ `04-check-nsg.sh`, `get-instance-view` power state, `/health` readiness wait; `log/warn/die` helpers |
| Security & Networking | TLS gateway; key rotation; open-NSG warning-gated; quota verified | ✅ Caddy gateway; open-NSG emits warning (testing-only); region/SKU defaults in config |
| Compute & Runtime | CUDA via `NvidiaGpuDriverLinux` extension (idempotent); SGLang in Docker (`--gpus all`, `--shm-size`, `--ipc=host`, HF cache); Docker + NVIDIA toolkit prereqs; image/tag in config | ✅ Idempotent extension in `01-deploy.sh` (`--version $NVIDIA_EXT_VERSION`, skip if `Succeeded`); Dockerized SGLang in `05-run-sglang.sh`; `cloud-init.yaml` installs Docker + NVIDIA toolkit; `SGLANG_IMAGE` in config |
| Deployment Workflow & Quality Gates | Numbered lifecycle scripts; `az` preflight; docs accurate | ✅ Scripts `00`–`05` + `99`; `command -v az` + `az account show` preflight; `README.md` kept current |

**Result**: PASS — no violations. Complexity Tracking not required.

## Project Structure

### Documentation (this feature)

```text
specs/001-sglang-openai-endpoint/
├── plan.md              # This file (/speckit.plan output)
├── research.md          # Phase 0 output (technology decisions)
├── data-model.md        # Phase 1 output (entities, config schema)
├── quickstart.md        # Phase 1 output (end-to-end validation, SC-001…SC-008)
├── contracts/
│   ├── openai-endpoint.md   # HTTPS OpenAI API + auth contract
│   └── scripts-cli.md       # Script CLI contracts (args, exit codes, idempotency)
├── checklists/
│   └── requirements.md      # Spec quality checklist
└── tasks.md             # Phase 2 output (/speckit.tasks — T001–T022)
```

### Source Code (repository root)

```text
deploy/
├── config.sh            # Single source of configuration (Principle IV)
├── cloud-init.yaml      # First-boot: Docker + NVIDIA Container Toolkit
├── Caddyfile.tmpl       # HTTPS + API-key gateway template
├── 00-genkey.sh         # Generate / rotate the secret API key (FR-008)
├── 01-deploy.sh         # Provision RG, VNet, NSG, public IP, NIC, GPU VM + NVIDIA ext
├── 02-start-vm.sh       # Start/allocate VM if stopped (FR-003)
├── 03-open-nsg.sh       # Open all inbound/outbound ports (FR-004, warning-gated)
├── 04-check-nsg.sh      # Verify NSG allow-all rules effective (FR-006)
├── 05-run-sglang.sh     # Launch SGLang (loopback) + Caddy (HTTPS) (FR-002, FR-009, FR-010)
├── 99-destroy.sh        # Full teardown / --vm-only deallocate (FR-007)
├── .gitignore           # Excludes .secrets/, *.key, *.pem, rendered Caddyfile
└── README.md            # Usage, secured flow, security warnings
```

**Structure Decision**: Single-project infrastructure automation. All deployment
logic lives in `deploy/` as numbered, idempotent Bash scripts sourcing a single
`config.sh`. No application source tree or test framework is required beyond
script syntax validation and the quickstart end-to-end check, matching the
CLI/IaC nature of the feature.

## Complexity Tracking

> No constitution violations — section intentionally empty.

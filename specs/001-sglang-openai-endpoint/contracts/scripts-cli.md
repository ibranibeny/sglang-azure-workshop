# Contract: Lifecycle Script CLI

The deployment is operated through ordered shell scripts in `deploy/`. Each
script sources `config.sh`, is idempotent, and emits timestamped log/warn/error
output. All paths are run from the `deploy/` directory.

## Ordering & responsibilities

| Script | Purpose | Key requirements | Idempotent behavior |
|--------|---------|------------------|---------------------|
| `00-genkey.sh [--rotate]` | Generate or rotate the secret API key | FR-008, FR-011 | Without `--rotate`, keeps existing key; with `--rotate`, overwrites |
| `01-deploy.sh` | Provision RG, VNet, NSG, public IP, NIC, GPU VM + driver | FR-001, FR-013, FR-014 | Reuses existing resources; if VM exists, starts it instead of recreating |
| `02-start-vm.sh` | Start/allocate VM if stopped/deallocated | FR-003 | No-op if already running |
| `03-open-nsg.sh` | Open all inbound + outbound ports | FR-004, FR-005 | Create-or-update rules; re-runnable |
| `04-check-nsg.sh` | Verify allow-all rules present + effective | FR-006 | Read-only; reports per-direction status |
| `05-run-sglang.sh` | Launch SGLang (loopback) + Caddy (HTTPS + key) | FR-002, FR-009, FR-010, FR-016 | Recreates containers; waits for readiness |
| `99-destroy.sh [--vm-only]` | Full teardown or compute-only deallocate | FR-007 | Full deletes RG (confirmation); `--vm-only` deallocates |

## Cross-cutting contract (all scripts)

- MUST `source ./config.sh`; MUST NOT hardcode tunables (FR-012).
- MUST verify `az` is installed and authenticated before mutating Azure (FR-013, where applicable).
- MUST emit timestamped INFO/WARN/ERROR-distinguished output (FR-015).
- MUST be safe to re-run (FR-014).
- MUST NOT print or commit secrets (FR-011).

## Pre/postconditions

### 00-genkey.sh
- **Pre**: none. **Post**: `deploy/.secrets/api_key` exists with a ≥256-bit hex secret; file is git-ignored.

### 01-deploy.sh
- **Pre**: `az` authenticated; quota available. **Post**: RG, network, NSG, public IP, NIC, running VM, GPU driver extension applied. If VM pre-existed, it is running.

### 02-start-vm.sh
- **Pre**: VM exists. **Post**: VM power state is `running`.

### 03-open-nsg.sh
- **Pre**: NSG exists. **Post**: `AllowAllInbound` + `AllowAllOutbound` rules present; security warning emitted.

### 04-check-nsg.sh
- **Pre**: NSG exists. **Post**: report of inbound/outbound allow-all presence and (if VM running) effective rules. Non-mutating.

### 05-run-sglang.sh
- **Pre**: VM running; `00-genkey.sh` has produced a key; `HF_TOKEN` exported if model gated. **Post**: SGLang container serving on loopback; Caddy serving HTTPS on 443 enforcing the API key; readiness confirmed.

### 99-destroy.sh
- **Pre**: deployment exists. **Post (full)**: resource group and all resources deleted after explicit confirmation. **Post (`--vm-only`)**: VM deallocated, other resources retained.

## Acceptance mapping

- User Story 2 (lifecycle): `02-start-vm.sh`, `99-destroy.sh`.
- User Story 3 (network): `03-open-nsg.sh`, `04-check-nsg.sh`.
- User Story 4 (key): `00-genkey.sh`, key rotation via `05-run-sglang.sh` restart.

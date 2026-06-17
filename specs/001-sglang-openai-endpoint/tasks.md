---
description: "Task list for SGLang OpenAI-compatible endpoint for Qwen3.6-27B on Azure"
---

# Tasks: SGLang OpenAI-Compatible Endpoint for Qwen3.6-27B on Azure

**Input**: Design documents from `/specs/001-sglang-openai-endpoint/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: No automated test framework is requested in the spec (this is
infrastructure automation). "Verification" tasks below use the project's own
check scripts and `curl`/`az` probes instead of unit tests.

**Organization**: Tasks are grouped by user story to enable independent
implementation and verification. Existing scripts in `deploy/` already satisfy
several requirements; tasks note whether a file is **new** or an **update**.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1–US4)

## Path Conventions

Single-project infrastructure automation under `deploy/` at repository root, per
plan.md Structure Decision.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Configuration and secret-handling scaffolding shared by all stories

- [x] T001 [P] Add new tunables to `deploy/config.sh`: `HTTPS_PORT` (443), `CADDY_IMAGE` (caddy:2), `TLS_DOMAIN` (empty), `TLS_EMAIL` (empty), `API_KEY` (loaded from `.secrets/api_key`), and a `SECRETS_DIR` pointing at `deploy/.secrets`, per data-model.md.
- [x] T002 [P] Create `deploy/.gitignore` excluding `.secrets/` and any generated TLS/Caddy data so secrets are never committed (FR-011, SC-008).

**Checkpoint**: Config exposes all values; secret directory is git-ignored.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Cross-cutting prerequisites that every story relies on

**⚠️ CRITICAL**: Must complete before user-story work begins

- [x] T003 Verify `deploy/config.sh` is sourced by every script and contains no duplicated/hardcoded tunables; confirm each value supports env-var override (FR-012).
- [x] T004 Create `deploy/00-genkey.sh` to generate a ≥256-bit secret API key via `openssl rand -hex 32` into `deploy/.secrets/api_key` (mode 600), supporting `--rotate` to overwrite; never prints the key to stdout (FR-008, FR-011). This is a blocking prerequisite because the secured endpoint (US1) and rotation (US4) both depend on it.

**Checkpoint**: Configuration and API-key generation are available to all stories.

---

## Phase 3: User Story 1 - Serve the model over a secure HTTPS OpenAI-compatible endpoint (Priority: P1) 🎯 MVP

**Goal**: A running, HTTPS-only, API-key-protected OpenAI-compatible endpoint
serving `Qwen/Qwen3.6-27B` across both H100 GPUs.

**Independent Test**: From a clean subscription, run provisioning + launch, then
send an authenticated OpenAI chat-completion over HTTPS and get a response;
confirm a missing/invalid key is rejected and plain HTTP does not serve inference.

### Implementation for User Story 1

- [x] T005 [US1] Create `deploy/Caddyfile.tmpl`: listen on `{$HTTPS_PORT}`, terminate TLS (`tls internal` when `TLS_DOMAIN` empty, else ACME with `TLS_DOMAIN`/`TLS_EMAIL`), require `Authorization: Bearer {$API_KEY}` and return 401 otherwise, and `reverse_proxy 127.0.0.1:{$SGLANG_PORT}` (FR-009, FR-010; contracts/openai-endpoint.md).
- [x] T006 [US1] Update `deploy/05-run-sglang.sh` to bind the SGLang container to loopback (`127.0.0.1:$SGLANG_PORT`, not `0.0.0.0`) so the model is never exposed unauthenticated (FR-010, research Decision 1).
- [x] T007 [US1] Update `deploy/05-run-sglang.sh` to render `Caddyfile.tmpl` with `API_KEY`/`TLS_*`/ports and launch a Caddy container publishing `$HTTPS_PORT`, mounting the rendered Caddyfile and a persistent Caddy data volume (FR-009, FR-010).
- [x] T008 [US1] Update `deploy/05-run-sglang.sh` to launch SGLang with `--tp $TP_SIZE` serving `$MODEL_PATH` and to fail fast with a clear message if `.secrets/api_key` is missing or `HF_TOKEN` is required but empty (FR-002, edge cases).
- [x] T009 [US1] Add a readiness wait to `deploy/05-run-sglang.sh` that polls the endpoint health/`/v1/models` over HTTPS (with the key) until the model is loaded, distinct from VM power state, before reporting success (FR-016).
- [x] T010 [US1] Ensure `deploy/05-run-sglang.sh` prints the final HTTPS endpoint URL and an authenticated `curl -k` example, and never echoes the API key value (FR-011, FR-015).

**Checkpoint**: US1 is independently functional — authenticated HTTPS inference works; unauthenticated/plain-HTTP is rejected. This is the MVP.

---

## Phase 4: User Story 2 - Manage the VM lifecycle (allocate, start, destroy) (Priority: P2)

**Goal**: Start a stopped/deallocated VM, fully tear down, or deallocate compute
only — all idempotent.

**Independent Test**: Deallocate the VM then run start automation and confirm it
returns to running; run full teardown and confirm all resources are gone.

### Implementation for User Story 2

- [x] T011 [P] [US2] Verify/update `deploy/02-start-vm.sh`: queries power state, starts/allocates only when not running, and is a clean no-op when already running (FR-003, FR-014; US2 scenarios 1–2).
- [x] T012 [P] [US2] Verify/update `deploy/99-destroy.sh`: full mode deletes the resource group after explicit name confirmation; `--vm-only` deallocates compute while preserving resources (FR-007; US2 scenarios 3–4).
- [x] T013 [US2] Confirm `deploy/01-deploy.sh` is idempotent: detects an existing VM and starts it instead of recreating, and reuses existing RG/VNet/NSG/IP/NIC (FR-014; US2/idempotency edge case).

**Checkpoint**: VM can be restarted, deallocated, and fully destroyed without duplication.

---

## Phase 5: User Story 3 - Open and verify network exposure (Priority: P3)

**Goal**: Open all inbound/outbound ports (testing-only, with warning) and verify
the all-open state.

**Independent Test**: Apply open-all automation, then run verification and confirm
it reports allow-all inbound and outbound rules as present and effective.

### Implementation for User Story 3

- [x] T014 [P] [US3] Verify/update `deploy/03-open-nsg.sh`: creates-or-updates `AllowAllInbound` + `AllowAllOutbound` rules (all protocols/ports/sources) idempotently and emits the testing-only security warning (FR-004, FR-005; US3 scenarios 1, 4).
- [x] T015 [P] [US3] Verify/update `deploy/04-check-nsg.sh`: reports presence of allow-all rules per direction and, when the VM is running, the effective NSG rules; clearly flags a direction that is not fully open (FR-006; US3 scenarios 2–3).

**Checkpoint**: Network can be opened and its open state independently verified.

---

## Phase 6: User Story 4 - Generate and rotate the API key (Priority: P3)

**Goal**: Generate a fresh key and rotate it without rebuilding the VM.

**Independent Test**: Generate a key and confirm the endpoint accepts it; rotate
and confirm the old key is rejected and the new key works, with no VM recreation.

### Implementation for User Story 4

- [x] T016 [US4] Confirm `deploy/00-genkey.sh --rotate` overwrites `.secrets/api_key` and that re-running `deploy/05-run-sglang.sh` re-renders the Caddyfile and restarts only the Caddy container (not the SGLang/model container or the VM) (FR-008; US4 scenarios 1–2, research Decision 2).

**Checkpoint**: Keys can be generated and rotated live without VM rebuild.

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Documentation, consistency, and final validation across all stories

- [x] T017 [P] Update `deploy/README.md` to document the new secured flow: `00-genkey.sh`, HTTPS + API-key usage, self-signed vs `TLS_DOMAIN` override, key rotation, and the testing-only open-NSG warning with production hardening guidance (FR-005; quickstart.md).
- [x] T018 [P] Verify every script in `deploy/` emits timestamped INFO/WARN/ERROR-distinguished output via the shared helpers and that none print secret values (FR-011, FR-015).
- [ ] T019 Run the quickstart end-to-end validation checklist in `specs/001-sglang-openai-endpoint/quickstart.md` and confirm SC-001 through SC-008 (auth enforced, HTTPS-only, restart, teardown, idempotency, rotation, NSG verify, no committed secrets). **Status (2026-06-17)**: Non-mutating dry-run validation PASSED — all 7 scripts source `config.sh`, `config.sh` exposes all 13 tunables, `az` 2.85.0 installed + authenticated, `.gitignore` excludes secrets (SC-008), open-NSG warning present (FR-005), SGLang loopback bind + Caddy HTTPS gateway present (FR-010). Live inference/provisioning portion (provision → serve → auth-reject over the wire → restart → teardown) remains DEFERRED pending operator approval to allocate the costly `Standard_NC80adis_H100_v5` VM.

---

## Phase 8: Compute & Runtime Requirements (Constitution v1.1.0)

**Purpose**: Satisfy the Compute & Runtime Requirements section added in
constitution v1.1.0 — GPU driver via idempotent VM extension, Dockerized SGLang
runtime, and container-runtime prerequisites — with explicit traceability.

- [x] T020 Confirm `deploy/01-deploy.sh` installs the NVIDIA CUDA driver via the `NvidiaGpuDriverLinux` VM extension (publisher `Microsoft.HpcCompute`) idempotently: it queries `provisioningState` and skips re-installation when already `Succeeded` (Constitution v1.1.0 Compute & Runtime; verifiable via `nvidia-smi`).
- [x] T021 Confirm `deploy/05-run-sglang.sh` runs SGLang as a Docker container from `${SGLANG_IMAGE}` (`lmsysorg/sglang`) launched with `python3 -m sglang.launch_server`, `--gpus all`, `--shm-size 32g`, `--ipc=host`, and a Hugging Face cache volume (`/opt/hf-cache:/root/.cache/huggingface`) (Constitution v1.1.0 Compute & Runtime).
- [x] T022 Confirm `deploy/cloud-init.yaml` installs the container-runtime prerequisites (Docker + NVIDIA Container Toolkit via `nvidia-ctk runtime configure --runtime=docker`) at first boot, and that the SGLang image/tag is centralized in `deploy/config.sh` (`SGLANG_IMAGE`) and env-overridable (Constitution v1.1.0 Compute & Runtime; Principle IV).

**Checkpoint**: GPU driver, Docker runtime, and Dockerized SGLang all comply with the amended constitution.

---

## Dependencies & Execution Order

- **Setup (Phase 1)** → **Foundational (Phase 2)** must complete before user stories.
- **User Story 1 (P1)** depends on Foundational (config + `00-genkey.sh`). It is the MVP and should be implemented first.
- **User Story 2 (P2)**, **User Story 3 (P3)**, **User Story 4 (P3)** are largely independent of each other:
  - US2 and US3 touch only their own existing scripts and can proceed in parallel after Foundational.
  - US4 depends on `00-genkey.sh` (Foundational, T004) and on the Caddy launch from US1 (T007) for the live-rotation verification (T016).
- **Polish (Phase 7)** runs last, after all stories are in place.

```text
Setup(T001,T002) → Foundational(T003,T004) → US1(T005..T010) ─┐
                                            → US2(T011..T013) ─┤
                                            → US3(T014,T015)  ─┼→ Polish(T017..T019)
                                            → US4(T016)*      ─┘
   * T016 also needs US1's T007
```

## Parallel Execution Examples

- **Setup**: T001 and T002 in parallel (different files).
- **After Foundational**: launch US2 (T011, T012) and US3 (T014, T015) in
  parallel — all `[P]`, different scripts — while US1 (T005–T010) proceeds.
- **Polish**: T017 and T018 in parallel.

## Implementation Strategy

- **MVP scope**: Phases 1–3 (Setup + Foundational + User Story 1) deliver a
  working, secure HTTPS endpoint — the minimum viable product.
- **Incremental delivery**: Add US2 (lifecycle), US3 (network open/verify), and
  US4 (key rotation) as independent increments, then finish with Polish.

## Requirement Mapping

| Requirement | Tasks |
|-------------|-------|
| FR-001 provision via az CLI | T013 |
| FR-002 serve Qwen via SGLang `--tp` | T008 |
| FR-003 start if stopped | T011 |
| FR-004/005 open NSG + warning | T014 |
| FR-006 verify NSG | T015 |
| FR-007 teardown / --vm-only | T012 |
| FR-008 generate/rotate key | T004, T016 |
| FR-009 require API key | T005, T007 |
| FR-010 HTTPS-only, loopback backend | T005, T006, T007 |
| FR-011 secrets not committed | T002, T004, T010, T018 |
| FR-012 single config source | T001, T003 |
| FR-013 az preflight | T013 (existing scripts) |
| FR-014 idempotent | T011, T012, T013, T014 |
| FR-015 timestamped log levels | T010, T018 |
| FR-016 readiness ≠ power state | T009 |
| FR-017 ordered scripts | T001–T016 (numbered files) |

## Success Criteria Mapping

| Success Criterion | Tasks |
|-------------------|-------|
| SC-001 reach working authenticated HTTPS endpoint, no manual steps | T005–T010, T019 |
| SC-002 100% reject no-key + plain-HTTP | T005, T006, T007, T019 |
| SC-003 restart deallocated VM without recreate | T011, T019 |
| SC-004 full teardown leaves no orphans | T012, T019 |
| SC-005 re-run produces no duplicates/errors | T011, T012, T013, T014, T019 |
| SC-006 generate + rotate key, old stops working | T004, T016, T019 |
| SC-007 NSG verify reports open/closed correctly | T015, T019 |
| SC-008 no secret in any committed file | T002, T004, T010, T018, T019 |

## Constitution Mapping (v1.1.0 Compute & Runtime)

| Constitution requirement | Tasks |
|--------------------------|-------|
| GPU driver via idempotent `NvidiaGpuDriverLinux` extension | T020 |
| Dockerized SGLang (`--gpus all`, `--shm-size`, `--ipc=host`, HF cache) | T021 |
| Docker + NVIDIA Container Toolkit prereqs; image/tag centralized | T022 |

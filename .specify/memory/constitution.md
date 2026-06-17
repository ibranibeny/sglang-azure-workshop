<!--
SYNC IMPACT REPORT
==================
Version change: 1.0.0 → 1.1.0
Bump rationale: MINOR — added a new "Compute & Runtime Requirements" section
mandating the NVIDIA CUDA driver VM extension and Docker-based SGLang execution.
No existing principles were removed or redefined.

Modified principles: none (all five principles unchanged)

Added sections:
  - Compute & Runtime Requirements (Section 4)

Removed sections: none

Templates requiring updates:
  - .specify/templates/plan-template.md ✅ reviewed (generic "Constitution Check" gate remains valid)
  - .specify/templates/spec-template.md ✅ reviewed (no constitution-specific sections required)
  - .specify/templates/tasks-template.md ✅ reviewed (task categories cover IaC/security/verification)

Prior history:
  - 1.0.0 (2026-06-16): Initial ratification (5 principles + Security & Networking,
    Deployment Workflow & Quality Gates sections).

Follow-up TODOs: none
-->

# SGLang on Azure Constitution

Serving the `Qwen/Qwen3.6-27B` model through the SGLang OpenAI-compatible API on
Azure GPU compute (`Standard_NC80adis_H100_v5`, region `indonesiacentral`),
provisioned and operated entirely through Azure CLI (`az`) automation.

## Core Principles

### I. Infrastructure as Code via Azure CLI

All Azure resources MUST be created, modified, and destroyed through scripted
`az` CLI commands committed to the repository — never through manual portal
clicks or undocumented ad-hoc commands. Scripts MUST be self-contained,
re-runnable, and readable as the authoritative description of the deployed
system. Manual intervention is permitted only for one-time interactive login
(`az login`) and quota requests.

*Rationale: A reproducible, reviewable deployment is the single source of truth
and the only way to reliably recreate or audit the environment.*

### II. Idempotent & Reversible Operations

Every provisioning script MUST be safe to run more than once: existing resources
are detected and reused or updated, not duplicated or errored on. A stopped or
deallocated VM MUST be started/allocated rather than recreated. Every resource
that can be created MUST have a corresponding teardown path: a full `destroy`
that removes the resource group, and a lighter `--vm-only` deallocation that
stops compute billing while preserving state.

*Rationale: Idempotency makes automation trustworthy; guaranteed teardown
prevents orphaned GPU resources from silently accruing cost.*

### III. Secure Access by Default (NON-NEGOTIABLE)

The model endpoint MUST be exposed over HTTPS/TLS; plain-HTTP exposure of the
inference API to any non-loopback address is prohibited. The API MUST require a
secret API key on every request, and the deployment MUST provide a documented
mechanism to generate and rotate that key. Secrets (API keys, Hugging Face
tokens, TLS private keys) MUST NEVER be hardcoded or committed; they are
supplied via environment variables or a secret store and excluded from version
control.

*Rationale: An unauthenticated, unencrypted GPU inference endpoint is an open
invitation to credential theft and compute abuse; auth and transport encryption
are the minimum non-negotiable controls.*

### IV. Single Source of Configuration

All tunable values — resource group, region, VM size, model path, ports,
tensor-parallel size, endpoint names — MUST live in one central, version-tracked
configuration file that every script sources. No value may be duplicated or
hardcoded across scripts. Every configuration variable MUST support runtime
override via environment variable without editing files.

*Rationale: Centralized configuration eliminates drift, makes the blast radius
of a change obvious, and lets the same scripts target different environments.*

### V. Verifiability & Observability

The deployment MUST provide explicit checks that report actual observed state,
not assumptions: NSG rules MUST be inspectable and confirmed effective, the VM
power state MUST be queryable, and the served endpoint MUST expose a health/test
path. Scripts MUST emit timestamped, human-readable progress and clearly
distinguish informational, warning, and error output.

*Rationale: GPU deployments fail in slow, expensive ways; fast verification and
clear logging turn multi-minute failures into immediate, diagnosable signals.*

## Security & Networking Requirements

- **Transport**: The public endpoint MUST terminate TLS (HTTPS). A reverse proxy
  or gateway in front of the SGLang server is the expected mechanism for TLS
  termination and API-key enforcement.
- **Authentication**: A secret API key is REQUIRED for all inference requests.
  The key MUST be generatable on demand and rotatable without rebuilding the VM.
- **Network posture**: Wide-open NSG rules (all ports, all protocols, inbound
  and outbound, `0.0.0.0/0`) are permitted ONLY as an explicitly acknowledged,
  documented testing convenience. When used, the all-open posture MUST be
  accompanied by a visible security warning in code and docs, and MUST NOT be
  treated as the production default. Production-intent deployments SHOULD
  restrict source ranges to known IPs and only the SSH and HTTPS ports.
- **Secret handling**: API keys, Hugging Face tokens, and TLS material MUST be
  injected at runtime and MUST be absent from the repository and logs.
- **Region & SKU**: Default region is `indonesiacentral` and default GPU SKU is
  `Standard_NC80adis_H100_v5`; quota MUST be verified before provisioning.

## Compute & Runtime Requirements

- **GPU driver via VM extension**: The NVIDIA CUDA driver on the GPU VM MUST be
  installed through the Azure `NvidiaGpuDriverLinux` VM extension
  (publisher `Microsoft.HpcCompute`), not through manual in-guest driver
  installation. The extension step MUST be idempotent — re-running provisioning
  MUST detect an already-successful extension and skip reinstallation. Driver
  readiness MUST be verifiable (e.g., `nvidia-smi` succeeds) before the model
  server is launched.
- **Containerized model server**: SGLang MUST run as a Docker container using a
  published SGLang image (e.g., `lmsysorg/sglang`) launched via
  `python3 -m sglang.launch_server`, rather than a bare-metal/host Python
  install. The container MUST be granted GPU access (`--gpus all`) with adequate
  shared memory (`--shm-size`, `--ipc=host`) and a persistent Hugging Face cache
  volume so repeated launches avoid re-downloading weights.
- **Container runtime prerequisites**: The VM MUST have Docker and the NVIDIA
  Container Toolkit installed (e.g., via cloud-init at first boot) so the
  container can access the GPUs. The model-server image and tag MUST be defined
  in the single central configuration source (per Principle IV) and overridable
  at runtime.

*Rationale: The supported Azure VM extension is the reliable, idempotent path to
CUDA drivers, and containerizing SGLang keeps the host clean, makes restarts and
upgrades reproducible, and isolates the model runtime from host state.*

## Deployment Workflow & Quality Gates

- **Lifecycle scripts**: The deployment MUST provide, at minimum, scripts to
  (1) provision infrastructure, (2) start/allocate the VM, (3) open the NSG,
  (4) verify the NSG, (5) launch the model server, and (6) destroy resources.
- **Ordering**: Scripts MUST be numbered or otherwise ordered to make the
  intended execution sequence unambiguous.
- **Pre-flight checks**: Before provisioning, scripts MUST confirm `az` is
  installed and authenticated and SHOULD surface quota/region availability.
- **Documentation gate**: Any change to scripts MUST keep the accompanying
  README usage instructions and security warnings accurate.
- **Review gate**: Changes that widen network exposure, alter authentication, or
  touch secret handling MUST be explicitly called out in review.

## Governance

This constitution supersedes ad-hoc practices for this project. All changes to
deployment scripts and configuration MUST comply with the principles above;
deviations MUST be justified in writing and, where they weaken security, treated
as exceptional and time-bounded.

Amendments require: a documented change, a version bump per the policy below,
and an updated Sync Impact Report. Versioning follows semantic versioning:
MAJOR for backward-incompatible governance/principle removals or redefinitions,
MINOR for newly added or materially expanded principles/sections, PATCH for
clarifications and non-semantic refinements.

Compliance is reviewed whenever scripts are modified; reviewers MUST verify that
Principle III (secure access) and the Security & Networking Requirements remain
satisfied before approval.

**Version**: 1.1.0 | **Ratified**: 2026-06-16 | **Last Amended**: 2026-06-17

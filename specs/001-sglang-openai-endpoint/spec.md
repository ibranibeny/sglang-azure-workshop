# Feature Specification: SGLang OpenAI-Compatible Endpoint for Qwen3.6-27B on Azure

**Feature Branch**: `001-sglang-openai-endpoint`

**Created**: 2026-06-16

**Status**: Planned

**Input**: User description: "Have SGLang serve an OpenAI-compatible API for the Qwen/Qwen3.6-27B model on Azure. Deployment via az CLI, region IndonesiaCentral, VM SKU Standard_NC80adis_H100_v5. The deployment must: (1) enable/allocate the VM if it is shut down, (2) open all NSG ports inbound and outbound, (3) verify the NSG is fully open, (4) provide destroy/teardown code, (5) be able to generate an API key, (6) expose the endpoint over HTTPS."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Serve the model over a secure HTTPS OpenAI-compatible endpoint (Priority: P1)

An ML engineer runs the deployment automation and, a few minutes later, has a
running endpoint that speaks the OpenAI Chat Completions protocol, is reachable
over HTTPS, and rejects any request that does not present the correct secret API
key. They point an existing OpenAI client at the endpoint URL and key and get
completions from `Qwen/Qwen3.6-27B`.

**Why this priority**: This is the core value of the whole feature — without a
working, authenticated, encrypted inference endpoint there is nothing to manage,
secure, or tear down. It is the minimum viable product.

**Independent Test**: Run the provisioning + launch automation against a clean
subscription, then send an OpenAI-format chat completion request over HTTPS with
a valid key and confirm a model response; repeat with a missing/invalid key and
confirm rejection.

**Acceptance Scenarios**:

1. **Given** a clean Azure subscription with sufficient GPU quota, **When** the operator runs the provisioning and launch automation, **Then** an HTTPS endpoint becomes available that returns a valid OpenAI-format chat completion from `Qwen/Qwen3.6-27B`.
2. **Given** a running endpoint, **When** a client sends a request with the correct API key over HTTPS, **Then** the request is served successfully.
3. **Given** a running endpoint, **When** a client sends a request with a missing or incorrect API key, **Then** the request is rejected as unauthorized and no inference is performed.
4. **Given** a running endpoint, **When** a client attempts to connect over plain HTTP to the public address, **Then** the connection is refused or redirected to HTTPS and the inference API is never served unencrypted.

---

### User Story 2 - Manage the VM lifecycle (allocate, start, destroy) (Priority: P2)

An operator needs to control cost and availability: bring the VM back online
when it has been deallocated, stop compute billing when idle, and completely
remove all resources when the workload is finished.

**Why this priority**: GPU compute is expensive; the ability to start a stopped
VM and to fully tear everything down is essential for safe, cost-controlled
operation, but it depends on the endpoint (P1) existing first.

**Independent Test**: Deallocate the VM, run the start/allocate automation, and
confirm the VM returns to a running state; then run the teardown automation and
confirm all created resources are gone.

**Acceptance Scenarios**:

1. **Given** a VM that is stopped or deallocated, **When** the operator runs the start/allocate automation, **Then** the VM is brought to a running state and the endpoint can be relaunched.
2. **Given** a VM that is already running, **When** the operator runs the start/allocate automation, **Then** the automation reports no change and does not error or duplicate resources.
3. **Given** a deployed environment, **When** the operator runs the full teardown automation and confirms, **Then** all resources created by the deployment are removed.
4. **Given** a deployed environment, **When** the operator runs the compute-only teardown, **Then** compute billing stops while the VM and its state are preserved for a later restart.

---

### User Story 3 - Open and verify network exposure (Priority: P3)

An operator opens all inbound and outbound ports on the network security group
for testing access, and then runs a verification step that confirms the
all-open rules are present and effective.

**Why this priority**: Network reachability is required to consume the endpoint,
but it is a supporting concern layered on top of a working, secured endpoint and
is explicitly a testing-only convenience.

**Independent Test**: Apply the open-all-ports automation, then run the
verification automation and confirm it reports allow-all inbound and outbound
rules as present and effective.

**Acceptance Scenarios**:

1. **Given** a provisioned network security group, **When** the operator runs the open-all automation, **Then** rules allowing all inbound and all outbound traffic are present.
2. **Given** an open network security group, **When** the operator runs the verification automation, **Then** it reports the allow-all inbound and outbound rules and whether they are effective on the VM.
3. **Given** a network security group missing an allow-all rule, **When** the operator runs the verification automation, **Then** it clearly reports which direction is not fully open.
4. **Given** the open-all automation is invoked, **When** it runs, **Then** it emits a visible security warning that the configuration exposes all ports to the public internet and is for testing only.

---

### User Story 4 - Generate and rotate the API key (Priority: P3)

An operator generates a fresh secret API key for the endpoint, and can later
rotate it, without rebuilding the VM.

**Why this priority**: Key generation and rotation are required for secure
operation and credential hygiene, but they support the secured endpoint (P1)
rather than standing alone.

**Independent Test**: Run the key-generation automation, confirm a new secret is
produced and the endpoint accepts it; rotate the key and confirm the old key is
rejected and the new key is accepted.

**Acceptance Scenarios**:

1. **Given** a deployment with no key yet, **When** the operator runs the key-generation automation, **Then** a sufficiently strong secret API key is produced and made available to the endpoint without being committed to version control.
2. **Given** an endpoint with an active key, **When** the operator rotates the key, **Then** the endpoint accepts the new key and rejects the previous key, without the VM being recreated.

---

### Edge Cases

- What happens when the requested GPU SKU has no quota or capacity in the target region? The provisioning step must surface the failure clearly rather than silently hang.
- What happens when the model is gated and no valid model-access token is supplied? The launch step must fail with a clear, actionable message instead of an opaque download error.
- What happens when the operator re-runs provisioning against an already-deployed environment? It must detect existing resources and not create duplicates (idempotency).
- How does the system handle a request that arrives while the model is still loading? It should not appear "ready" until the endpoint can actually serve completions.
- What happens when the VM is deallocated while the endpoint is expected to be up? Lifecycle automation must distinguish "stopped" from "running" and act accordingly.
- What happens when a self-signed certificate is used and a client enforces certificate verification? The behavior (and how to trust or override it) must be documented.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST provision all required Azure resources (resource group, networking, public address, GPU virtual machine) for the target region and GPU SKU using scripted Azure CLI automation.
- **FR-002**: The system MUST serve the `Qwen/Qwen3.6-27B` model through an OpenAI-compatible API (chat completions) backed by SGLang, using both GPUs of the VM via tensor parallelism.
- **FR-003**: The system MUST detect when the VM is stopped or deallocated and start/allocate it, and MUST NOT recreate the VM when it already exists. *(Req 1)*
- **FR-004**: The system MUST provide automation to open all inbound and all outbound ports (all protocols, all sources) on the network security group. *(Req 2)*
- **FR-005**: The open-all-ports automation MUST emit a visible security warning indicating that exposing all ports to the public internet is for testing only and is not the production default.
- **FR-006**: The system MUST provide automation that inspects the network security group and reports whether allow-all inbound and outbound rules are present and effective. *(Req 3)*
- **FR-007**: The system MUST provide teardown automation that removes all created resources, and a separate lighter option that stops compute billing while preserving the VM and its state. *(Req 4)*
- **FR-008**: The system MUST provide automation to generate a strong secret API key for the endpoint, and MUST support rotating that key without recreating the VM. *(Req 5)*
- **FR-009**: The system MUST require a valid secret API key on every inference request and MUST reject requests with a missing or invalid key.
- **FR-010**: The system MUST expose the endpoint over HTTPS/TLS and MUST NOT serve the inference API over plain HTTP to any non-loopback address. *(Req 6)*
- **FR-011**: The system MUST keep all secrets (API key, model-access token, TLS private key) out of version control and inject them at runtime via environment variables or a secret store.
- **FR-012**: All tunable values (resource group, region, VM SKU, model path, ports, tensor-parallel size, endpoint/certificate names) MUST be defined in a single central configuration source that every script reads, with per-value runtime override supported.
- **FR-013**: Provisioning automation MUST verify that the Azure CLI is installed and authenticated before attempting to create resources.
- **FR-014**: Each provisioning and lifecycle operation MUST be safe to run repeatedly (idempotent), reusing or updating existing resources rather than duplicating or failing.
- **FR-015**: The system MUST emit timestamped, human-readable progress output that distinguishes informational, warning, and error conditions.
- **FR-016**: The system MUST expose a way to confirm the endpoint is actually ready to serve completions (health/readiness check) distinct from the VM merely being powered on.
- **FR-017**: Lifecycle and launch scripts MUST be ordered or numbered so the intended execution sequence is unambiguous.

### Key Entities *(include if feature involves data)*

- **Deployment Configuration**: The single authoritative set of tunable values (region, GPU SKU, resource and network names, model path, ports, tensor-parallel size, certificate identity). Sourced by every script; overridable at runtime.
- **GPU Virtual Machine**: The compute host running the model server; has a power state (running / stopped / deallocated) and hosts the GPUs used for inference.
- **Network Security Group**: The set of inbound/outbound rules controlling reachability of the VM; the subject of the open-all and verification operations.
- **API Key (Secret)**: The secret credential required on every inference request; generatable and rotatable; never stored in version control.
- **TLS Certificate / Endpoint Identity**: The material enabling HTTPS termination in front of the model server.
- **Model Endpoint**: The externally consumed OpenAI-compatible HTTPS URL that serves `Qwen/Qwen3.6-27B` chat completions.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Starting from a clean subscription with quota, an operator can reach a working, authenticated HTTPS inference endpoint by running the documented automation in sequence, with no manual portal steps.
- **SC-002**: 100% of inference requests lacking a valid API key are rejected, and 100% of plain-HTTP attempts to the public address fail to receive an unencrypted inference response.
- **SC-003**: An operator can restart a deallocated VM and return the endpoint to a serving state using a single documented command, without recreating the VM.
- **SC-004**: An operator can fully remove all deployed resources with a single documented teardown command, leaving no orphaned compute, network, or address resources.
- **SC-005**: Re-running any provisioning or lifecycle command against an already-deployed environment produces no duplicate resources and no errors.
- **SC-006**: An operator can generate a new API key and rotate it such that the previous key stops working and the new key works, without recreating the VM.
- **SC-007**: The network-verification command correctly reports the open/closed state of inbound and outbound traffic in 100% of trials, including when a direction is not fully open.
- **SC-008**: No secret (API key, model-access token, TLS private key) appears in any committed file in the repository.

## Assumptions

- The Azure CLI is installed and the operator can authenticate interactively (`az login`); this one-time login is the only permitted manual step.
- GPU quota for `Standard_NC80adis_H100_v5` in `indonesiacentral` is available or will be requested before provisioning; quota acquisition is out of scope for the automation.
- The target SKU provides two GPUs, so the model is served with a tensor-parallel size of two by default (overridable via configuration).
- Because the endpoint is reached via a public IP with no pre-existing DNS name, HTTPS uses a self-signed certificate by default; clients must trust it or disable verification, and substituting a CA-signed certificate (which requires a DNS name) is an optional override documented but not automated.
- Access to the `Qwen/Qwen3.6-27B` weights is available; if the model is gated, a valid model-access token is supplied at runtime via environment variable.
- The all-ports-open network posture is an explicitly acknowledged testing-only convenience per the project constitution, not the production default; restricting source ranges is recommended for real use.
- A single-VM, single-region deployment is sufficient for this feature; high availability, autoscaling, and multi-region failover are out of scope.
- TLS termination and API-key enforcement are performed by a reverse proxy/gateway in front of the SGLang server on the same VM.

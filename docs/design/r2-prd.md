# PRD: R2 — DevWorkspace Lifecycle on Kind

**Branch:** `release/r2`
**Status:** Shipped and verified

---

## Problem Statement

The platform team needs to prove that a DevWorkspace can be stood up on a local Kind cluster and reach a running, exec-able state before committing to the full OpenShift DevSpaces deployment. Without this proof, the team cannot be confident the DevWorkspace Operator lifecycle works, that the workspace URL plumbing is correct, or that the per-user namespace isolation shape is sound — all of which are prerequisites for R3 (deny list) and beyond.

---

## Solution

R2 installs the DevWorkspace Operator (DWO) on a fresh Kind + Calico cluster alongside its required dependencies (cert-manager, ingress-nginx), applies a blank single-container workspace in a per-user namespace, and verifies two done-criteria: the workspace reaches `Running` phase and `kubectl exec` into the workspace pod exits 0. No web IDE, no egress enforcement, no PATH restriction — lifecycle proof only.

---

## User Stories

1. As a platform engineer, I want a single `make up` command to build the full R2 stack from nothing, so that setup is reproducible and the order of dependencies is explicit.
2. As a platform engineer, I want `make verify` to assert both R2 done-criteria automatically, so that I know the release is complete without manual inspection.
3. As a platform engineer, I want cert-manager installed and ready before DWO is applied, so that DWO's webhook TLS is correctly provisioned on Kind (where no platform CA exists).
4. As a platform engineer, I want ingress-nginx installed with Kind port mappings, so that the workspace URL plumbing exists for future releases.
5. As a platform engineer, I want the DevWorkspaceOperatorConfig to set `clusterHostSuffix: 127.0.0.1.nip.io`, so that workspace endpoint hostnames resolve to localhost via nip.io on the dev machine.
6. As a platform engineer, I want the blank workspace to live in a per-user namespace (`aienclave-testuser`), so that the namespace-per-user isolation shape is established from R2 onward.
7. As a platform engineer, I want the workspace pod to carry the `aienclave/egress: restricted` label from R2 onward, so that the ADR 0002 confinement convention is real and the label is present before R5 adds the policy that acts on it.
8. As a platform engineer, I want `make verify` to tolerate DWO's slow image pull times (up to 10 minutes), so that the assertion does not produce false negatives on first cluster creation.
9. As a platform engineer, I want `make down` to cleanly tear down the cluster, so that R2 can be re-run from scratch at any time.
10. As a platform engineer, I want all kubectl commands to use `--context kind-aienclave`, so that operations on the AIEnclave cluster never accidentally target a co-resident cluster (e.g. `stackrox-dev`).
11. As a platform engineer, I want all external manifests (Calico, ingress-nginx, cert-manager, DWO) applied from pinned upstream URLs — never vendored — so that the repo stays small and the version intent is explicit.
12. As a platform engineer, I want the DWO namespace (`devworkspace-controller`) created before applying `combined.yaml`, so that the apply does not fail on a missing namespace.
13. As a future-release developer, I want the blank devfile to be the seed shape for R3–R5, so that later releases evolve the same container rather than introducing a new workspace definition.
14. As a project reader, I want the Makefile to include numbered, commented install steps, so that the ordering rationale is clear without reading all ADRs.

---

## Implementation Decisions

### Stack and install order

`make up` builds in strict order (each step gates the next):

1. `kind create cluster` with R1 config + `extraPortMappings` 80/443 on the control-plane node
2. Calico (ADR 0001) — CNI, enforces NetworkPolicy
3. ingress-nginx (Kind manifest, ADR 0005) — exposes workspace URLs
4. cert-manager v1.15.3 (ADR 0004) — provides DWO webhook TLS on Kind
5. Create `devworkspace-controller` namespace (combined.yaml does not create it)
6. DWO v0.41.0 `combined.yaml` (ADR 0006)
7. `DevWorkspaceOperatorConfig` — sets `clusterHostSuffix: 127.0.0.1.nip.io` (ADR 0003)
8. Create `aienclave-testuser` namespace
9. Blank `DevWorkspace` CR

### DevWorkspaceOperatorConfig name is hard-coded by DWO

DWO v0.41.0 looks up the operator config by the fixed name `devworkspace-operator-config` in the `devworkspace-controller` namespace. Any other name is silently ignored, causing `basic` routing to fail with "clusterHostSuffix must be set." The config CR must use exactly that name.

### Workspace namespace: per-user from R2

Workspaces are created in `aienclave-testuser` (hardcoded test stand-in), not `default`. This establishes the namespace-per-user isolation shape. On real OpenShift/Che, the platform provisions namespaces per user on first login; with bare DWO the namespace is pre-created. Workspace naming (`aienclave-<userid>`) is deferred — R2 retains `aienclave-blank`.

### Blank workspace shape (ADR 0006)

Single container (`quay.io/wto/web-terminal-tooling:1.2`, pinned named tag), `routingClass: basic`, `command: ["tail", "-f", "/dev/null"]`, 256Mi/512Mi memory. Modelled on DWO `samples/plain.yaml`. Not `samples/empty.yaml` (no container → exec fails). Not `che-code` (large image, browser surface, out of scope).

### pod-override carries the egress label

`aienclave/egress: restricted` (ADR 0002) is applied via `spec.template.attributes.pod-overrides.metadata.labels` — the DWO pod-override merge mechanism. Label confirmed present on the deployed workspace pod. The NetworkPolicy that selects this label is NOT applied in R2 (R5 owns egress enforcement).

### Kind port mappings adjusted for dev machine

Host ports 8080/8443 used instead of 80/443 because `stackrox-dev` cluster holds 80/443 on the dev machine. `containerPort` stays 80/443 (ingress-nginx listens there inside the node).

### Calico rollout timeout

Calico daemonset may need >120s to roll out on WSL2. The `make up` Makefile step uses `--timeout=120s` which timed out on the first run (node image was cold). Subsequent runs pass within timeout once the image is cached. A future improvement would be to increase the timeout or use a retry loop.

### Verification strategy

`scripts/verify.sh` polls `DevWorkspace.status.phase` until `Running` (600s timeout, 10s interval), fails fast on `Failed` phase. Then `kubectl exec` into the pod found by label `controller.devfile.io/devworkspace_name=aienclave-blank`. No browser assertion — R2 is lifecycle-only.

---

## Testing Decisions

A good test for this release asserts **observable cluster state**, not internal DWO reconciliation details:
- Phase field on the `DevWorkspace` CR
- Exit code of `kubectl exec` into the workspace pod

**`make verify` is the test.** It is the acceptance gate for R2 done-criteria. No unit tests are written for shell scripts or YAML manifests — integration tests against a live cluster are the meaningful signal here.

Future test concern: if R2's `make up` is re-run (full `make down` + `make up` cycle), verify whether cert-manager readiness gating is sufficient or whether additional webhook stabilisation time is needed before applying `devworkspace-blank.yaml`.

---

## Out of Scope

- Web IDE / browser-loads-IDE end-to-end (deferred; needs `che-code` workspace, large image pulls)
- Egress enforcement / NetworkPolicy active on workspace pod (R5)
- PATH restriction / deny list (R3)
- Copilot CLI auth / PVC (R4)
- Real OpenShift deployment (R6)
- Automatic namespace provisioning per user (bare DWO; Che handles this on OpenShift)
- Workspace naming convention `aienclave-<userid>` (deferred)
- Air-gap / offline cert-manager or image resolution (R6)

---

## Further Notes

- **cert-manager is Kind-specific** (ADR 0004). On OpenShift R6 the service-CA operator provides webhook TLS automatically; cert-manager drops out of the install order when porting.
- **DWO namespace gap** is a known DWO v0.41.0 behaviour: `combined.yaml` does not create `devworkspace-controller`. The Makefile compensates with `kubectl create namespace --dry-run=client | apply -f -` (idempotent).
- **`Recreate` deployment strategy**: DWO uses `strategy: Recreate` for workspace deployments — one pod at a time, no rolling update. Expected for a single-user workspace.
- **`ownerReferences`**: The workspace pod is owned by the `DevWorkspace` CR; deleting the CR cascades cleanly to the deployment and pod.
- **Workspace URL plumbing is stood up but unexercised in R2**. `*.127.0.0.1.nip.io:8080/8443` resolves correctly via nip.io but no IDE page exists to load. Proven end-to-end browser access is deferred to a release that adds a web IDE.

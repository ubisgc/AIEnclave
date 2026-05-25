# PRD: R3 — Hardened Workspace: Tool Deny List and PATH Enforcement

**Branch:** `release/r3`
**Status:** Shipped and verified

---

## Problem Statement

The platform team needs to verify that a workspace container running GitHub Copilot CLI is effectively prevented from executing cluster management tools (`kubectl`, `oc`, `helm`, `ssh`, `scp`). Without this verification, the team cannot be confident that an AI agent operating inside the workspace cannot pivot to production clusters or lateral systems, even if the tools are nominally absent. The R3 question is empirical: does Copilot's agent mode respect PATH-level wrappers, or does it resolve binary paths absolutely and bypass them?

---

## Solution

R3 replaces the blank R2 workspace with a hardened custom image built on UBI9-minimal. The image installs GitHub Copilot CLI (`copilot` binary via the `gh.io/copilot-install` installer) and `gh` CLI, but intentionally omits cluster tools. Deny wrappers (one-line shell scripts that exit 1 with a policy message) are baked into the image at `/denied-bins/`. The DevWorkspace spec prepends `/denied-bins` to `PATH` via the devfile container `env` field. `make verify` asserts all four done-criteria automatically.

A local Docker registry (`kind-registry:5000`) bridges Docker and the Kind cluster, required because DWO unconditionally sets `imagePullPolicy: Always` on all workspace containers.

---

## User Stories

1. As a platform engineer, I want `make up` to build a custom workspace image and push it to a local registry before cluster creation, so that DWO can pull it with `imagePullPolicy: Always` without a remote registry.
2. As a platform engineer, I want `make image` to build and push independently, so that I can iterate on the image without tearing down the cluster.
3. As a platform engineer, I want `make down` to also stop and remove the local registry container, so that no stale containers are left after teardown.
4. As a platform engineer, I want the Kind cluster configured with a containerd mirror for `kind-registry:5000`, so that DWO can resolve and pull the workspace image by name from within the cluster.
5. As a platform engineer, I want the workspace image to be based on UBI9-minimal, so that the image is compatible with OpenShift DevSpaces when R6 ports the devfile to the tooling cluster.
6. As a platform engineer, I want `gh` CLI and the `copilot` binary installed in the workspace image at build time, so that the AI coding agent is available without runtime downloads.
7. As a platform engineer, I want deny wrappers baked into the image at `/denied-bins/` for `kubectl`, `oc`, `helm`, `ssh`, and `scp`, so that enforcement is part of the image and not dependent on runtime volume mounts or operator behaviour.
8. As a platform engineer, I want the devfile container `PATH` env to prepend `/denied-bins`, so that wrappers shadow any residual binaries the image ships (e.g. `openssh-clients` pulled in as a `git` dependency).
9. As a platform engineer, I want `HOME` set to `/home/user` (world-writable, created in the image) in the devworkspace env, so that Copilot can write its cache and config when DWO assigns an arbitrary non-root UID.
10. As a platform engineer, I want `make up` to wait for the DWO webhook serving certificate to be `Ready` before applying any DevWorkspace, so that the mutating webhook does not reject the apply with a TLS connection error.
11. As a platform engineer, I want `make verify` to assert that the `aienclave-r3` DevWorkspace reaches `Running` phase, so that workspace lifecycle is confirmed as part of the done-criteria.
12. As a platform engineer, I want `make verify` to assert that `kubectl exec` into the workspace pod exits 0, so that the pod is reachable for further inspection.
13. As a platform engineer, I want `make verify` to assert that running `kubectl` inside the workspace produces the deny message and exits non-zero, so that PATH enforcement is empirically confirmed.
14. As a platform engineer, I want `make verify` to assert that `command -v kubectl` inside the workspace resolves to `/denied-bins/kubectl`, so that it is confirmed the wrapper shadows any real binary rather than a real binary being on PATH.
15. As a platform engineer, I want the ADR (0007) for the wrapper delivery approach to document why ConfigMap volumeMount was rejected and why baking into the image was chosen, so that the decision is traceable when the approach is revisited for R6.

---

## Implementation Decisions

### Custom workspace image (UBI9-minimal)

- Base: `registry.access.redhat.com/ubi9/ubi-minimal:9.4` — chosen for OpenShift R6 portability.
- `microdnf` used; `curl` omitted from install list because UBI9-minimal ships `curl-minimal` which conflicts with the full `curl` package.
- `git` is installed and pulls in `openssh-clients` as a transitive dependency — `ssh` and `scp` are therefore present in the image. Deny wrappers for those two are load-bearing, not redundant.
- `gh` CLI installed via direct tarball download from GitHub releases (`v2.52.0` pinned). No package repo needed.
- `copilot` binary installed via `curl -fsSL https://gh.io/copilot-install | bash` — this is the standalone GitHub Copilot CLI, not the `gh copilot` extension. The entry point is `copilot`, not `gh copilot`.
- Deny wrappers written at image build time via a `RUN` loop — one script per blocked tool, each prints `<tool>: blocked by AIEnclave policy (ADR 0007)` to stderr and exits 1.
- `/home/user` created with `chmod 777` so the arbitrary UID assigned by DWO at runtime can write Copilot cache and gh config.

### Why ConfigMap volumeMount was rejected (ADR 0007)

DWO explicitly rejects `pod-overrides` that target `spec.containers`, returning: `cannot use pod-overrides to override pod containers`. This makes it impossible to add a `volumeMount` or set `imagePullPolicy` on the workspace container via the DevWorkspace spec. Wrappers must therefore live inside the image itself.

### Local registry

DWO sets `imagePullPolicy: Always` on all workspace containers unconditionally. `kind load docker-image` loads the image onto the node but is bypassed when pull policy is `Always`. A local `registry:2` container is started on `localhost:5001` (host) / `5000` (internal), connected to the `kind` Docker network, and configured as a containerd mirror in `kind-config.yaml`. The devworkspace image reference uses `kind-registry:5000/aienclave-workspace:r3`.

### DevWorkspace spec env

Two env vars set via devfile container `env` (native Devfile v2 — not pod-overrides):
- `PATH=/denied-bins:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` — hardcoded because K8s env values do not support `$(PATH)` expansion.
- `HOME=/home/user` — overrides the build-time `ENV HOME=/root`; needed because `/root` is not writable by the runtime UID.

### DWO webhook race

Applying a DevWorkspace immediately after `rollout status` on the DWO controller deployment can hit "connection refused" on the mutating webhook — the deployment is ready but the TLS serving cert issued by cert-manager is not yet propagated. Fix: `kubectl wait certificate/devworkspace-controller-serving-cert -n devworkspace-controller --for=condition=Ready --timeout=60s` before any DevWorkspace apply.

### verify.sh assertion 4

`which` is not installed on UBI9-minimal. Assertion 4 uses `kubectl exec -- sh -c 'command -v kubectl'` (`command` is a shell builtin, always available) instead of `kubectl exec -- which kubectl`.

---

## Testing Decisions

`make verify` is the test suite for R3. Good tests for infrastructure code assert observable external behaviour — not internal state — at the boundary of the system under test (the workspace container).

**Assertion 1 — Lifecycle:** DevWorkspace reaches `Running` phase within 600 s. Confirms DWO can schedule and start the custom image.

**Assertion 2 — Exec:** `kubectl exec -- echo ok` exits 0. Confirms the pod is reachable and the container is running.

**Assertion 3 — Deny message (key R3 assertion):** Running `kubectl version` inside the workspace produces `blocked by AIEnclave policy (ADR 0007)` in stderr and exits non-zero. This directly answers the R3 open question: PATH wrappers are respected. If this assertion had failed with exit 0 and real cluster output, it would mean Copilot agent mode resolves binaries by absolute path, bypassing PATH — which would require enforcement at the image layer (layer 1) or admission control.

**Assertion 4 — Wrapper resolution:** `command -v kubectl` returns `/denied-bins/kubectl`. Confirms the wrapper is the resolved binary, not a fallback.

No unit tests — all behaviour is infrastructure-level and only meaningful when running against a live cluster.

---

## Out of Scope

- **Copilot agent mode bypass test** — whether Copilot's agent (not interactive shell) respects PATH when autonomously executing shell commands. The interactive deny was confirmed; agent-mode invocation of shell tools was not systematically tested in R3. Tracked as an open question for R4/R5.
- **`--deny-tool` flag** — the done-criteria referenced Copilot CLI starting with `--deny-tool` flags. The `copilot` binary installed via `gh.io/copilot-install` does not expose this flag in v1.0.54. The interactive deny-wrapper approach supersedes this requirement for R3.
- **Enterprise tenant behaviour** — R3 was run on a home lab with a personal GitHub account (Copilot Free). Enterprise tenant config (Azure, data residency, org policy) was not tested. Third-party MCP servers appeared disabled, but this reflects org Copilot policy on the personal account, not R3 enforcement.
- **Token storage location** — `/login` was run inside the workspace confirming Copilot can authenticate, but where the token lands (`~/.copilot/config.json`, keychain, or elsewhere) was not inspected. This is R4's question — requires a company machine with an enterprise account.
- **Egress restriction** — `git clone github.com` succeeded from inside the workspace, confirming egress is open. Tightening egress is R5.
- **OpenShift portability** — devfile is not yet tested on OpenShift DevSpaces. That is R6.

---

## Further Notes

**R3 empirical answer:** PATH wrappers are respected. `kubectl` inside the workspace exits 1 with the deny message; `command -v kubectl` resolves to `/denied-bins/kubectl`. The enforcement assumption holds for interactive shell use.

**DWO constraints discovered:**
- `pod-overrides` cannot modify `spec.containers` — forces wrappers into the image.
- `imagePullPolicy: Always` is unconditional — forces a local registry for Kind dev loops.
- Webhook cert race — always wait for cert-manager to issue the serving cert before applying DevWorkspaces.

**UBI9-minimal packaging quirk:** `curl` conflicts with pre-installed `curl-minimal`; omit `curl` from `microdnf install` lists. `curl-minimal` provides the `curl` binary and is sufficient for the Copilot installer script.

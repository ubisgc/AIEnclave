# PRD: R5 — Egress Observation and Enforcement

**Branch:** `release/r5`
**Status:** Shipped and verified

---

## Problem Statement

The platform team needs to know exactly which external endpoints GitHub Copilot CLI contacts during normal operation, and confirm that a Kubernetes NetworkPolicy can enforce that allowlist without breaking Copilot functionality. Without this, the team cannot justify the egress posture to security stakeholders or configure the real OpenShift cluster's network controls. The R5 question is empirical: which FQDNs does Copilot actually need, and does a deny-all-except-allowlist policy break anything?

---

## Solution

R5 adds a two-phase egress control workflow to the existing hardened workspace. Phase 1 (observe): CoreDNS query logging is enabled, capturing all DNS queries from the workspace pod in real time. The user runs Copilot commands and git operations while `scripts/capture-traffic.sh watch` streams DNS hits. Phase 2 (enforce): the observed FQDNs are resolved to CIDRs and written into a Kubernetes NetworkPolicy scoped to the workspace pod label. `make verify` asserts Copilot still works post-enforcement and that an unexpected domain (example.com) is blocked. The workspace image is also extended with Node.js and the `skills` CLI for AI toolchain use.

On the real OpenShift cluster, RHACS (Advanced Cluster Security — already deployed) replaces the manual CoreDNS capture with live per-pod network flow monitoring and automated policy generation. This is tracked as R7.

---

## User Stories

1. As a platform engineer, I want `scripts/capture-traffic.sh start` to enable CoreDNS query logging and print the workspace pod IP, so that I can identify which DNS queries belong to the workspace.
2. As a platform engineer, I want `scripts/capture-traffic.sh watch` to stream live DNS queries from the workspace pod, so that I can observe Copilot's network activity in real time during a session.
3. As a platform engineer, I want `scripts/capture-traffic.sh fqdns` to extract a deduplicated list of FQDNs queried by the workspace pod, so that I have an input for building the egress allowlist.
4. As a platform engineer, I want `scripts/capture-traffic.sh stop` to disable CoreDNS query logging, so that CoreDNS logs are not permanently polluted after the capture session.
5. As a platform engineer, I want `make up` to apply an open-egress NetworkPolicy before starting the workspace, so that Copilot can reach all endpoints during Phase 1 observation without manual intervention.
6. As a platform engineer, I want a separate enforced NetworkPolicy manifest with CIDR-based allowlist, so that Phase 2 enforcement is a single `kubectl apply` once the FQDN list is known.
7. As a platform engineer, I want `make verify` to assert the workspace is Running, Copilot responds before enforcement, the NetworkPolicy is applied, Copilot still responds after enforcement, and an unexpected domain is blocked, so that all R5 done-criteria are checked automatically.
8. As a platform engineer, I want the egress allowlist to include GitHub CIDRs, GitHub CDN CIDRs, and npm registry CIDRs, so that Copilot auth, API calls, git clone, and runtime skill/plugin installation all work within the enforced policy.
9. As a platform engineer, I want the enforced NetworkPolicy to deny all egress except DNS and the explicit allowlist, so that unexpected outbound connections are blocked by default.
10. As a platform engineer, I want the workspace image to include Node.js and the `skills` CLI, so that users can install AI toolchain skills and plugins without leaving the workspace.
11. As a platform engineer, I want Node.js and `skills` CLI installed outside `/home/user`, so that the PVC mount at `/home/user` does not shadow these tools at runtime.
12. As a platform engineer, I want `make up` to poll the DWO webhook endpoint until it has an IP before applying DevWorkspace manifests, so that the webhook TLS race does not cause `make up` to fail.
13. As a platform engineer, I want the R5 PRD to document that on the real OpenShift cluster RHACS replaces the manual capture workflow (R7) and corporate proxy replaces direct CIDR-based allowlists (R8), so that the Kind dev loop findings are correctly contextualised for production.

---

## Implementation Decisions

### Two-phase egress model

Phase 1 (`netpol-workspace-egress-open.yaml`): a NetworkPolicy that allows all egress from the workspace pod. Applied by `make up`. Used during traffic capture.

Phase 2 (`netpol-workspace-egress-enforce.yaml`): a NetworkPolicy with a CIDR-based allowlist + deny-all default. Applied manually once the FQDN list is built. The two policies share the same name (`workspace-egress`) in the same namespace, so `kubectl apply` of the enforce policy replaces the open policy in-place.

### CoreDNS query logging

CoreDNS's `log` plugin is patched into the running `coredns` ConfigMap via `sed` and a `rollout restart`. This avoids any changes to the Kind cluster config. The capture script enables logging, streams logs filtered by workspace pod IP, extracts FQDNs, and restores the ConfigMap on `stop`. The log format is:

```
[INFO] <pod-ip>:<port> - <id> "<type> IN <fqdn>. udp ..." <status> ...
```

FQDN extraction uses: `grep -oP '(?<= IN )\S+(?=\. (?:udp|tcp))'` followed by filtering out cluster-local search domain suffixes (`.cluster.local`, `.svc.`, `.home`).

### Observed egress endpoints (personal Copilot Free account, 2026-05-25)

| FQDN | Resolved CIDR | Purpose |
|------|---------------|---------|
| `github.com` | `140.82.112.0/20` | Auth device flow |
| `api.github.com` | `140.82.112.0/20` | GitHub API |
| `api.individual.githubcopilot.com` | `140.82.112.0/20` | Copilot API |
| `telemetry.individual.githubcopilot.com` | `140.82.112.0/20` | Copilot telemetry |
| `raw.githubusercontent.com` | `185.199.108.0/22` | GitHub CDN (git pack fetch, raw content) |
| `registry.npmjs.org` | `104.16.0.0/20` | npm package registry (runtime skill install) |

`raw.githubusercontent.com` was discovered during a `git clone` test after the initial Copilot capture — confirms the capture must include git operations, not only Copilot API calls.

### NetworkPolicy structure

Three egress rules:
1. DNS (UDP+TCP port 53) to any destination — required for FQDN resolution.
2. HTTPS (TCP 443) to `140.82.112.0/20` — GitHub (all Copilot + git endpoints).
3. HTTPS (TCP 443) to `185.199.108.0/22` and `104.16.0.0/20` — GitHub CDN and npm registry.

Pod selector: `aienclave/egress: restricted` — set via `pod-overrides` in the DevWorkspace spec (inherited from R3/R4).

### npm registry CIDR risk note

`104.16.0.0/20` is a Cloudflare range shared with services beyond npmjs.org. This is acceptable in the Kind dev loop. On the real OpenShift cluster (R8), all npm traffic routes through the org proxy, which provides package-level filtering. The CIDR is documented with this caveat in the NetworkPolicy manifest.

### Runtime skill/plugin install requirement

Users must be able to install Copilot skills and plugins at runtime (`npx skills@latest add <skill>`), not only use pre-baked tools. This requires npm registry egress. Pre-installing in the image is a fallback for known tools (e.g. `skills` CLI), but runtime install is the expected workflow.

### Node.js installation

Node.js v20.19.2 installed from the official release tarball (direct download, no package manager). Only the `bin/node`, `bin/npm`, `bin/npx`, `lib/`, and `include/` paths are extracted. Installed to `/usr/local` so it is on the standard PATH and unaffected by the PVC mount at `/home/user`.

### `skills` CLI pre-installation

`skills` CLI installed globally via `npm install --global --prefix /opt/skills skills@latest` at image build time. `/opt/skills/bin` prepended to `PATH` in the DevWorkspace container env. Installed outside `/home/user` to avoid PVC shadowing. `chmod -R a+rX /opt/skills` ensures any runtime UID can execute the binary.

### DWO webhook endpoint probe

`make up` now polls the `devworkspace-webhookserver` endpoint in the DWO namespace until an IP appears in `.subsets[0].addresses[0].ip`, with a 2-second interval and 30-iteration limit. This replaces the prior `kubectl wait certificate` + implicit sleep approach, which was not sufficient — the TLS cert being Ready does not mean the webhook server has opened its listener.

### RHACS replaces this workflow on OpenShift (R7)

The CoreDNS capture + manual CIDR building is a Kind dev loop workaround. RHACS, already deployed on the org's OpenShift tooling cluster, provides per-pod network flow monitoring that is live, persistent, and does not require manual setup. R7 validates that RHACS produces an equivalent allowlist and can enforce it via admission control.

### Corporate proxy invalidates direct CIDRs (R8)

The organisation routes all egress through a corporate HTTP/HTTPS proxy. On the real cluster, the NetworkPolicy CIDR allowlist must target the proxy IP, not GitHub or npm registry IPs. All tools (copilot, git, node, npm) must receive `HTTPS_PROXY`, `HTTP_PROXY`, and `NO_PROXY` env vars via the DevWorkspace spec. R8 addresses this.

---

## Testing Decisions

`make verify` is the R5 test suite. Good tests assert observable external behaviour at the workspace boundary — not internal state.

**Assertion 1 — Lifecycle:** DevWorkspace reaches `Running` within 600 s. Confirms PVC + image pull succeed with the updated image.

**Assertion 2 — Open egress baseline:** `copilot --version` responds before the enforce policy is applied. Confirms the workspace can reach Copilot endpoints with open egress.

**Manual step:** Script pauses and instructs the user to apply the enforce NetworkPolicy.

**Assertion 3 — Policy present:** `workspace-egress` NetworkPolicy exists in the workspace namespace. Confirms the correct policy name was applied.

**Assertion 4 — Copilot survives enforcement (key R5 assertion):** `copilot --version` responds after the enforce policy is applied. A failure here means a required endpoint is missing from the CIDR allowlist.

**Assertion 5 — Unexpected egress blocked:** `curl --connect-timeout 5 https://example.com` exits non-zero. Confirms the default-deny posture is active.

Known noise: `copilot --version` emits a WebSocket warning (`Unknown stream id 1`) and reports `Package extraction took Nms` on first invocation. These are startup artefacts, not errors — the version string appears despite the noise.

No unit tests — all behaviour is infrastructure-level and meaningful only against a live cluster.

---

## Out of Scope

- **Enterprise tenant endpoints** — capture was run against a personal GitHub account (Copilot Free). Enterprise tenant (Azure AD, org SSO, GitHub Enterprise) may add Microsoft/Azure CDN endpoints. Re-capture on a company machine before R6.
- **FQDN-based NetworkPolicy** — Calico CE does not support FQDN matching in standard NetworkPolicy. CIDRs are used. Calico Enterprise or a DNS proxy (e.g. CoreDNS egress plugin) would enable FQDN-based rules.
- **UDP/non-HTTPS egress** — only DNS (53) and HTTPS (443) are in the allowlist. Copilot WebSocket traffic uses HTTPS upgrade — no additional ports needed based on the capture.
- **Corporate proxy configuration** — R8. All direct-internet CIDRs are replaced by the proxy IP on the real cluster.
- **RHACS integration** — R7. Manual CoreDNS capture is a Kind dev loop substitute.
- **Internal npm mirror** — an alternative to allowing `registry.npmjs.org` directly (Nexus, Artifactory, Verdaccio). Deferred to R8 proxy work.
- **`npx <pkg>@latest` at runtime** — requires npm registry egress, now allowed in the NetworkPolicy. Not tested end-to-end in R5 due to workspace restart during image rebuild; validated at network level by the CIDR addition.

---

## Further Notes

**R5 empirical answer:** Copilot CLI (personal account) needs five FQDNs, all resolving to two GitHub-owned CIDRs (`140.82.112.0/20`, `185.199.108.0/22`). A single additional CIDR (`104.16.0.0/20`) covers npm registry for runtime skill installation. Three rules in the NetworkPolicy (DNS + two HTTPS blocks) are sufficient.

**Discovered during session:**
- `raw.githubusercontent.com` only appeared after running `git clone` — not seen in Copilot-only traffic. Egress capture must include all workspace operations users are expected to perform, not just the primary tool.
- `registry.npmjs.org` was blocked by the enforce policy, surfacing as an `ETIMEDOUT` error from `npx skills@latest`. This revealed that runtime plugin install is a functional requirement that must be in the allowlist — pre-baking all tools in the image is not a complete substitute.
- DWO webhook TLS race: the `kubectl wait certificate --for=condition=Ready` gate is insufficient. The webhook server needs additional time after cert issuance to mount the secret and open the TLS listener. Fixed by polling the endpoint IP instead.

**`copilot --version` noise:** The version check emits WebSocket and package extraction log lines on first invocation. These do not indicate failure but make verify output harder to read. Consider replacing with a lighter liveness check (e.g. `copilot --help` or checking the binary path) before R6.

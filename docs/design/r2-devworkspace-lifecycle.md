# R2 Design — DevWorkspace lifecycle on Kind

**Status:** proposed (awaiting human approval gate, TEAM.md §5)
**Branch:** `release/r2`
**Question R2 answers:** Does the Workspace lifecycle work? — `kubectl get devworkspace` shows `Running`, `kubectl exec` into the Workspace container succeeds.

This doc records the R2 decisions and the target file tree. Decisions that are hard to reverse / surprising are captured as ADRs 0003 (amended), 0004, 0005, 0006. This doc is the map; the ADRs are the why.

---

## How DWO reconciles a Workspace

Mental model for the full lifecycle — from CR to running container:

```
User creates DevWorkspace CR
        │
        ▼
DWO controller watches for DevWorkspace CRs (operator pattern)
        │
        ├─ reads Devfile from CR template (or URL)
        ├─ creates Pod  ← container images + command from Devfile components
        │                  injects devworkspace-controller sidecar for lifecycle mgmt
        ├─ creates Service  ← routes traffic to the Pod
        └─ creates Ingress  ← exposes Workspace URL (*.clusterHostSuffix)
```

**Namespace = user isolation boundary.** Each user's workspace lives in its own namespace. Kubernetes RBAC on that namespace controls who can `get`/`exec`/`delete` it. With bare DWO (no Che), namespaces are pre-created; Che/DevSpaces would auto-provision them per user on first login.

**Pod = enclave enforcement point (ADR 0002).** NetworkPolicy and the deny list attach to the Pod. The Devfile pod-override adds `aienclave/egress: restricted` so Calico can select it.

**Access.** DWO creates the Ingress and Workspace URL for browser IDE access. In R2 the container only runs `tail -f /dev/null` — no IDE — so the verify path is `kubectl exec`, not a browser load.

---

## Scope (tight)

**In:** Stand up DWO on a fresh Kind cluster and prove one blank Workspace reaches `Running` and is `exec`-able. Stand up the ingress + Workspace URL *plumbing* (ADR 0003).

**Out (and why):**
- No web IDE / `che-code` (heavy image pulls; R2 is lifecycle-only — ADR 0006).
- No browser-loads-IDE end-to-end test (nothing to load without an IDE — ADR 0003 consequences).
- No egress block applied (egress tightening is R5 — ADR 0006). The `restricted` label is present as a hook.
- No PATH restriction / deny list (R3).
- No Copilot auth / PVC (R4).

---

## The stack and install ordering

`make up` builds the whole R2 stack from nothing (fresh cluster — `make down` first). Ordering is load-bearing because each layer gates the next:

```
1. kind create cluster  (R1 config + extraPortMappings 80/443)   → node Ready
2. kubectl apply Calico  (ADR 0001, unchanged)                    → calico-node rollout complete
3. kubectl apply ingress-nginx (kind manifest, ADR 0005)          → controller pod Ready
4. kubectl apply cert-manager  (pinned, ADR 0004)                 → cert-manager pods Ready
5. kubectl apply DWO combined.yaml (pinned, ADR 0006/CONTEXT)     → DWO pods Ready
6. kubectl apply DevWorkspaceOperatorConfig (clusterHostSuffix)   → applied
7. kubectl apply blank DevWorkspace (test-dev/)                   → DevWorkspace Running
```

Each `kubectl apply` of an infrastructure layer is followed by a `kubectl wait`/`rollout status` gate, mirroring R1's `make up`. Steps 3–4 may run in either order; both must be Ready before step 5. Step 6 must precede step 7 so endpoints get a hostname suffix.

**Pinned versions** (platform-engineer confirms exact tags at build time; these are the design baseline):
- Calico `v3.32.0` (unchanged, ADR 0001)
- ingress-nginx — the kind-published manifest (`kind.sigs.k8s.io/examples/ingress/deploy-ingress-nginx.yaml`)
- cert-manager — a pinned release manifest (e.g. `v1.15.x`)
- DevWorkspace Operator — a pinned **stable** tag (e.g. `v0.41.0`; not the `v1.0.0-alpha*` line)

---

## Decisions (resolved in the grill)

| # | Decision | Choice | ADR |
|---|----------|--------|-----|
| 1 | Che vs DWO-only | **DWO only**, via `combined.yaml` (no Che dashboard/registries/OLM) | CONTEXT term; ADR 0006 |
| 2 | Webhook TLS on Kind | **cert-manager is mandatory**, installed before DWO | ADR 0004 |
| 3 | Ingress controller | **ingress-nginx** (kind manifest, DWO-documented) | ADR 0005 |
| 4 | Workspace URL scheme | `*.127.0.0.1.nip.io` via DWO `clusterHostSuffix`; drop `aienclave.` label + dashed form | ADR 0003 (amended) |
| 5 | Blank devfile | `plain.yaml`-shaped single container + `restricted` label; **not** `empty.yaml` | ADR 0006 |
| 6 | Fresh vs layered cluster | **Fresh** cluster per release; R2 kind-config = R1 config **+** `extraPortMappings` | this doc |
| 7 | Egress block in R2 | **Not applied** (R5 owns egress); label present as hook only | ADR 0006 |
| 8 | Verification | Poll `DevWorkspace` phase == `Running` (long timeout); `kubectl exec` echo exits 0 | this doc |

---

## Kind config change (decision 6)

R2 **extends** R1's `kind/kind-config.yaml` rather than adding a second file — one cluster definition per release branch is the convention. The merge keeps R1's CNI swap and pod subnet (so ADR 0001/0002 still hold) and adds port mappings (so browser traffic reaches the ingress controller). Illustrative shape (platform-engineer realises exact YAML):

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true          # R1 / ADR 0001 — kindnet doesn't enforce NetworkPolicy
  podSubnet: "192.168.0.0/16"       # R1 / ADR 0001 — keep pod IPs out of 10.0.0.0/8
nodes:
  - role: control-plane
    extraPortMappings:              # R2 — host 80/443 → node 80/443 → ingress-nginx hostPort
      - { containerPort: 80,  hostPort: 80,  protocol: TCP }
      - { containerPort: 443, hostPort: 443, protocol: TCP }
    kubeadmConfigPatches:
      - |
        kind: ClusterConfiguration
        controllerManager:
          extraArgs:
            cluster-cidr: "192.168.0.0/16"
```

Single control-plane node satisfies the ingress-nginx scheduling constraints (ADR 0005). Multi-node would need the `ingress-ready` label revisited.

## DevWorkspaceOperatorConfig (decision 4)

A `DevWorkspaceOperatorConfig` named in the `devworkspace-controller` namespace sets:

```yaml
config:
  routing:
    clusterHostSuffix: "127.0.0.1.nip.io"   # Workspace URL = <dwo-prefix>.127.0.0.1.nip.io
```

This is the corrected mechanism (ADR 0003): traffic to `*.127.0.0.1.nip.io:80/443` resolves to `127.0.0.1`, hits Kind's `extraPortMappings`, lands on the ingress-nginx controller. The official DWO doc uses the Kind *node* IP (`172.18.x.nip.io`); we use `127.0.0.1.nip.io` because the host port-mapping path is what the team's browsers actually reach, and it keeps the URL host-independent. **Platform-engineer to confirm** the suffix resolves end-to-end during implementation; if the node-IP form proves necessary, that is a mechanism tweak within ADR 0003, not a scope change.

## Blank Workspace (decision 5)

Single container, `routingClass: basic`, sleeping command, carrying `aienclave/egress: restricted` (ADR 0002) via a devfile pod-override. Illustrative (not implementation):

```yaml
kind: DevWorkspace
apiVersion: workspace.devfile.io/v1alpha2
metadata:
  name: aienclave-blank
spec:
  started: true
  routingClass: 'basic'
  template:
    components:
      - name: tooling
        container:
          image: quay.io/wto/web-terminal-tooling:next   # placeholder; pin a real tag
          memoryRequest: 256Mi
          memoryLimit: 512Mi
          command: ["tail", "-f", "/dev/null"]
    # pod-override adds label aienclave/egress: restricted (ADR 0002) — exact syntax is impl detail
```

The pod-override carrying the `restricted` label is a **binding requirement** (ADR 0002), even though no policy selects it in R2.

## Verification (decision 8)

`scripts/verify.sh` (rewritten from R1's) asserts exactly the two done-criteria, nothing about browser/IDE:

1. **Lifecycle:** poll `kubectl get devworkspace aienclave-blank` until phase `Running`, with a generous timeout (DWO's own doc warns image pulls can exceed 5 min). FAIL on timeout.
2. **Exec:** `kubectl exec` into the Workspace pod (selected by the well-known `controller.devfile.io/devworkspace_name` label) running `echo`/`id`; PASS iff exit 0.

Mirror R1 verify.sh structure: pinned `--context`, PASS/FAIL lines, single exit code.

---

## Target file tree (R2 additions in **bold**)

```
Makefile                              # extend: up/down/verify build full R2 stack
CONTEXT.md                            # updated: DevWorkspace Operator term, Workspace URL fix
kind/
  kind-config.yaml                    # extend: + extraPortMappings 80/443
scripts/
  verify.sh                           # rewrite: assert R2 done-criteria
test-dev/
  netpol-block-rfc1918.yaml           # R1 — NOT applied in R2 (kept for R5)
  **devworkspaceoperatorconfig.yaml** # clusterHostSuffix: 127.0.0.1.nip.io
  **devworkspace-blank.yaml**         # the blank Workspace (labelled, single container)
docs/
  design/
    **r2-devworkspace-lifecycle.md**  # this doc
  adr/
    0003-workspace-url-ingress-scheme.md   # amended (mechanism corrected)
    **0004-cert-manager-prerequisite-for-dwo-on-kind.md**
    **0005-ingress-nginx-as-the-ingress-controller.md**
    **0006-r2-blank-workspace-shape.md**
```

Note: ingress-nginx, cert-manager, Calico and DWO are applied **from pinned upstream URLs** (ADR 0001 style) — not vendored into the repo.

---

## Risks / things for the human to weigh

1. **Workspace URL is plumbing-only in R2** (ADR 0003). If the human expects "open a browser, see an IDE" as part of R2, that requires the `che-code` workspace and is a scope expansion (would belong as an R2.5 or fold into R6). Recommend keeping R2 lifecycle-only.
2. **cert-manager is a new external dependency** (ADR 0004) — Kind-only, drops out on OpenShift. Acceptable for the PoC, consistent with ADR 0001's apply-from-URL stance.
3. **`clusterHostSuffix: 127.0.0.1.nip.io` vs node-IP** — design picks the host-mapping form; flagged for platform-engineer to confirm end-to-end. Mechanism tweak if wrong, not a redesign.
4. **DWO pinned stable tag** — avoid `v1.0.0-alpha*`. Platform-engineer pins the exact tag at build.
```


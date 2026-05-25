# Brainstorm: AIEnclave — Secure AI Workspace on OpenShift

**Date:** 2026-05-25  
**Participants:** Søren (Platform Team)  
**Format:** Grill-me session  
**Status:** Brainstorm complete — PoC concept, not approved policy

---

## Problem Statement

Need a secure, policy-compliant environment (**AIEnclave**) for running AI coding tools (GitHub Copilot CLI) without risk of AI agent accessing production credentials or violating company software policies.

### Context

- Highly regulated company
- Daily work involves OpenShift clusters with live production `kubectl`/`oc` contexts
- Company policy: strict control over installed software and vulnerability posture
- WSL2 is an approved technology
- Only approved AI tool: **GitHub Copilot CLI** (Azure Enterprise, company tenant)
- Claude and other AI tools: **not allowed** by company policy

---

## Threat Model

| Threat | Severity | Notes |
|--------|----------|-------|
| AI agent reads prod kubeconfig, runs destructive cluster commands | High | Has not happened, proactive concern |
| AI tool itself has known vulnerabilities, violates software policy | High | Company requires clean vuln posture |
| Source code sent to public AI endpoint (data exfil) | **Mitigated** | Azure Enterprise tenant — data stays within company |
| AI installs additional binaries (e.g. its own kubectl) | Medium | Needs deny list coverage |
| AI exfils code via git push to unknown remote | Medium | Deny list candidate |

---

## Key Decisions

### Primary Approach: AIEnclave — OpenShift DevWorkspace on Tooling Cluster

Run Copilot CLI inside an AIEnclave (OpenShift DevWorkspace) on a **dedicated tooling cluster**, physically and logically separated from production.

**Rejected / deferred alternatives:**
- WSL2 dual-distro: viable personal fallback, but no audit trail, RFC1918 network not isolatable, harder to share with team — **not a PoC target**
- Local container (Podman): security team may not accept as isolation boundary — **not a PoC target**
- Local VM: heavy, still on same physical machine as prod creds — **not a PoC target**

**PoC decision:** DevWorkspace solution only. Local options remain personal fallback at best.

### PoC Testing Approach: Kind + Eclipse Che

Test DevWorkspace concept locally before requiring a real OpenShift tooling cluster.

| Layer | Tool | Notes |
|-------|------|-------|
| Local Kubernetes | **Kind** (Kubernetes IN Docker) | Runs full k8s cluster locally in Docker |
| Workspace operator | **Eclipse Che** or **DevWorkspace Operator** | Open-source upstream of OpenShift DevSpaces — runs on vanilla k8s |
| Network enforcement | Calico or Cilium CNI | Default Kind CNI does not enforce NetworkPolicy — must swap |

**Devfile format is an open standard (devfile.io)** — devfile written for Kind/Che PoC ports directly to OpenShift DevSpaces with no changes.

**PoC progression:**
```
Kind + Eclipse Che (local) → validate devfile, workspace lifecycle, NetworkPolicy, PVC
        │
        ▼
OpenShift tooling cluster → port devfile, validate in real environment
```

Zero dependency on real cluster for initial PoC work.

### Authentication

GitHub OAuth device flow on workspace startup → token stored on PVC (persists between sessions). Platform team controls workspace template.

### Data Privacy

Copilot runs on **Azure Enterprise** — all model inference stays within company tenant. Not public OpenAI/GitHub endpoints. Data residency concern: resolved.

---

## Architecture

```
Developer laptop (prompts, browser)
        │
        ▼
OpenShift Tooling Cluster (separate from prod)
  └── DevWorkspace (isolated namespace)
        ├── Copilot CLI (agent mode)
        ├── PVC (GitHub OAuth token persists)
        ├── Mounted: source repos only
        ├── NOT installed: kubectl, oc, helm, oc CLI
        ├── Egress: github.com (auth) + Azure Enterprise Copilot endpoints
        └── Policy: deny list at OS/PATH level
```

**Production cluster: never reachable from workspace.**

---

## Command Policy: Deny List

Model: **default allow, explicit deny** (platform team are trusted users).

### High Priority Blocks

| Command/Tool | Reason | Enforcement |
|---|---|---|
| `kubectl` / `oc` / `helm` | No cluster access | Not installed + PATH restricted |
| `curl` / `wget` to RFC1918 | Prevent SSRF to internal services | Network policy or shell wrapper |
| `git remote add` / `git push` to unknown remotes | Prevent source exfil | Shell wrapper |
| `ssh` / `scp` | No lateral movement | Not installed |

### Consider Blocking

| Command/Tool | Reason |
|---|---|
| `pip install` / `npm install -g` | Agent could self-install blocked tools |
| `chmod +x` on downloaded files | Executable drop |

### Enforcement Mechanism

Copilot CLI has no native command policy file — enforcement at workspace/OS level:

1. **DevWorkspace template** — don't install blocked binaries (strongest for `kubectl`/`oc`)
2. **Restricted PATH** — workspace only exposes approved binaries
3. **Shell wrappers** — replace blocked commands with scripts that exit 1 with clear error

---

## Open Questions

1. Does Copilot CLI agent mode respect shell config that blocks certain commands, or does it bypass shell wrappers?
2. Can OpenShift NetworkPolicy on tooling cluster block RFC1918 egress from workspace pods?
3. What Copilot/Azure egress endpoints need to be allowlisted?
4. Audit logging — does platform team need logs of what Copilot executed, or is isolation sufficient for PoC?
5. Workspace template versioning and change control — who approves changes to the deny list?

---

## Next Steps (PoC)

- [ ] Stand up Kind cluster with Calico/Cilium CNI
- [ ] Install Eclipse Che or DevWorkspace Operator on Kind cluster
- [ ] Define DevWorkspace template (devfile) with no cluster CLI tools
- [ ] Set up PVC for token persistence
- [ ] Test GitHub OAuth flow inside workspace
- [ ] Implement PATH restriction / shell wrappers for deny list
- [ ] Validate NetworkPolicy egress enforcement on Kind
- [ ] Test Copilot CLI agent mode end-to-end in workspace
- [ ] Port devfile to OpenShift tooling cluster
- [ ] Document for potential company policy proposal

---

## Notes

- Target users: platform team only (small, trusted group) for PoC
- Long-term goal: AIEnclave PoC becomes reference architecture / inspiration for company AI tooling policy
- WSL2 dual-distro remains viable personal-use fallback if workspace approach is too heavy

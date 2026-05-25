<p align="center">
  <img src="docs/assets/avatar-dark.svg" width="120" alt="AIEnclave logo"/>
</p>

# AIEnclave

A proof-of-concept for running GitHub Copilot CLI inside a secure, isolated [OpenShift DevWorkspace](https://github.com/devfile/devworkspace-operator) on a dedicated tooling cluster — physically and logically separated from production.

**Target users:** Platform team only.

---

## Problem

Platform engineers work daily with live production OpenShift clusters. Running an AI coding agent (Copilot CLI) on the same machine as production credentials creates real risk:

- AI agent reads prod kubeconfig and runs destructive cluster commands
- AI installs additional binaries that bypass tooling policy
- AI exfiltrates source code to unknown remotes

The solution is isolation: run the AI tooling in a workspace that structurally cannot reach production, rather than relying on the agent to behave.

---

## Architecture

```
Developer laptop (prompts, browser)
        │
        ▼
OpenShift Tooling Cluster  ← separate cluster, not prod
  └── DevWorkspace (isolated namespace)
        ├── Copilot CLI (agent mode)
        ├── PVC — GitHub OAuth token persists between sessions
        ├── Mounted: source repos only
        ├── NOT installed: kubectl, oc, helm, ssh, scp
        ├── Egress allowed: github.com + Azure Enterprise Copilot endpoints only
        └── Restricted PATH + shell wrappers for deny-listed commands
```

**Production cluster is never reachable from the workspace** — enforced by NetworkPolicy egress blocks, not trust.

---

## Security Model

| Layer | Mechanism |
|---|---|
| No cluster tools | Blocked binaries not installed in workspace image |
| Restricted PATH | Workspace only exposes approved binaries |
| Shell wrappers | Deny-listed commands (`kubectl`, `oc`, `helm`, `ssh`, `scp`) exit 1 with error |
| Egress block | NetworkPolicy drops outbound traffic to RFC1918 / internal CIDRs |
| Allowed egress | github.com (auth) + Azure Enterprise Copilot endpoints |
| Data residency | Copilot runs on Azure Enterprise tenant — inference stays within company |

Enforcement order: **(1) don't install → (2) restrict PATH → (3) shell wrapper**. Defense in depth.

---

## PoC Approach

Test the DevWorkspace concept locally before requiring a real OpenShift cluster.

| Layer | Tool |
|---|---|
| Local Kubernetes | [Kind](https://kind.sigs.k8s.io/) (Kubernetes IN Docker) |
| Network enforcement | [Calico](https://projectcalico.docs.tigera.io/) CNI (default Kind CNI does not enforce NetworkPolicy) |
| Workspace operator | DevWorkspace Operator / Eclipse Che |

The devfile format is an open standard — a devfile written for Kind/Che ports directly to OpenShift DevSpaces without modification.

```
Kind + Eclipse Che (local)  →  validate devfile, NetworkPolicy, PVC, auth
        │
        ▼
OpenShift tooling cluster   →  port devfile, validate in real environment
```

---

## Release Ladder

| Release | Delivers | Question answered |
|---|---|---|
| R1 | Kind + Calico + RFC1918 egress block | NetworkPolicy enforcement feasible on Kind? |
| R2 | DevWorkspace Operator, blank workspace starts | Workspace lifecycle works? |
| R3 | Devfile: no cluster tools, restricted PATH, deny list | Do shell wrappers hold against agent mode? |
| R4 | Copilot CLI auth inside workspace | Token location confirmed, PVC scope verified |
| R5 | Progressively tighten egress while Copilot runs | Which endpoints does Copilot actually need? |
| R6 | Port devfile to OpenShift tooling cluster | Devfile portable without changes? |

Each release is isolated on a dedicated branch (`release/rN`) and answers one empirical question.

---

## Prerequisites

```bash
kind       # https://kind.sigs.k8s.io/
kubectl    # https://kubernetes.io/docs/tasks/tools/
docker     # running daemon required
```

---

## Quick Start

```bash
make up      # create Kind cluster with Calico CNI and apply NetworkPolicy
make verify  # run done-criteria checks for the current release
make down    # tear down cluster
```

---

## Repository Layout

```
Makefile            # cluster lifecycle: up / down / verify
CONTEXT.md          # project glossary — canonical term definitions
kind/               # Kind cluster configuration
scripts/            # verify.sh and other shell scripts
test-dev/           # NetworkPolicy manifests, test pods
docs/
  releases.md       # full release ladder and done-criteria
  adr/              # architecture decision records
  brainstorm/       # threat model, rejected alternatives, full context
```

---

## Key Constraints

- Production cluster must never be reachable from workspace — enforced by NetworkPolicy, not convention
- OAuth token stored plaintext on PVC (headless Linux, no keychain) — accepted risk, quantified in R4
- Copilot CLI runs on Azure Enterprise tenant — source code does not leave the company
- This is a PoC; target audience is the platform team, not end users

---

## Background

See [`docs/brainstorm/aienclave-brainstorm.md`](docs/brainstorm/aienclave-brainstorm.md) for the full threat model, architecture decisions, and rejected alternatives.  
See [`docs/releases.md`](docs/releases.md) for done-criteria per release.  
See [`CONTEXT.md`](CONTEXT.md) for the project glossary and canonical terminology.

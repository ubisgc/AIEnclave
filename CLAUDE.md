# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

AIEnclave is a PoC for running GitHub Copilot CLI in a secure, isolated OpenShift DevWorkspace on a dedicated tooling cluster — separated from production. Target users: platform team only.

See `docs/brainstorm/aienclave-brainstorm.md` for threat model, architecture decisions, and rejected alternatives.  
See `docs/releases.md` for the full release ladder and done-criteria per release.

## Tech Stack

- **Cluster automation:** Makefile (`make r1-up`, `make r1-down`, etc. — one target per release)
- **K8s manifests:** Raw YAML (no Helm, no Kustomize)
- **Workspace templates:** Devfile v2 YAML
- **Scripting:** Bash where needed
- **Local cluster:** Kind (Kubernetes IN Docker) with Calico or Cilium CNI (default Kind CNI does not enforce NetworkPolicy)

## Repository Layout (grows per release)

```
Makefile            # cluster lifecycle targets: up / down / verify (branch = release context)
CONTEXT.md          # project glossary (ubiquitous language)
kind/               # Kind cluster configs
scripts/            # shell scripts (verify.sh, etc.)
test-dev/           # dev/test manifests (NetworkPolicy, test pods, etc.)
docs/
  releases.md       # release ladder + done-criteria
  adr/              # architecture decision records
  brainstorm/       # threat model, architecture, rejected alternatives
```

Each release is isolated on its own branch (`release/rN`). Makefile targets are the entry point per release.

## Branching

Every release starts on a dedicated branch: `release/r<N>` (e.g. `release/r1`). No implementation work on `master` directly.

## Key Architectural Constraints

- Production cluster must never be reachable from workspace — enforced via NetworkPolicy
- Blocked in workspace: `kubectl`, `oc`, `helm`, `ssh`, `scp` — not installed, PATH restricted
- Enforcement order: (1) don't install binary, (2) restrict PATH, (3) shell wrapper exiting 1
- Copilot CLI runs on Azure Enterprise tenant — data stays within company
- OAuth token stored plaintext on PVC (headless Linux, no keychain) — by design, quantified in R4

## Common Commands

```bash
make up      # stand up cluster for current release
make down    # tear down cluster
make verify  # run done-criteria checks
```

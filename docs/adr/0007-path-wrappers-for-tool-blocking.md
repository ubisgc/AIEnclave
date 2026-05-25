# ADR 0007 — PATH wrappers for blocked tool enforcement

**Status:** Accepted  
**Release:** R3

---

## Context

R3 must prevent the workspace from running cluster management tools (kubectl, oc, helm, ssh, scp).
The threat model has three enforcement layers (ADR 0002):
1. Don't install the binary
2. Restrict PATH
3. Shell wrapper exiting 1

The base image (`quay.io/wto/web-terminal-tooling:1.2`) ships kubectl and oc.
We cannot strip binaries without building a custom image.

## Decision

Mount a ConfigMap of shell wrappers at `/denied-bins`. Set `PATH=/denied-bins:…` via the
devfile container `env` field. Wrappers shadow real binaries and exit 1 with a deny message.

The open question R3 closes: **does Copilot CLI agent mode respect PATH, or does it exec
binaries via absolute path?** If via absolute path, the wrapper is bypassed and enforcement
falls back to layer 1 (install-time absence) — not available on this image, so a custom image
or admission control would be required for R4+.

## ConfigMap delivery

ConfigMap over init-container or custom image because:
- No registry needed for Kind dev loop
- Wrapper content is readable and diffable in git
- DWO's `pod-overrides` strategic merge can attach a ConfigMap volume to the generated pod

## Consequences

- `kubectl <cmd>` inside workspace → wrapper exits 1 + deny message to stderr
- `which kubectl` → `/denied-bins/kubectl` (wrapper, not the real binary)
- If agent resolves `/usr/bin/kubectl` directly → wrapper bypassed → recorded as finding, R4 addresses via image
- Wrappers are single-layer: a user with shell access can call the real binary by absolute path — not the threat model (blocked user, not blocked root)

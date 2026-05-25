---
status: proposed
---

# R2's blank Workspace is a single-container devfile, no web IDE, no egress block

R2's "blank workspace" is a `DevWorkspace` with a single tooling container that does nothing but stay alive (`tail -f /dev/null`), modelled on the DWO project's `samples/plain.yaml` with `routingClass: basic`. It is deliberately **not** the `samples/empty.yaml` (`template: {}`), which defines no container and therefore produces no pod to `kubectl exec` into — failing R2's second done-criterion. It is also deliberately **not** a `che-code` workspace: pulling the web-IDE contribution adds large image pulls and a browser session as failure suspects in an experiment whose only question is "does the Workspace lifecycle work?".

The workspace pod carries the `aienclave/egress: restricted` label (ADR 0002's project-wide confinement convention) via a devfile pod-override, so the boundary holds from R2 onward. But R2 **does not** re-apply R1's RFC1918 egress block (`test-dev/netpol-block-rfc1918.yaml`). Egress tightening is explicitly R5; applying it in R2 would add "image pull blocked?" / "endpoint unreachable?" to a lifecycle-only experiment. The label is present (so the convention is real and testable later); the policy that acts on it is not.

## Considered Options

- **`plain.yaml`-shaped single container, labelled, no egress block (chosen)** — exec-able, Running fast, no IDE pull, honours ADR 0002, defers egress to R5.
- **`empty.yaml`** — minimal but produces no container; fails `kubectl exec`. Rejected.
- **`che-code` IDE workspace** — proves a browser-loads-IDE flow, but heavy image pulls and a web surface beyond R2's lifecycle question. Deferred.

## Consequences

- R2's done-criteria are met without any web IDE; the Workspace URL plumbing (ADR 0003/0005) is stood up but not exercised by a real browser session in R2.
- The blank devfile is the seed the later releases evolve: R3 strips cluster tools / restricts PATH on this same container shape; R4 adds the PVC + Copilot auth; R5 adds the egress allowlist that the `restricted` label already anticipates.
- Because the label is present but no policy selects it in R2, a future reader must not assume "labelled == confined" until R5 — the label is a hook, not yet an enforced boundary.

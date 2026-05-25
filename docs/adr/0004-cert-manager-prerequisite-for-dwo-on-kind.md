---
status: proposed
---

# cert-manager is a hard prerequisite for the DevWorkspace Operator on Kind (R2)

R2 installs cert-manager (pinned, single `kubectl apply` from its release manifest) *before* the DevWorkspace Operator, because DWO's webhook server needs a TLS serving cert that nothing on vanilla Kind provides otherwise. This is surprising: on OpenShift the platform's service-CA operator injects that cert automatically, so the dependency is invisible in DWO's manifests — but DWO's `combined.yaml` carries `cert-manager.io/inject-ca-from` annotations and mounts a `webhook-tls-certs` secret. Without cert-manager the webhook never gets a cert, the admission/conversion webhook fails, and `DevWorkspace` resources never reconcile to `Running` — failing R2's first done-criterion with an error that does not obviously point at certs.

## Considered Options

- **cert-manager, pinned, apply-from-URL (chosen)** — exactly what DWO's own official Kind-without-OLM install guide does; single manifest, no Helm, matches the ADR 0001 install style.
- **Hand-roll a self-signed cert + CA bundle into the webhook config** — fewer moving parts at runtime but fragile, must be regenerated, and diverges from the documented, tested DWO install path. Rejected.
- **Skip it** — not viable; the webhook simply doesn't function.

## Consequences

- Install ordering in `make up` is load-bearing: cert-manager must be `Ready` before DWO is applied, and DWO must be `Ready` before any `DevWorkspace` is applied. The Makefile gates each step with `kubectl wait`/`rollout status`.
- Adds an external image/manifest dependency fetched at build time (like Calico in ADR 0001) — acceptable for a local Kind PoC; air-gap is an R6 concern.
- This dependency is **Kind-specific**. On the real OpenShift tooling cluster (R6) the service-CA operator covers it, so the cert-manager step is expected to drop out when the devfile/stack ports.

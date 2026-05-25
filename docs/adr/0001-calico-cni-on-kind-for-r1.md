---
status: accepted
---

# Calico as the CNI on Kind for NetworkPolicy enforcement

R1 uses Calico (pinned v3.32.0) as the Kind CNI, installed by applying the upstream manifest from its pinned URL at cluster-build time. Kind's default CNI (kindnet) does not enforce NetworkPolicy, so it is disabled (`disableDefaultCNI: true`) and Calico replaces it. Calico installs as a single self-contained `kubectl apply` (no operator, no Helm), enforces standard Kubernetes NetworkPolicy, and Calico's own CI runs on Kind with exactly this configuration — so the combination is well-supported.

We considered Cilium. Rejected for R1 because its clean install path on Kind wants the `cilium` CLI or Helm, both of which the project's tech stack explicitly excludes (no Helm). Cilium's advantages — eBPF, Hubble, and FQDN-based egress rules — are real and may matter at R5 when egress is tightened to specific Copilot/Azure domains by hostname. R1 only needs CIDR-based egress blocking, which Calico does natively via standard `NetworkPolicy`. The R1 policy uses the standard Kubernetes API, so revisiting the CNI at R5 is cheap.

## Considered Options

- **Calico v3.32.0, apply-from-URL (chosen)** — single manifest, no extra tooling, standard NetworkPolicy, project tests on Kind.
- **Cilium** — better egress story (FQDN rules) for R5, but needs CLI/Helm to install cleanly; deferred as a possible R5 reconsideration.

## Consequences

- `make r1-up` requires network egress to GitHub to fetch the manifest at build time (acceptable for a local Kind PoC; air-gap is an R6 concern on the real cluster).
- Kind pod subnet is set to `192.168.0.0/16` (matching Calico's CI config and its default IP pool) so pod IPs stay out of the blocked `10.0.0.0/8` range; the controller-manager `cluster-cidr` is patched to match.
- If R5 needs FQDN/domain-based egress allowlisting, revisit Cilium; the standard-API R1 policy ports without lock-in.

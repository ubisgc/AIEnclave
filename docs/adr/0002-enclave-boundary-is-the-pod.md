---
status: accepted
---

# The enclave boundary is the workspace pod, not the namespace

The R1 NetworkPolicy confines pods by label (`podSelector: matchLabels: {aienclave/egress: restricted}`), not by selecting the whole namespace. Only pods carrying the label are egress-blocked; an unlabeled pod in the same namespace is unaffected. This is the security model for the whole project: the **Workspace** pod is the unit of confinement, and it carries the `aienclave/egress: restricted` label.

We considered namespace-scoping (block every pod in an `enclave` namespace, prove the contrast with a pod in a second `outside` namespace). Rejected because AIEnclave's boundary is the workspace pod, not the namespace: from R2 the DevWorkspace Operator and Eclipse Che run pods that legitimately share the workspace namespace and must *not* be egress-blocked. Namespace-scoping would force those co-tenants into a separate namespace or require carve-out exceptions; label-scoping confines only the workspace pod and lets co-tenants coexist untouched.

## Consequences

- R1 needs only one namespace; the blocked/allowed contrast is a single label-field difference between two otherwise-identical pods — a crisp, low-variable verification.
- The label `aienclave/egress: restricted` is a project-wide convention. In R2 the workspace pod (or its devfile/DevWorkspace template) must carry it for the policy to apply.
- NetworkPolicy limits inherited by later releases: traffic to/from the pod's own **node** is always allowed regardless of CIDR (Kind node sits on `172.18.x`), `hostNetwork` pods bypass `podSelector` semantics (workspace must never run hostNetwork), and `ipBlock` behavior against DNAT'd Service IPs is undefined (verification must use a literal external IP, never a Service).

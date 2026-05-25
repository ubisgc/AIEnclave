---
status: proposed
---

# ingress-nginx is the R2 ingress controller (kind-flavoured manifest)

R2 uses ingress-nginx, installed from the kind project's purpose-built manifest (`kind.sigs.k8s.io/examples/ingress/deploy-ingress-nginx.yaml`), as the ingress controller that serves the Workspace URL (ADR 0003). ADR 0003 left the choice open between ingress-nginx and Contour; ingress-nginx wins for two concrete reasons: (1) the DevWorkspace Operator's own official Kind-without-OLM install guide uses ingress-nginx, so it is the tested, supported path for exactly our stack; (2) the kind-flavoured manifest binds the controller to the control-plane node via `hostPort` 80/443 and tolerates the control-plane taint, which is precisely what makes Kind's `extraPortMappings` (host 80/443 → node 80/443) carry browser traffic to the controller. It is a single `kubectl apply`, no Helm — consistent with the project stack and ADR 0001's install style.

## Considered Options

- **ingress-nginx, kind manifest (chosen)** — DWO-documented, kind-published, hostPort binding aligns with `extraPortMappings`, single apply.
- **Contour** — works as an Ingress controller, but no first-party kind manifest and no DWO precedent; adds novelty cost for zero R2 benefit.

## Consequences

- The kind ingress-nginx manifest pins the controller to a node carrying the expected scheduling constraints; R2's single-node control-plane satisfies this. A multi-node Kind config would need the `ingress-ready` node label / placement revisited.
- R2 uses the controller's `hostPort` binding as the traffic path. The DWO doc's optional step of re-exposing the controller Service as NodePort is **not** adopted — it is a different path and unnecessary given `extraPortMappings` + hostPort.
- ingress-nginx is the local-PoC choice. On the real OpenShift tooling cluster (R6), Routes/the OpenShift router replace it; this ADR does not bind R6.

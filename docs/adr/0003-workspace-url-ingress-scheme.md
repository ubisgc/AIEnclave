---
status: proposed
---

# Workspace reached by wildcard nip.io hostname via an ingress controller (R2)

Starting in R2, the AIEnclave cluster runs an ingress controller and the workspace web IDE is reached from a browser by a hostname under the wildcard scheme `*.aienclave.127-0-0-1.nip.io` (nip.io resolves the embedded `127-0-0-1` to `127.0.0.1`), not by raw IP or NodePort. This gives stable, human-readable Workspace URLs on a local Kind cluster without editing `/etc/hosts`, and keeps the local URL scheme close to what a real OpenShift route would look like so the devfile ports cleanly (R6).

This is explicitly **not** an R1 concern: R1 proves outbound egress blocking, which involves no inbound traffic, no Service, and no hostname. Pulling ingress into R1 would add an ingress controller, wildcard DNS, and Kind port-mappings as failure suspects in an experiment whose only question is "does Calico drop RFC1918 egress?". Ingress enters when there is a web surface to reach — the Che / DevWorkspace IDE in R2.

## Considered Options

- **nip.io wildcard (chosen)** — zero host-file edits, works for anyone who clones the repo, mirrors OpenShift route shape.
- **`/etc/hosts` entries** — requires per-machine root edits, doesn't scale to wildcard subdomains, friction for the team.
- **NodePort + raw IP** — what the user explicitly rejected; no stable name, ugly URLs, diverges from the OpenShift target.

## Consequences

- R2 design must choose the ingress controller (Che has opinions — likely ingress-nginx or Contour) and set Kind `extraPortMappings` for 80/443.
- The hostname scheme is project-wide baseline from R2 onward; later releases reuse it rather than inventing per-release URL conventions.
- nip.io is an external dependency reachable at resolve time; an offline/air-gapped run would need a fallback (host-file or local wildcard DNS). Note for R6 on the real cluster.

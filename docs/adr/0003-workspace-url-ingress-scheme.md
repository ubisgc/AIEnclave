---
status: proposed
---

# Workspace reached by wildcard nip.io hostname via an ingress controller (R2)

Starting in R2, the AIEnclave cluster runs an ingress controller and the workspace web IDE is reached from a browser by a wildcard `*.nip.io` hostname, not by raw IP or NodePort. This gives stable Workspace URLs on a local Kind cluster without editing `/etc/hosts`, and keeps the local URL scheme close to what a real OpenShift route would look like so the devfile ports cleanly (R6).

**Hostname mechanism (corrected during R2 design).** The hostname is **not** freely chosen by us. The DevWorkspace Operator builds every workspace endpoint hostname as `<dwo-generated-prefix>.<clusterHostSuffix>`, where `clusterHostSuffix` is set in a `DevWorkspaceOperatorConfig`. R2 sets `clusterHostSuffix: 127.0.0.1.nip.io` so that browser traffic to `*.127.0.0.1.nip.io:80/443` resolves to `127.0.0.1` and rides Kind's `extraPortMappings` (host 80/443 → node 80/443 → ingress controller). The original draft scheme `*.aienclave.127-0-0-1.nip.io` is **dropped**: the `aienclave.` middle label fights the operator's hostname builder (we do not control the left labels) and the dashed `127-0-0-1` form adds nothing over the dotted `127.0.0.1`.

This is explicitly **not** an R1 concern: R1 proves outbound egress blocking, which involves no inbound traffic, no Service, and no hostname. Pulling ingress into R1 would add an ingress controller, wildcard DNS, and Kind port-mappings as failure suspects in an experiment whose only question is "does Calico drop RFC1918 egress?". Ingress enters when there is a web surface to reach — the Che / DevWorkspace IDE in R2.

## Considered Options

- **nip.io wildcard (chosen)** — zero host-file edits, works for anyone who clones the repo, mirrors OpenShift route shape.
- **`/etc/hosts` entries** — requires per-machine root edits, doesn't scale to wildcard subdomains, friction for the team.
- **NodePort + raw IP** — what the user explicitly rejected; no stable name, ugly URLs, diverges from the OpenShift target.

## Consequences

- R2 chooses ingress-nginx as the ingress controller (see ADR 0005), and sets Kind `extraPortMappings` for 80/443.
- The hostname scheme is project-wide baseline from R2 onward; later releases reuse it rather than inventing per-release URL conventions.
- nip.io is an external dependency reachable at resolve time; an offline/air-gapped run would need a fallback (host-file or local wildcard DNS). Note for R6 on the real cluster.
- **R2 does not prove a browser actually loads an IDE.** The R2 blank Workspace (ADR 0006) has no web IDE, so there is no page to load — R2 stands up the routing plumbing and the URL scheme, proven by the DevWorkspace reaching `Running` with an endpoint. End-to-end browser-loads-IDE is deferred (it needs the heavy `che-code` contribution and large image pulls), out of R2's lifecycle-only scope.

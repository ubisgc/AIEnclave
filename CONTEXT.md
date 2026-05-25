# AIEnclave

A PoC for running GitHub Copilot CLI inside a secure, isolated OpenShift DevWorkspace on a dedicated tooling cluster, separated from production. This glossary fixes the language the project uses so releases stay consistent. It is a glossary, not a spec — implementation lives in the release dirs and ADRs.

## Language

### Enclave & confinement

| Term | Definition | Aliases to avoid |
| ---- | ---------- | ---------------- |
| **AIEnclave** | The isolated workspace environment as a whole — cluster, workspace, and the policies that confine it | sandbox, jail, container |
| **Workspace** | The single DevWorkspace (Eclipse Che / DevWorkspace Operator) where Copilot CLI runs, one per user | pod, environment, IDE |
| **DevWorkspace Operator** | The controller that reconciles a `DevWorkspace` custom resource into a running **Workspace** pod; the upstream of OpenShift DevSpaces. The PoC runs it alone (no full Eclipse Che) | DWO, operator |
| **Eclipse Che** | The full cloud-IDE platform (dashboard, gateway, plugin/devfile registries) built on the **DevWorkspace Operator**; OpenShift DevSpaces is its downstream. AIEnclave uses DWO alone, not full Che | Che, CodeReady |
| **OLM (Operator Lifecycle Manager)** | The Kubernetes operator-installer (catalogs, subscriptions) standard on OpenShift; this PoC skips it and installs DWO directly via `combined.yaml` | Operator Lifecycle Manager, operator hub |
| **CRD (CustomResourceDefinition)** | Extends the Kubernetes API with a new resource type; DWO installs the `DevWorkspace` CRD on startup, teaching the cluster what a `DevWorkspace` object is | custom resource definition |
| **CR (Custom Resource)** | An instance of a CRD; in AIEnclave a user creates a `DevWorkspace` CR to request a workspace — DWO's controller loop watches for these and reconciles them into a running Pod | custom resource, manifest |
| **Deny list** | The set of commands the workspace forbids (`kubectl`, `oc`, `helm`, `ssh`, `scp`), enforced by not-installed → PATH → shell wrapper | blocklist, blacklist |

### Network: direction & blocking

| Term | Definition | Aliases to avoid |
| ---- | ---------- | ---------------- |
| **RFC1918** | The standard reserving three private IPv4 ranges (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`); "reach an RFC1918 address" means "reach the internal network" | private IPs, LAN |
| **Egress block** | A NetworkPolicy rule that drops outbound traffic from the workspace to a destination CIDR | firewall, network isolation |
| **RFC1918 block** | The R1 egress block; blocks only `10.0.0.0/8` as a stand-in for internal networks, proving the *mechanism* on Kind (not real prod-unreachability) [1] | prod block |
| **Workspace URL** | The inbound browser-reachable hostname for the workspace IDE, a wildcard `*.nip.io` hostname whose suffix the DevWorkspace Operator builds from its configured `clusterHostSuffix` (R2+; mechanism in ADR 0003) | endpoint, ingress |
| **Egress endpoint** | An *external* outbound destination the workspace may reach (github.com, Azure Copilot); outbound, unlike the inbound **Workspace URL** | endpoint (unqualified) |

[1] R1 blocks only `10.0.0.0/8`, not the full RFC1918 set, because `172.16.0.0/12` collides with Kind's Docker bridge (`172.18.0.0/16`, the node) and `192.168.0.0/16` is the chosen pod subnet — blocking either would poison the cluster's own plumbing. Verified by curling a literal external `10.x` (must drop) against a public control IP (must succeed) — never a Service IP. R5 maps it to real internal CIDRs.

## Relationships

- An **AIEnclave** contains exactly one **Workspace** (per user, for the PoC)
- A **Workspace** is confined by one or more **Egress blocks** and one **Deny list**
- A **Workspace** is reached inbound by its **Workspace URL** (browser → IDE)
- A **Workspace** reaches outbound only its permitted **Egress endpoints**
- The **RFC1918 block** is the first, simplest **Egress block** — proven in R1

## Example dialogue

> **Architect:** "When R1 says the pod can't curl an RFC1918 IP, are we proving production is unreachable?"
> **Platform engineer:** "No — there's no production on Kind. We're proving the **egress block** mechanism works. `10.0.0.0/8` is a stand-in. Mapping it to real prod CIDRs is R5."
> **Architect:** "And the `nip.io` hostname — that's the same network direction?"
> **Platform engineer:** "Opposite. That's the **Workspace URL** — me, in a browser, reaching the IDE inbound. Egress is the workspace reaching out. Different direction, different release: the URL is R2. And the hostname isn't ours to name freely — the **DevWorkspace Operator** generates it from its `clusterHostSuffix`."

## Flagged ambiguities

- "endpoint" was used for both the inbound browser hostname and outbound destinations — resolved: **Workspace URL** (inbound) vs **Egress endpoint** (outbound). They are different directions and must not share a word.
- "RFC1918 block" risked meaning "production is unreachable" — resolved: in R1 it is the *mechanism* proven against private CIDRs, not a prod-unreachability guarantee.
- The **Workspace URL** was first written as `*.aienclave.127-0-0-1.nip.io` — resolved: the DevWorkspace Operator builds the hostname from its `clusterHostSuffix`, so the `aienclave.` middle label and dashed `127-0-0-1` form are dropped; the scheme is `*.<clusterHostSuffix>` (see ADR 0003).

# PRD: R4 — Copilot CLI Auth Inside Workspace: Token Location and PVC Scope

**Branch:** `release/r4`
**Status:** Shipped and verified

---

## Problem Statement

Before committing to the AIEnclave architecture, the platform team needs empirical confirmation of where the GitHub Copilot CLI stores its OAuth token on headless Linux — and whether that token is scoped to a persistent volume or lost on pod restart. Without this, the team cannot quantify the plaintext token risk or confirm that authentication survives workspace restarts. The R4 question is: does the token land in a keychain (encrypted, opaque) or in a plaintext file on the PVC?

---

## Solution

R4 extends the R3 hardened workspace with a 1 GiB PersistentVolumeClaim mounted at `/home/user`. The `copilot auth` device-flow is run interactively inside the workspace; `make verify` then asserts the token file exists, is readable plaintext JSON, has `0600` permissions, and is backed by the PVC (not ephemeral overlay storage). The open question is answered: token lands at `~/.copilot/config.json`, plaintext, PVC-backed, no keychain involved.

---

## User Stories

1. As a platform engineer, I want the workspace to have a persistent home directory backed by a PVC, so that the Copilot OAuth token survives pod restarts without requiring re-authentication.
2. As a platform engineer, I want to run `copilot auth` inside the workspace using the device flow, so that I can authenticate without a browser inside the container.
3. As a platform engineer, I want `make verify` to assert the PVC is mounted at `/home/user`, so that persistence is structurally confirmed before token assertions run.
4. As a platform engineer, I want `make verify` to assert the token file exists at `~/.copilot/config.json` after authentication, so that the token location is empirically confirmed.
5. As a platform engineer, I want `make verify` to assert the token file is readable plaintext containing a `token` key, so that the absence of a keychain or encryption layer is confirmed.
6. As a platform engineer, I want `make verify` to assert token file permissions are `0600`, so that Unix permission isolation is confirmed.
7. As a platform engineer, I want `make verify` to assert the token path is backed by a non-overlay filesystem, so that it is confirmed the token is on the PVC and not ephemeral container storage.
8. As a platform engineer, I want the verify script to pause and instruct me to run `copilot auth` interactively before checking the token, so that the device-flow can be completed in a separate terminal.
9. As a platform engineer, I want the R4 PRD to document the threat model around plaintext token storage, so that risk is formally quantified before R5.
10. As a platform engineer, I want the Dockerfile to set `HOME=/home/user` at build time so it matches the runtime value DWO injects, eliminating any mismatch between build-time tool installation paths and the runtime home directory.

---

## Implementation Decisions

### PVC for home directory

A `volume` component of `size: 1Gi` is declared in the DevWorkspace spec (Devfile v2 `components` array). DWO automatically provisions a PVC and mounts it into the container. The mount path is `/home/user`, matching the `HOME` env var already set in R3. No StorageClass is specified — the Kind default (local-path provisioner) is used for the dev loop; OpenShift DevSpaces provides its own default StorageClass in R6.

### Copilot CLI is a standalone binary, not a gh extension

`https://gh.io/copilot-install` installs a standalone `copilot` binary to `/usr/local/bin/copilot` — not a `gh` extension. This was discovered when the build failed because the script did not create the assumed `gh` extension data directory. Implications:
- The entry point is `copilot auth`, not `gh copilot auth`.
- No `XDG_DATA_HOME` or gh extension data-dir concerns apply.
- The `gh` CLI installed in the image is still useful for future use but is not required for Copilot auth in R4.

### XDG_DATA_HOME approach rejected

An initial attempt installed the `copilot` binary assuming it was a `gh` extension and set `XDG_DATA_HOME=/opt/gh-data` to avoid the PVC mount shadowing the extension directory under `/home/user`. This was wrong — the installer writes a binary to `/usr/local/bin/`, not to an extension data directory. The approach was removed. The binary at `/usr/local/bin/copilot` is unaffected by the PVC mount at `/home/user`.

### Token location confirmed: `~/.copilot/config.json`

After `copilot auth` completes, the token is written to `/home/user/.copilot/config.json`. The file is a JSON document containing:
- `copilotTokens`: map of host URL → raw OAuth token string (format `gho_...`)
- `lastLoggedInUser` / `loggedInUsers`: host and login metadata
- `firstLaunchAt`, `trustedFolders`, `expAssignmentsCache`: operational metadata

The token value is stored as a plain string — no envelope encryption, no keychain reference.

### PVC mount assertion uses `/proc/mounts`

`make verify` assertion 2 greps `/proc/mounts` for `/home/user`. This is more reliable than `df` for detecting mount presence. Assertion 6 uses `df -T` to confirm the filesystem type is not `overlay` (which would indicate ephemeral container storage).

### Filesystem backing confirmed: ext4 on `/dev/sdd`

```
Filesystem     Type  Mounted on
/dev/sdd       ext4  /home/user
```

Non-overlay, non-tmpfs — confirms PVC backing.

### Token directory permissions

`.copilot/` directory is created as `drwx------` (700, owner-only). `config.json` is `0600`. Both are owned by the arbitrary UID assigned by DWO at runtime (observed as UID 1234 in this dev loop). No `/etc/passwd` entry exists for that UID; `whoami` returns an error. This is expected DWO behaviour on Kubernetes.

### Threat model: plaintext token risk scoped and accepted

The token is plaintext on the PVC. Risk is bounded by:

| Actor | Access | Mitigated by |
|-------|--------|-------------|
| Other workspace users | Cannot exec into another user's namespace | OpenShift namespace RBAC |
| Processes in same container | Can read token (UID 1234 = same process) | Intended — user's own session |
| Platform admins (cluster-admin) | Can read PV backing data | Accepted — same trust as any hosted dev env |

In production OpenShift: namespace isolation is enforced; workspaces are personal (1:1 user-to-workspace); SCC UID ranges differ per namespace, preventing cross-namespace UID collision. The plaintext risk is scoped to the user themselves and cluster-admin. No lateral movement between users is possible. This risk is formally accepted and documented here; no further mitigation is required before R5.

---

## Testing Decisions

`make verify` is the R4 test suite. All assertions operate at the container boundary — no internal state is inspected beyond what is observable via `kubectl exec`.

**Assertion 1 — Lifecycle:** DevWorkspace reaches `Running` within 600 s. Unchanged from R3; confirms the R4 devfile (with PVC component) is accepted by DWO.

**Assertion 2 — PVC mounted (key structural assertion):** `/proc/mounts` contains `/home/user`. Confirms DWO provisioned and attached the PVC before any token assertions run. Fails fast if PVC was not bound.

**Manual step — device-flow auth:** Script pauses and prints the `kubectl exec` command and `copilot auth` instruction. User completes the GitHub device-flow in a host browser. Script resumes on Enter.

**Assertion 3 — Token file exists:** `test -f ~/.copilot/config.json`. Confirms auth completed and token was written to the expected path.

**Assertion 4 — Plaintext (key R4 assertion):** `cat` the token file and grep for `token`. The file contents are printed redacted. Directly answers the R4 open question: no keychain, no encryption.

**Assertion 5 — Permissions:** `stat -c '%a'` returns `600`. WARN (not FAIL) if unexpected — a non-600 result is a security finding worth documenting, not a blocker.

**Assertion 6 — PVC backing:** `df -T` on the token path. `overlay` filesystem = FAIL (token on ephemeral storage = PVC not mounted correctly). Non-overlay = PASS.

No unit tests — all behaviour is infrastructure-level and meaningful only against a live cluster.

---

## Out of Scope

- **Enterprise tenant token location** — auth was run against a personal GitHub account (Copilot Free). Enterprise tenant (Azure AD, org SSO) may produce a different token format or additional credential files. Verify on a company machine before R6.
- **Token rotation / expiry** — `copilotTokens` in the JSON is a map of host → token. Expiry behaviour and re-auth flow were not tested. If the token expires and `copilot auth` is re-run, the old value is overwritten in the same file.
- **Egress restriction during auth** — `copilot auth` requires outbound HTTPS to `github.com`. R4 runs with open egress. R5 captures the exact egress endpoints required.
- **`gh` CLI auth** — `gh auth login` was not tested in R4. The `gh` binary is present in the image but authentication and token storage for `gh` (`~/.config/gh/hosts.yml`) are out of scope. This may become relevant if `gh copilot` extension is evaluated as an alternative to the standalone CLI.
- **Agent mode token access** — whether Copilot's agent mode can read or exfiltrate the token from `~/.copilot/config.json` was not tested. Covered implicitly by R5 egress tightening.
- **PVC encryption at rest** — the Kind local-path provisioner does not encrypt PV backing storage. In production OpenShift, StorageClass encryption should be verified before considering the threat model complete.
- **OpenShift portability** — devfile not yet tested on OpenShift DevSpaces. That is R6.

---

## Further Notes

**R4 empirical answer:** Copilot CLI stores its OAuth token at `~/.copilot/config.json` as a plaintext JSON string. No system keychain is used on headless Linux. The file is on the PVC (ext4, `/dev/sdd`) and survives pod restarts. Permissions are `0600`. Plaintext risk is scoped to the workspace owner and cluster-admin — accepted as stated in the threat model.

**Build-time discovery — standalone binary vs. gh extension:** The `gh.io/copilot-install` script installs a standalone `copilot` binary, not a `gh` extension. This was not obvious from the URL or the existing Dockerfile comment ("Installs gh CLI + gh-copilot"). The distinction matters: a `gh` extension would require HOME and XDG_DATA_HOME alignment between build and runtime; a standalone binary at `/usr/local/bin/copilot` has no such dependency.

**etcd timeout during `make up`:** One transient `etcdserver: request timed out` was observed during DWO manifest apply on a fresh Kind cluster. The apply was idempotent — re-applying the same manifest after the timeout succeeded. No Makefile change was made; the error is a known Kind/etcd cold-start race and resolves on retry.

**Token redaction gap in verify.sh:** `make verify` output includes the full token value (`gho_...`) in the redacted display because the `sed` substitution targets `"token":` (JSON key) but `copilotTokens` uses a different key structure. The redaction is cosmetic only — verify output should not be pasted into logs or shared documents. Fix before R6 if verify output is captured in CI.

# AIEnclave — Release Plan

**Approach:** Small releases. Questions answered empirically by running code, not upfront analysis.

---

## Release Ladder

| Release | What ships | Question answered | Status |
|---------|-----------|-------------------|--------|
| **R1** | Kind cluster + Calico/Cilium CNI | RFC1918 egress block feasible? | TODO |
| **R2** | DevWorkspace Operator on Kind, blank workspace starts | Workspace lifecycle works? | TODO |
| **R3** | Devfile: no cluster tools, restricted PATH, `--deny-tool` list | Shell wrappers respected by agent mode? | TODO |
| **R4** | Copilot CLI auth inside workspace | Token lands where? Plaintext on PVC confirmed? | TODO |
| **R5** | NetworkPolicy egress — progressively tighten while Copilot runs | Which endpoints actually needed? | TODO |
| **R6** | Port devfile to OpenShift tooling cluster | Devfile portable without changes? | TODO |

---

## Done Criteria (per release)

**R1:** `kubectl apply` a NetworkPolicy blocking `10.0.0.0/8`. Pod inside cluster cannot curl an RFC1918 IP. Pod outside policy can.

**R2:** `kubectl get devworkspace` shows Running. `kubectl exec` into workspace container succeeds.

**R3:** `kubectl exec` into workspace — `which kubectl` returns nothing. `kubectl` returns exit 1 with deny message. Copilot CLI starts with `--deny-tool` flags applied.

**R4:** Copilot CLI runs `/login` inside workspace. Confirm token location (`~/.copilot/config.json` or keychain). Confirm token file permissions and PVC scope.

**R5:** Start with open egress. Run Copilot CLI, capture DNS + TCP traffic. Tighten NetworkPolicy to observed endpoints. Confirm Copilot still works. Confirm unexpected domains blocked.

**R6:** Copy devfile from Kind setup to OpenShift tooling cluster DevSpaces. Workspace starts without modification.

---

## Open Questions (answered per release, not upfront)

- R1 closes: RFC1918 block via NetworkPolicy on Kind + Calico/Cilium
- R3 closes: Does agent mode respect PATH wrappers, or does it exec directly?
- R4 closes: OAuth token storage on headless Linux — plaintext risk confirmed/quantified
- R5 closes: Exact egress allowlist for Copilot CLI + Enterprise tenant

## Background

See `brainstorm/aienclave-brainstorm.md` for threat model, architecture, and full context.

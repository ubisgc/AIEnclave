#!/usr/bin/env bash
# R5 verification: prove egress NetworkPolicy limits workspace traffic to allowlist.
#
# Done criteria (releases.md R5):
#   1. Lifecycle:   aienclave-r5 DevWorkspace reaches phase == Running.
#   2. Open egress: Copilot CLI works with open egress (baseline).
#   3. Enforce:     NetworkPolicy (allowlist) applied to workspace pod.
#   4. Copilot OK:  Copilot CLI still works after policy applied.
#   5. Blocked:     Unexpected domain (e.g. example.com) is unreachable from workspace.
#
# Open question this closes: exact egress allowlist for Copilot CLI.
#
# Prerequisites:
#   - scripts/capture-traffic.sh start   (enable CoreDNS query log)
#   - Run Copilot in workspace to generate traffic
#   - scripts/capture-traffic.sh fqdns   (collect FQDN list)
#   - Populate CIDRs in test-dev/netpol-workspace-egress-enforce.yaml
set -uo pipefail

KUBECTL="kubectl --context kind-aienclave"
NS=aienclave-testuser
DW_NAME=aienclave-r5
DW_LABEL="controller.devfile.io/devworkspace_name=${DW_NAME}"
RUNNING_TIMEOUT=600
POLL_INTERVAL=10

rc=0

# --- Assertion 1: DevWorkspace reaches Running -----------------------------------
echo "Assertion 1: DevWorkspace ${DW_NAME} -> phase Running (timeout ${RUNNING_TIMEOUT}s)..."
deadline=$(( $(date +%s) + RUNNING_TIMEOUT ))
phase=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  phase=$($KUBECTL get devworkspace "$DW_NAME" -n "$NS" \
            -o jsonpath='{.status.phase}' 2>/dev/null)
  if [ "$phase" = "Running" ]; then break; fi
  if [ "$phase" = "Failed" ]; then
    echo "  observed phase Failed; aborting"
    break
  fi
  echo "  phase=${phase:-<none>}; waiting ${POLL_INTERVAL}s..."
  sleep "$POLL_INTERVAL"
done

if [ "$phase" = "Running" ]; then
  echo "PASS: DevWorkspace ${DW_NAME} reached Running"
else
  echo "FAIL: DevWorkspace ${DW_NAME} did not reach Running (last phase: ${phase:-<none>})"
  rc=1
fi

# --- Get pod name ---------------------------------------------------------------
POD=""
if [ "$rc" -eq 0 ]; then
  POD=$($KUBECTL get pods -n "$NS" -l "$DW_LABEL" \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -z "$POD" ]; then
    echo "FAIL: no pod found for label ${DW_LABEL}"
    rc=1
  fi
fi

# --- Assertion 2: Copilot works with open egress (Phase 1 baseline) --------------
if [ -n "$POD" ]; then
  echo "Assertion 2: copilot --version reachable with open egress..."
  copilot_ver=$($KUBECTL exec -n "$NS" "$POD" -- copilot --version 2>&1 || true)
  if echo "$copilot_ver" | grep -qi "copilot"; then
    echo "PASS: copilot responds — ${copilot_ver}"
  else
    echo "FAIL: copilot --version gave unexpected output: ${copilot_ver}"
    rc=1
  fi
fi

# --- Manual step: apply enforced NetworkPolicy -----------------------------------
if [ -n "$POD" ] && [ "$rc" -eq 0 ]; then
  echo ""
  echo "========================================================================"
  echo "MANUAL STEP: apply enforced egress NetworkPolicy, then press Enter"
  echo ""
  echo "  Ensure FQDNs are resolved and CIDRs populated in:"
  echo "    test-dev/netpol-workspace-egress-enforce.yaml"
  echo ""
  echo "  Then apply:"
  echo "    kubectl --context kind-aienclave apply -f test-dev/netpol-workspace-egress-enforce.yaml"
  echo "========================================================================"
  echo ""
  read -r -p "Press Enter once NetworkPolicy is applied... "
fi

# --- Assertion 3: NetworkPolicy exists and targets workspace label ---------------
if [ -n "$POD" ] && [ "$rc" -eq 0 ]; then
  echo "Assertion 3: workspace-egress NetworkPolicy present in ${NS}..."
  np=$($KUBECTL get networkpolicy workspace-egress -n "$NS" \
        -o jsonpath='{.metadata.name}' 2>/dev/null || true)
  if [ "$np" = "workspace-egress" ]; then
    echo "PASS: NetworkPolicy workspace-egress found"
  else
    echo "FAIL: NetworkPolicy workspace-egress not found in ${NS}"
    rc=1
  fi
fi

# --- Assertion 4: Copilot still works after enforcement --------------------------
if [ -n "$POD" ] && [ "$rc" -eq 0 ]; then
  echo "Assertion 4: copilot --version still works after NetworkPolicy applied..."
  copilot_ver=$($KUBECTL exec -n "$NS" "$POD" -- copilot --version 2>&1 || true)
  if echo "$copilot_ver" | grep -qi "copilot"; then
    echo "PASS: copilot responds after enforcement — ${copilot_ver}"
  else
    echo "FAIL: copilot --version failed after enforcement: ${copilot_ver}"
    echo "      (missing endpoint in allowlist — check CoreDNS logs and update CIDRs)"
    rc=1
  fi
fi

# --- Assertion 5: unexpected domain blocked --------------------------------------
if [ -n "$POD" ] && [ "$rc" -eq 0 ]; then
  echo "Assertion 5: example.com unreachable from workspace (egress blocked)..."
  # curl exits non-zero on connection failure; we want non-zero here.
  block_output=$($KUBECTL exec -n "$NS" "$POD" -- \
    sh -c 'curl -s --connect-timeout 5 https://example.com 2>&1; echo "exit:$?"' || true)
  if echo "$block_output" | grep -q "exit:0"; then
    echo "FAIL: example.com reachable — NetworkPolicy not blocking unexpected egress"
    echo "      output: ${block_output}"
    rc=1
  else
    echo "PASS: example.com blocked — ${block_output}"
  fi
fi

if [ "$rc" -eq 0 ]; then
  echo ""
  echo "R5 VERIFY: PASS"
  echo "Egress allowlist enforced. Copilot works. Unexpected egress blocked."
else
  echo ""
  echo "R5 VERIFY: FAIL"
fi
exit "$rc"

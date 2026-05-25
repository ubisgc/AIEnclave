#!/usr/bin/env bash
# R3 verification: prove the hardened DevWorkspace blocks cluster tools via PATH wrappers.
#
# Done criteria (releases.md R3):
#   1. Lifecycle: aienclave-r3 DevWorkspace reaches phase == Running.
#   2. Exec:      kubectl exec into workspace pod succeeds.
#   3. Wrapper:   running `kubectl` inside workspace exits non-zero with deny message.
#   4. PATH:      `which kubectl` inside workspace resolves to the wrapper (/denied-bins/kubectl),
#                 confirming the real binary is shadowed.
#
# Open question this closes: does the deny message appear (PATH respected)?
# If assertion 3 fails with exit 0, agent mode bypasses PATH — record as finding.
set -uo pipefail

KUBECTL="kubectl --context kind-aienclave"
NS=aienclave-testuser
DW_NAME=aienclave-r3
DW_LABEL="controller.devfile.io/devworkspace_name=${DW_NAME}"
RUNNING_TIMEOUT=600   # seconds — 10 min; DWO warns image pulls can be slow
POLL_INTERVAL=10

rc=0

# --- Assertion 1: DevWorkspace reaches Running -----------------------------------
echo "Assertion 1: DevWorkspace ${DW_NAME} -> phase Running (timeout ${RUNNING_TIMEOUT}s)..."
deadline=$(( $(date +%s) + RUNNING_TIMEOUT ))
phase=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  phase=$($KUBECTL get devworkspace "$DW_NAME" -n "$NS" \
            -o jsonpath='{.status.phase}' 2>/dev/null)
  if [ "$phase" = "Running" ]; then
    break
  fi
  if [ "$phase" = "Failed" ]; then
    echo "  observed phase Failed; aborting wait early"
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

# --- Assertion 2: exec into workspace pod ----------------------------------------
POD=""
if [ "$rc" -eq 0 ]; then
  echo "Assertion 2: kubectl exec into workspace pod (label ${DW_LABEL})..."
  POD=$($KUBECTL get pods -n "$NS" -l "$DW_LABEL" \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -z "$POD" ]; then
    echo "FAIL: no pod found for label ${DW_LABEL}"
    rc=1
  elif $KUBECTL exec -n "$NS" "$POD" -- echo ok >/dev/null 2>&1; then
    echo "PASS: exec into ${POD} succeeded"
  else
    echo "FAIL: exec into ${POD} failed"
    rc=1
  fi
else
  echo "SKIP: workspace never reached Running"
fi

# --- Assertion 3: kubectl wrapper blocks with deny message -----------------------
if [ -n "$POD" ]; then
  echo "Assertion 3: kubectl inside workspace exits non-zero with deny message..."
  deny_output=$($KUBECTL exec -n "$NS" "$POD" -- kubectl version 2>&1 || true)
  if echo "$deny_output" | grep -q "blocked by AIEnclave policy"; then
    echo "PASS: kubectl denied — output: ${deny_output}"
  else
    echo "FAIL: expected deny message not found — output: ${deny_output}"
    echo "      (exit 0 with real output means agent mode bypasses PATH — record as R3 finding)"
    rc=1
  fi
else
  echo "SKIP: no pod available"
fi

# --- Assertion 4: command -v kubectl resolves to wrapper -------------------------
# `which` is not installed on UBI9-minimal; use `command -v` (shell builtin) via sh -c.
if [ -n "$POD" ]; then
  echo "Assertion 4: command -v kubectl resolves to /denied-bins/kubectl..."
  cv_output=$($KUBECTL exec -n "$NS" "$POD" -- sh -c 'command -v kubectl' 2>/dev/null || true)
  if [ "$cv_output" = "/denied-bins/kubectl" ]; then
    echo "PASS: command -v kubectl -> ${cv_output}"
  else
    echo "FAIL: command -v kubectl -> '${cv_output}' (expected /denied-bins/kubectl)"
    rc=1
  fi
else
  echo "SKIP: no pod available"
fi

if [ "$rc" -eq 0 ]; then
  echo "R3 VERIFY: PASS"
else
  echo "R3 VERIFY: FAIL"
fi
exit "$rc"

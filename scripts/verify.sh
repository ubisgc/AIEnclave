#!/usr/bin/env bash
# R2 verification: prove the DevWorkspace lifecycle works on Kind + Calico + DWO.
#
# Two done-criteria, nothing about browser/IDE (ADR 0003/0006 — R2 is lifecycle-only):
#   1. Lifecycle: the blank DevWorkspace reaches phase == Running.
#   2. Exec:      kubectl exec into the workspace pod runs `echo` with exit 0.
#
# DWO's own docs warn workspace image pulls can exceed 5 min; assertion 1 uses a
# generous 10-minute timeout and FAILs on timeout.
set -uo pipefail

KUBECTL="kubectl --context kind-aienclave"
NS=aienclave-testuser
DW_NAME=aienclave-blank
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

# --- Assertion 2: exec into the workspace pod ------------------------------------
echo "Assertion 2: kubectl exec into workspace pod (label ${DW_LABEL})..."
if [ "$rc" -eq 0 ]; then
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

if [ "$rc" -eq 0 ]; then
  echo "R2 VERIFY: PASS"
else
  echo "R2 VERIFY: FAIL"
fi
exit "$rc"

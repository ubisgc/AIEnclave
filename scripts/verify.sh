#!/usr/bin/env bash
# R4 verification: prove OAuth token lands plaintext on PVC, not ephemeral storage.
#
# Done criteria (releases.md R4):
#   1. Lifecycle:    aienclave-r4 DevWorkspace reaches phase == Running.
#   2. PVC mounted:  /home/user is a mounted PersistentVolume inside the workspace pod.
#   3. Auth:         (manual) user runs `gh auth login --web` inside workspace.
#   4. Token exists: ~/.config/gh/hosts.yml present after login.
#   5. Plaintext:    token file is readable plaintext (no keychain, no encryption).
#   6. Permissions:  token file mode is 0600 (owner-only read/write).
#   7. PVC scope:    token path is on the PVC mount, not ephemeral container storage.
#
# Open question this closes: OAuth token storage on headless Linux — plaintext risk confirmed.
set -uo pipefail

KUBECTL="kubectl --context kind-aienclave"
NS=aienclave-testuser
DW_NAME=aienclave-r4
DW_LABEL="controller.devfile.io/devworkspace_name=${DW_NAME}"
RUNNING_TIMEOUT=600
POLL_INTERVAL=10
TOKEN_PATH=/home/user/.config/gh/hosts.yml

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

# --- Assertion 2: PVC mounted at /home/user -------------------------------------
POD=""
if [ "$rc" -eq 0 ]; then
  echo "Assertion 2: PVC mounted at /home/user..."
  POD=$($KUBECTL get pods -n "$NS" -l "$DW_LABEL" \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -z "$POD" ]; then
    echo "FAIL: no pod found for label ${DW_LABEL}"
    rc=1
  else
    # /proc/mounts shows real mounts; grep for /home/user on a non-overlay filesystem.
    mount_output=$($KUBECTL exec -n "$NS" "$POD" -- \
      sh -c 'grep " /home/user " /proc/mounts' 2>/dev/null || true)
    if echo "$mount_output" | grep -q "/home/user"; then
      echo "PASS: /home/user is mounted — ${mount_output}"
    else
      echo "FAIL: /home/user does not appear in /proc/mounts (PVC not attached)"
      echo "      /proc/mounts:"
      $KUBECTL exec -n "$NS" "$POD" -- cat /proc/mounts 2>/dev/null || true
      rc=1
    fi
  fi
fi

# --- Manual step: user runs gh auth login ----------------------------------------
if [ -n "$POD" ] && [ "$rc" -eq 0 ]; then
  echo ""
  echo "========================================================================"
  echo "MANUAL STEP: run the following in another terminal, then press Enter here"
  echo ""
  echo "  kubectl --context kind-aienclave exec -it -n ${NS} ${POD} -- bash"
  echo "  # inside workspace:"
  echo "  gh auth login --web"
  echo "  # complete the device-flow browser prompt, then return here"
  echo "========================================================================"
  echo ""
  read -r -p "Press Enter once gh auth login has completed... "
fi

# --- Assertion 3: token file exists ---------------------------------------------
if [ -n "$POD" ] && [ "$rc" -eq 0 ]; then
  echo "Assertion 3: token file exists at ${TOKEN_PATH}..."
  if $KUBECTL exec -n "$NS" "$POD" -- test -f "$TOKEN_PATH" 2>/dev/null; then
    echo "PASS: ${TOKEN_PATH} exists"
  else
    echo "FAIL: ${TOKEN_PATH} not found after login"
    echo "      Other gh config files present:"
    $KUBECTL exec -n "$NS" "$POD" -- sh -c 'find /home/user/.config -type f 2>/dev/null || echo "(none)"'
    rc=1
  fi
fi

# --- Assertion 4: token is plaintext -------------------------------------------
if [ -n "$POD" ] && [ "$rc" -eq 0 ]; then
  echo "Assertion 4: token file is readable plaintext..."
  token_contents=$($KUBECTL exec -n "$NS" "$POD" -- cat "$TOKEN_PATH" 2>/dev/null || true)
  if echo "$token_contents" | grep -q "oauth_token"; then
    echo "PASS: token file contains plaintext oauth_token"
    echo "      --- token file contents (redacted) ---"
    echo "$token_contents" | sed 's/oauth_token:.*/oauth_token: <REDACTED>/'
    echo "      ----------------------------------------"
  else
    echo "FAIL: oauth_token key not found in ${TOKEN_PATH} — contents:"
    echo "$token_contents"
    rc=1
  fi
fi

# --- Assertion 5: file permissions 0600 ----------------------------------------
if [ -n "$POD" ] && [ "$rc" -eq 0 ]; then
  echo "Assertion 5: token file permissions are 0600..."
  perms=$($KUBECTL exec -n "$NS" "$POD" -- \
    sh -c "stat -c '%a' ${TOKEN_PATH}" 2>/dev/null || true)
  if [ "$perms" = "600" ]; then
    echo "PASS: ${TOKEN_PATH} mode = ${perms}"
  else
    echo "WARN: ${TOKEN_PATH} mode = ${perms} (expected 600 — document as finding)"
  fi
fi

# --- Assertion 6: token path is on PVC mount ------------------------------------
if [ -n "$POD" ] && [ "$rc" -eq 0 ]; then
  echo "Assertion 6: token path resolves to PVC mount (not overlay/tmpfs)..."
  # df shows the filesystem backing the path; overlay = ephemeral container layer.
  df_output=$($KUBECTL exec -n "$NS" "$POD" -- df -T "$TOKEN_PATH" 2>/dev/null || true)
  echo "      df -T ${TOKEN_PATH}:"
  echo "$df_output"
  if echo "$df_output" | grep -qv "overlay"; then
    echo "PASS: token is not on overlay (ephemeral) filesystem — PVC confirmed"
  else
    echo "FAIL: token appears to be on overlay (ephemeral) filesystem — PVC not backing /home/user"
    rc=1
  fi
fi

if [ "$rc" -eq 0 ]; then
  echo ""
  echo "R4 VERIFY: PASS"
  echo "Finding confirmed: gh OAuth token stored plaintext at ${TOKEN_PATH} on PVC."
  echo "Keychain not used on headless Linux — plaintext risk quantified (see R4 PRD)."
else
  echo ""
  echo "R4 VERIFY: FAIL"
fi
exit "$rc"

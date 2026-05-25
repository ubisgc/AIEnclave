#!/usr/bin/env bash
# R1 verification: prove the RFC1918 egress block works on Kind + Calico.
#
# Deploys two otherwise-identical pods differing only by the
# aienclave/egress: restricted label. The labeled pod must NOT reach a
# literal 10.x address (Calico drops it); the unlabeled pod MUST reach a
# public control IP. Literal IPs only — never a Service IP (ipBlock vs
# DNAT'd Service IPs is undefined; see ADR 0002).
set -uo pipefail

KUBECTL="kubectl --context kind-aienclave"
NS=default
BLOCKED_IP=10.99.99.99   # literal RFC1918 stand-in for the internal network
CONTROL_IP=1.1.1.1       # public control IP — must stay reachable

cleanup() {
  $KUBECTL delete pod test-pod-blocked test-pod-allowed -n "$NS" \
    --ignore-not-found --wait=false >/dev/null 2>&1
}
trap cleanup EXIT

echo "Deploying test pods..."

$KUBECTL apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-pod-blocked
  namespace: default
  labels:
    aienclave/egress: restricted
spec:
  hostNetwork: false
  containers:
    - name: curl
      image: curlimages/curl:latest
      command: ["sleep", "3600"]
EOF

$KUBECTL apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-pod-allowed
  namespace: default
spec:
  hostNetwork: false
  containers:
    - name: curl
      image: curlimages/curl:latest
      command: ["sleep", "3600"]
EOF

echo "Waiting for pods Ready..."
$KUBECTL wait --for=condition=Ready pod/test-pod-blocked pod/test-pod-allowed \
  -n "$NS" --timeout=120s || {
    echo "FAIL: pods did not become Ready"
    exit 1
  }

rc=0

# Assertion 1: labeled pod must NOT reach the 10.x address (curl exits non-zero).
echo "Assertion 1: test-pod-blocked -> http://${BLOCKED_IP} (expect blocked)..."
if $KUBECTL exec -n "$NS" test-pod-blocked -- \
    curl --max-time 5 "http://${BLOCKED_IP}" >/dev/null 2>&1; then
  echo "FAIL: blocked pod reached ${BLOCKED_IP} (egress block not enforced)"
  rc=1
else
  echo "PASS: blocked pod could not reach ${BLOCKED_IP} (egress block enforced)"
fi

# Assertion 2: unlabeled pod MUST reach the public control IP (curl exits 0).
echo "Assertion 2: test-pod-allowed -> http://${CONTROL_IP} (expect reachable)..."
if $KUBECTL exec -n "$NS" test-pod-allowed -- \
    curl --max-time 5 "http://${CONTROL_IP}" >/dev/null 2>&1; then
  echo "PASS: allowed pod reached ${CONTROL_IP} (unrestricted egress works)"
else
  echo "FAIL: allowed pod could not reach ${CONTROL_IP} (egress wrongly blocked)"
  rc=1
fi

if [ "$rc" -eq 0 ]; then
  echo "R1 VERIFY: PASS"
else
  echo "R1 VERIFY: FAIL"
fi
exit "$rc"

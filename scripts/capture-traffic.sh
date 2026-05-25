#!/usr/bin/env bash
# R5 Phase 1: enable CoreDNS query logging, stream DNS queries from workspace pod,
# and print the FQDN list for use in netpol-workspace-egress-enforce.yaml.
#
# Usage:
#   scripts/capture-traffic.sh start   — enable CoreDNS logging + print pod IP
#   scripts/capture-traffic.sh watch   — stream DNS queries from workspace pod (live)
#   scripts/capture-traffic.sh stop    — disable CoreDNS logging
#   scripts/capture-traffic.sh fqdns   — extract unique FQDNs from CoreDNS logs
#
# On the real OpenShift cluster this step is replaced by RHACS network flow monitoring,
# which records all egress connections per-pod in real time without manual setup.
set -uo pipefail

KUBECTL="kubectl --context kind-aienclave"
NS=aienclave-testuser
DW_LABEL="controller.devfile.io/devworkspace_name=aienclave-r5"

cmd="${1:-help}"

pod_ip() {
  $KUBECTL get pods -n "$NS" -l "$DW_LABEL" \
    -o jsonpath='{.items[0].status.podIP}' 2>/dev/null
}

case "$cmd" in
  start)
    echo "Enabling CoreDNS query log plugin..."
    # Patch CoreDNS ConfigMap to add 'log' directive — logs every query to stdout.
    $KUBECTL -n kube-system get configmap coredns -o yaml \
      | sed 's/        errors/        log\n        errors/' \
      | $KUBECTL apply -f -
    # Restart CoreDNS to pick up ConfigMap change.
    $KUBECTL -n kube-system rollout restart deployment/coredns
    $KUBECTL -n kube-system rollout status deployment/coredns --timeout=60s

    IP=$(pod_ip)
    echo ""
    echo "CoreDNS query logging enabled."
    echo "Workspace pod IP: ${IP:-<not found — is workspace running?>}"
    echo ""
    echo "Next steps:"
    echo "  1. Run Copilot in workspace:  kubectl --context kind-aienclave exec -it -n ${NS} \$(kubectl --context kind-aienclave get pods -n ${NS} -l '${DW_LABEL}' -o jsonpath='{.items[0].metadata.name}') -- bash"
    echo "  2. Stream DNS live:           scripts/capture-traffic.sh watch"
    echo "  3. Run: copilot explain 'hello'  (or any copilot command)"
    echo "  4. When done:                 scripts/capture-traffic.sh fqdns"
    ;;

  watch)
    IP=$(pod_ip)
    if [ -z "$IP" ]; then
      echo "ERROR: workspace pod not found or not Running"
      exit 1
    fi
    echo "Streaming CoreDNS queries from pod IP ${IP} (Ctrl-C to stop)..."
    $KUBECTL -n kube-system logs -f -l k8s-app=kube-dns --prefix \
      | grep "$IP"
    ;;

  stop)
    echo "Disabling CoreDNS query log plugin..."
    $KUBECTL -n kube-system get configmap coredns -o yaml \
      | sed '/^        log$/d' \
      | $KUBECTL apply -f -
    $KUBECTL -n kube-system rollout restart deployment/coredns
    $KUBECTL -n kube-system rollout status deployment/coredns --timeout=60s
    echo "CoreDNS query logging disabled."
    ;;

  fqdns)
    IP=$(pod_ip)
    if [ -z "$IP" ]; then
      echo "ERROR: workspace pod not found"
      exit 1
    fi
    echo "Unique FQDNs queried by workspace pod ${IP}:"
    echo "(from CoreDNS pod logs — reflects all DNS since logging was enabled)"
    echo ""
    $KUBECTL -n kube-system logs -l k8s-app=kube-dns --tail=-1 2>/dev/null \
      | grep "$IP" \
      | grep -oP '(?<=\] )[^ ]+(?= \w+ IN)' \
      | sed 's/\.$//' \
      | sort -u
    echo ""
    echo "Resolve each FQDN to CIDR and add to test-dev/netpol-workspace-egress-enforce.yaml."
    echo "Example: dig +short <fqdn> | sort -u"
    ;;

  *)
    echo "Usage: $0 {start|watch|stop|fqdns}"
    exit 1
    ;;
esac

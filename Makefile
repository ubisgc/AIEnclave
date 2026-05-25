CLUSTER := aienclave
KUBECTL  := kubectl --context kind-$(CLUSTER)
CALICO_URL := https://raw.githubusercontent.com/projectcalico/calico/v3.32.0/manifests/calico.yaml

.PHONY: up down verify

up:
	@command -v kind kubectl docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || \
		{ echo "preflight failed: need kind, kubectl, docker on PATH and a running Docker daemon"; exit 1; }
	@kind get clusters 2>/dev/null | grep -qx "$(CLUSTER)" && \
		{ echo "cluster $(CLUSTER) already exists; run 'make down' first"; exit 1; } || true
	kind create cluster --name $(CLUSTER) --config kind/kind-config.yaml
	$(KUBECTL) apply -f $(CALICO_URL)
	$(KUBECTL) rollout status daemonset/calico-node -n kube-system --timeout=120s
	$(KUBECTL) apply -f test-dev/netpol-block-rfc1918.yaml

down:
	kind delete cluster --name $(CLUSTER)

verify:
	scripts/verify.sh

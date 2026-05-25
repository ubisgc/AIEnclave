CLUSTER    := aienclave
KUBECTL    := kubectl --context kind-$(CLUSTER)
IMAGE_NAME := aienclave-workspace
IMAGE_TAG  := r3
REGISTRY   := kind-registry
# REG_PORT: host-side port for the local registry; cluster-side is always 5000.
REG_PORT   := 5001

# Pinned upstream manifests — applied from URL, never vendored (ADR 0001 style).
CALICO_URL  := https://raw.githubusercontent.com/projectcalico/calico/v3.32.0/manifests/calico.yaml
INGRESS_URL := https://kind.sigs.k8s.io/examples/ingress/deploy-ingress-nginx.yaml
CERTMGR_URL := https://github.com/cert-manager/cert-manager/releases/download/v1.15.3/cert-manager.yaml
DWO_URL     := https://raw.githubusercontent.com/devfile/devworkspace-operator/v0.41.0/deploy/deployment/kubernetes/combined.yaml

DWO_NS := devworkspace-controller

.PHONY: up down verify image

image:
	docker build -t $(IMAGE_NAME):$(IMAGE_TAG) images/workspace/
	docker tag $(IMAGE_NAME):$(IMAGE_TAG) localhost:$(REG_PORT)/$(IMAGE_NAME):$(IMAGE_TAG)
	docker push localhost:$(REG_PORT)/$(IMAGE_NAME):$(IMAGE_TAG)

up:
	@command -v kind kubectl docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || \
		{ echo "preflight failed: need kind, kubectl, docker on PATH and a running Docker daemon"; exit 1; }
	@kind get clusters 2>/dev/null | grep -qx "$(CLUSTER)" && \
		{ echo "cluster $(CLUSTER) already exists; run 'make down' first"; exit 1; } || true
	# 0. Local registry — DWO sets imagePullPolicy:Always so images must be in a registry
	#    reachable from the cluster. Registry container joins the "kind" Docker network so
	#    Kind nodes resolve it by name as kind-registry:5000.
	@docker inspect $(REGISTRY) >/dev/null 2>&1 || \
		docker run -d --restart=always -p 127.0.0.1:$(REG_PORT):5000 \
			--name $(REGISTRY) registry:2
	# Build and push before cluster exists so the push target is ready when DWO pulls.
	docker build -t $(IMAGE_NAME):$(IMAGE_TAG) images/workspace/
	docker tag $(IMAGE_NAME):$(IMAGE_TAG) localhost:$(REG_PORT)/$(IMAGE_NAME):$(IMAGE_TAG)
	docker push localhost:$(REG_PORT)/$(IMAGE_NAME):$(IMAGE_TAG)
	kind create cluster --name $(CLUSTER) --config kind/kind-config.yaml
	# Connect registry to the kind network so nodes can reach kind-registry:5000.
	@docker network connect kind $(REGISTRY) 2>/dev/null || true
	# 1. CNI — Calico (ADR 0001); enforces NetworkPolicy, keeps pod IPs out of 10.0.0.0/8.
	$(KUBECTL) apply -f $(CALICO_URL)
	$(KUBECTL) rollout status daemonset/calico-node -n kube-system --timeout=120s
	# 2. Ingress controller — ingress-nginx kind manifest (ADR 0005); hostPort 80/443.
	$(KUBECTL) apply -f $(INGRESS_URL)
	$(KUBECTL) wait --namespace ingress-nginx \
		--for=condition=Ready pod \
		--selector=app.kubernetes.io/component=controller \
		--timeout=180s
	# 3. cert-manager (ADR 0004) — provides DWO webhook serving cert on Kind.
	$(KUBECTL) apply -f $(CERTMGR_URL)
	$(KUBECTL) rollout status deployment/cert-manager            -n cert-manager --timeout=180s
	$(KUBECTL) rollout status deployment/cert-manager-cainjector -n cert-manager --timeout=180s
	$(KUBECTL) rollout status deployment/cert-manager-webhook    -n cert-manager --timeout=180s
	# 4. DevWorkspace Operator (ADR 0006) — combined.yaml does NOT create its own
	#    namespace, so create it before apply.
	$(KUBECTL) create namespace $(DWO_NS) --dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(KUBECTL) apply -f $(DWO_URL)
	$(KUBECTL) rollout status deployment/devworkspace-controller-manager -n $(DWO_NS) --timeout=180s
	# Wait for DWO webhook TLS cert to be issued before applying any DevWorkspace; without
	# this the mutating webhook is registered but the serving cert isn't trusted yet,
	# causing "connection refused" on the first DevWorkspace apply.
	$(KUBECTL) wait certificate/devworkspace-controller-serving-cert \
		-n $(DWO_NS) --for=condition=Ready --timeout=60s
	# 5. Operator config — sets the workspace URL host suffix (ADR 0003).
	$(KUBECTL) apply -f test-dev/devworkspaceoperatorconfig.yaml
	# 6. R3 hardened workspace — DevWorkspace (ADR 0007).
	#    Deny wrappers baked into image; DWO blocks pod-overrides on spec.containers.
	$(KUBECTL) create namespace aienclave-testuser --dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(KUBECTL) apply -f test-dev/devworkspace-r3.yaml

down:
	kind delete cluster --name $(CLUSTER)
	@docker network disconnect kind $(REGISTRY) 2>/dev/null || true
	@docker stop $(REGISTRY) 2>/dev/null || true
	@docker rm $(REGISTRY) 2>/dev/null || true

verify:
	scripts/verify.sh

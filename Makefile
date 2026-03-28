MINIKUBE = /usr/bin/env minikube
KUSTOMIZE = /usr/bin/env kustomize
KUBECTL = /usr/bin/env kubectl
HELM = /usr/bin/env helm
IMAGE_REPO = mymagento/magento2
IMAGE_TAG ?= $(shell git rev-parse --short HEAD)$(shell git diff --quiet HEAD 2>/dev/null || echo '-dirty')

# --------------------------------------------------------------------------- #
# Pre-flight checks
# --------------------------------------------------------------------------- #

check-tools:
	@command -v minikube >/dev/null 2>&1 || { echo "Error: minikube is not installed"; exit 1; }
	@command -v kubectl >/dev/null 2>&1  || { echo "Error: kubectl is not installed"; exit 1; }
	@command -v kustomize >/dev/null 2>&1 || { echo "Error: kustomize is not installed"; exit 1; }
	@command -v helm >/dev/null 2>&1     || { echo "Error: helm is not installed"; exit 1; }
	@command -v docker >/dev/null 2>&1   || { echo "Error: docker is not installed"; exit 1; }

check-composer-auth:
	@if [ -z "$$COMPOSER_AUTH" ]; then \
		echo "Error: COMPOSER_AUTH is not set."; \
		echo "Run: export COMPOSER_AUTH='{\"http-basic\":{\"repo.magento.com\":{\"username\":\"...\",\"password\":\"...\"}}}'" ; \
		exit 1; \
	fi

# --------------------------------------------------------------------------- #
# Cluster
# --------------------------------------------------------------------------- #

minikube: check-tools
	$(MINIKUBE) start \
	--kubernetes-version=v1.24.0 \
	--vm-driver=docker \
	--cpus=4 \
	--memory=16g \
	--bootstrapper=kubeadm \
	--extra-config=kubelet.authentication-token-webhook=true \
	--extra-config=kubelet.authorization-mode=Webhook \
	--extra-config=scheduler.bind-address=0.0.0.0 \
	--extra-config=controller-manager.bind-address=0.0.0.0 --force
	minikube addons enable ingress
	minikube addons enable default-storageclass
	minikube addons enable storage-provisioner
	minikube addons enable metrics-server

cluster-dependencies: check-tools
	$(HELM) repo add mittwald https://helm.mittwald.de
	$(HELM) repo add cert-manager https://charts.jetstack.io
	$(HELM) repo update
	$(HELM) upgrade --install cert-manager cert-manager/cert-manager \
	--version v1.12.13 \
	--set installCRDs=true \
	--set ingressShim.defaultIssuerKind=ClusterIssuer \
	--set ingressShim.defaultIssuerName=selfsigned
	$(HELM) upgrade --install ingress-nginx oci://ghcr.io/nginxinc/charts/nginx-ingress \
  --set controller.kind=daemonset \
  --set controller.enableSnippets=true \
  --set controller.service.enabled=true \
  --set controller.service.type=ClusterIP \
  --set controller.service.clusterIP=10.96.0.2 \
  --set controller.service.httpPort.port=80 \
  --set controller.service.httpsPort.port=443 \
  --set controller.ingressClass.create=true \
  --set controller.ingressClass.name=nginx \
  --set controller.ingressClass.setAsDefaultIngress=true
	$(HELM) upgrade --install secret-gsenerator mittwald/kubernetes-secret-generator

# --------------------------------------------------------------------------- #
# Build
# --------------------------------------------------------------------------- #

build: check-tools check-composer-auth
	cd src && IMAGE_NAME="$(IMAGE_REPO):$(IMAGE_TAG)" DOCKERFILE_PATH=Dockerfile ./hooks/build

# --------------------------------------------------------------------------- #
# Walkthrough steps
# --------------------------------------------------------------------------- #

# Helper: set image tag in a kustomization dir, build & apply, then restore the file
# so the hardcoded tag never stays in version control.
define kustomize_apply
	cd $(1) && $(KUSTOMIZE) edit set image $(IMAGE_REPO)=$(IMAGE_REPO):$(IMAGE_TAG)
	$(KUSTOMIZE) build $(1) | $(KUBECTL) apply -f -
	git checkout $(1)/kustomization.yaml
endef

step-1: cluster-dependencies
	$(call kustomize_apply,deploy/walkthrough/step-1)

step-2: cluster-dependencies
	$(call kustomize_apply,deploy/walkthrough/step-2)

step-3: cluster-dependencies
	$(call kustomize_apply,deploy/walkthrough/step-3)

step-3-deploy: build
	@$(KUBECTL) get ingressclass nginx >/dev/null 2>&1 && \
		echo "Deleting existing IngressClass 'nginx' to avoid Helm conflict..." && \
		$(KUBECTL) delete ingressclass nginx || true
	$(MAKE) step-3

# --------------------------------------------------------------------------- #
# Deploy (production-style)
# --------------------------------------------------------------------------- #

deploy: check-composer-auth
	KUSTOMIZE="$(KUSTOMIZE)" KUBECTL="$(KUBECTL)" IMAGE_REPO="$(IMAGE_REPO)" IMAGE_TAG="$(IMAGE_TAG)" ./deploy/deploy.sh

deploy-zero:
	KUSTOMIZE="$(KUSTOMIZE)" KUBECTL="$(KUBECTL)" IMAGE_REPO="$(IMAGE_REPO)" IMAGE_TAG="$(IMAGE_TAG)" ./deploy/deploy.sh --zero-downtime

deploy-maintenance:
	KUSTOMIZE="$(KUSTOMIZE)" KUBECTL="$(KUBECTL)" IMAGE_REPO="$(IMAGE_REPO)" IMAGE_TAG="$(IMAGE_TAG)" ./deploy/deploy.sh --maintenance

deploy-only:
	KUSTOMIZE="$(KUSTOMIZE)" KUBECTL="$(KUBECTL)" IMAGE_REPO="$(IMAGE_REPO)" IMAGE_TAG="$(IMAGE_TAG)" ./deploy/deploy.sh --skip-build

# --------------------------------------------------------------------------- #
# Teardown
# --------------------------------------------------------------------------- #

destroy:
	$(KUBECTL) delete -k deploy/step-3
	$(KUBECTL) delete pvc data-db-0
	$(KUBECTL) delete pvc data-elasticsearch-0

.PHONY: check-tools check-composer-auth minikube cluster-dependencies build step-1 step-2 step-3 step-3-deploy deploy deploy-zero deploy-maintenance deploy-only destroy

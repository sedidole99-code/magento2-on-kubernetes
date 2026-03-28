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
# Monitoring
# --------------------------------------------------------------------------- #

monitoring: check-tools
	$(HELM) repo add prometheus-community https://prometheus-community.github.io/helm-charts
	$(HELM) repo update
	$(HELM) upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
	  --version 72.9.1 \
	  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
	  --set prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues=false \
	  --set grafana.sidecar.dashboards.enabled=true \
	  --set grafana.sidecar.dashboards.label=grafana_dashboard \
	  --set grafana.sidecar.dashboards.searchNamespace=ALL \
	  --set grafana.service.type=ClusterIP \
	  --set grafana.adminPassword=admin
	$(KUSTOMIZE) build deploy/bases/monitoring | $(KUBECTL) apply -f -
	@echo ""
	@echo "Monitoring stack installed (Prometheus + Grafana)."
	@echo "  Grafana:    kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80"
	@echo "  Prometheus: kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090"
	@echo "  Grafana credentials: admin / admin"
	@echo ""
	@echo "For log aggregation, choose one of:"
	@echo "  make logging-loki   — Loki + Promtail (logs in Grafana Explore)"
	@echo "  make monitoring-kibana    — Elasticsearch + Fluentbit + Kibana"

logging-loki: check-tools
	$(HELM) repo add grafana https://grafana.github.io/helm-charts
	$(HELM) repo update
	$(HELM) upgrade --install loki grafana/loki-stack \
	  --set loki.persistence.enabled=false \
	  --set promtail.enabled=true \
	  --set grafana.enabled=false \
	  --set loki.isDefault=false
	@echo ""
	@echo "Loki logging stack installed."
	@echo "To add Loki as a datasource in Grafana, run:"
	@echo "  make monitoring-loki-datasource"

monitoring-loki-datasource: check-tools
	$(HELM) upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
	  --version 72.9.1 \
	  --reuse-values \
	  --set grafana.additionalDataSources[0].name=Loki \
	  --set grafana.additionalDataSources[0].type=loki \
	  --set grafana.additionalDataSources[0].url=http://loki:3100 \
	  --set grafana.additionalDataSources[0].access=proxy \
	  --set grafana.additionalDataSources[0].isDefault=false
	@kubectl delete pod -l app.kubernetes.io/name=grafana 2>/dev/null || true
	@echo ""
	@echo "Loki datasource added to Grafana. Pod restarted."
	@echo "  Query logs in Grafana Explore with: {namespace=\"default\"}"

monitoring-kibana: check-tools
	$(HELM) repo add elastic https://helm.elastic.co
	$(HELM) repo add fluent https://fluent.github.io/helm-charts
	$(HELM) repo update
	$(HELM) upgrade --install elasticsearch elastic/elasticsearch \
	  -f deploy/bases/monitoring/elasticsearch-values.yaml
	@echo "Waiting for Elasticsearch to be ready..."
	$(KUBECTL) rollout status statefulset/elasticsearch-master --timeout=300s
	$(HELM) upgrade --install fluent-bit fluent/fluent-bit \
	  -f deploy/bases/monitoring/fluent-bit-values.yaml
	$(HELM) upgrade --install kibana elastic/kibana \
	  -f deploy/bases/monitoring/kibana-values.yaml
	@echo ""
	@echo "EFK logging stack installed."
	@echo "  Kibana:          kubectl port-forward svc/kibana-kibana 5601:5601"
	@echo "  Kibana credentials: elastic / <password from secret>"
	@echo "  Get password:    kubectl get secret elasticsearch-master-credentials -o jsonpath='{.data.password}' | base64 -d; echo"

# --------------------------------------------------------------------------- #
# Build
# --------------------------------------------------------------------------- #

build: check-tools check-composer-auth
	eval $$($(MINIKUBE) docker-env 2>/dev/null || true) && \
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
# Services overview
# --------------------------------------------------------------------------- #

services:
	KUBECTL="$(KUBECTL)" HELM="$(HELM)" MINIKUBE="$(MINIKUBE)" ./deploy/bases/services/services.sh html services.html
	@(xdg-open services.html >/dev/null 2>&1 || open services.html >/dev/null 2>&1 || echo "Open services.html in your browser") &

SERVICES_PERSISTENT ?= false

services-server:
	$(KUSTOMIZE) build deploy/bases/services | $(KUBECTL) apply -f -
	@$(KUBECTL) rollout status deployment/services-dashboard --timeout=120s
	@echo ""
	@echo "Services dashboard: http://localhost:8080"
	@printf "  Username: " && $(KUBECTL) get secret services-dashboard-credentials -o jsonpath='{.data.username}' | base64 -d && echo ""
	@printf "  Password: " && $(KUBECTL) get secret services-dashboard-credentials -o jsonpath='{.data.password}' | base64 -d && echo ""
	@echo ""
ifeq ($(SERVICES_PERSISTENT),true)
	@echo "Dashboard pod will keep running after port-forward stops."
	@echo "To remove later: kubectl delete -k deploy/bases/services"
else
	@echo "Dashboard pod will be removed when port-forward stops."
endif
	@echo "Press Ctrl+C to stop"
	$(KUBECTL) port-forward svc/services-dashboard 8080:8080; \
	if [ "$(SERVICES_PERSISTENT)" != "true" ]; then \
		echo "Cleaning up dashboard pod..."; \
		$(KUBECTL) delete -k deploy/bases/services --ignore-not-found; \
	fi

# --------------------------------------------------------------------------- #
# Teardown
# --------------------------------------------------------------------------- #

destroy:
	$(KUBECTL) delete -k deploy/walkthrough/step-3 --ignore-not-found
	$(KUBECTL) delete pvc data-db-0
	$(KUBECTL) delete pvc data-elasticsearch-0

.PHONY: check-tools check-composer-auth minikube cluster-dependencies monitoring logging-loki monitoring-loki-datasource monitoring-kibana build step-1 step-2 step-3 step-3-deploy deploy deploy-zero deploy-maintenance deploy-only destroy services services-server

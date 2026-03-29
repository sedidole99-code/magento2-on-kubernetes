MINIKUBE = /usr/bin/env minikube
KUSTOMIZE = /usr/bin/env kustomize
KUBECTL = /usr/bin/env kubectl
HELM = /usr/bin/env helm
IMAGE_REPO = mymagento/magento2
IMAGE_TAG ?= $(shell git rev-parse --short HEAD)$(shell git diff --quiet HEAD 2>/dev/null || echo '-dirty')

# --------------------------------------------------------------------------- #
# Environment support
# Usage: make <target> <env>  e.g. make deploy production, make destroy staging
# Shortcuts: dev/default, stag/staging, prod/production
# --------------------------------------------------------------------------- #

# Resolve environment from second goal word (make deploy prod → ENV=production)
ENVS = default dev develop stage staging production prod
ENV_WORD := $(strip $(filter $(ENVS),$(MAKECMDGOALS)))

# Normalize shortcuts
ifeq ($(ENV_WORD),dev)
  override ENV_WORD = default
else ifeq ($(ENV_WORD),develop)
  override ENV_WORD = default
else ifeq ($(ENV_WORD),stage)
  override ENV_WORD = staging
else ifeq ($(ENV_WORD),stag)
  override ENV_WORD = staging
else ifeq ($(ENV_WORD),prod)
  override ENV_WORD = production
endif

# Allow ENV= override for backward compat; ENV_WORD takes precedence
ENV ?= $(ENV_WORD)

# Resolve namespace and kustomize path
ifeq ($(ENV),staging)
  NAMESPACE = staging
  ENV_KUSTOMIZE_PATH = deploy/overlays/staging
else ifeq ($(ENV),production)
  NAMESPACE = production
  ENV_KUSTOMIZE_PATH = deploy/overlays/production
else ifeq ($(ENV),default)
  NAMESPACE = default
  ENV_KUSTOMIZE_PATH =
else ifneq ($(ENV),)
  $(error Unknown environment "$(ENV)". Use: default/dev, staging/stag, production/prod)
endif

ifneq ($(NAMESPACE),default)
  NS_FLAG = -n $(NAMESPACE)
else
  NS_FLAG =
endif

# Swallow environment words so make doesn't treat them as targets
$(filter $(ENVS),$(MAKECMDGOALS)):
	@true

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
	$(MINIKUBE) ssh -- sudo sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512
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
	@$(KUBECTL) get ingressclass nginx >/dev/null 2>&1 && \
		! $(KUBECTL) get ingressclass nginx -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null | grep -q Helm && \
		echo "Deleting non-Helm IngressClass 'nginx'..." && \
		$(KUBECTL) delete ingressclass nginx || true
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

check-env:
ifeq ($(ENV),)
	$(error Environment required. Usage: make <target> <env>  (dev, staging, prod))
endif

ensure-namespace:
ifneq ($(NAMESPACE),default)
	@$(KUBECTL) get namespace $(NAMESPACE) >/dev/null 2>&1 || $(KUBECTL) create namespace $(NAMESPACE)
endif

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
	cp $(1)/kustomization.yaml $(1)/kustomization.yaml.bak
	cd $(1) && $(KUSTOMIZE) edit set image $(IMAGE_REPO)=$(IMAGE_REPO):$(IMAGE_TAG)
	$(KUSTOMIZE) build $(CURDIR)/$(1) | $(KUBECTL) apply $(NS_FLAG) -f -
	mv $(1)/kustomization.yaml.bak $(1)/kustomization.yaml
endef

# Helper: wait for install job, follow logs, wait for rollout
define wait_for_install
	@echo ""
	@echo "Waiting for Magento install job to start (this may take a few minutes)..."
	@while true; do \
		RUNNING=$$($(KUBECTL) get pod $(NS_FLAG) -l job-name=magento-install -o jsonpath='{.items[0].status.containerStatuses[0].state.running}' 2>/dev/null); \
		COMPLETED=$$($(KUBECTL) get pod $(NS_FLAG) -l job-name=magento-install -o jsonpath='{.items[0].status.containerStatuses[0].state.terminated}' 2>/dev/null); \
		if [ -n "$$RUNNING" ] || [ -n "$$COMPLETED" ]; then break; fi; \
		printf "."; sleep 5; \
	done
	@echo ""
	@echo "Install job running. Following logs:"
	@echo "--------------------------------------"
	$(KUBECTL) logs $(NS_FLAG) -f job/magento-install -c magento-setup || true
	@echo "--------------------------------------"
	@echo ""
	@echo "Waiting for deployment rollout..."
	@$(KUBECTL) rollout status $(NS_FLAG) deployment/magento-web --timeout=600s
	@echo ""
	@echo "Magento is ready! Run 'minikube tunnel' to access the site."
endef

step-1: cluster-dependencies check-env ensure-namespace
ifeq ($(ENV_KUSTOMIZE_PATH),)
	$(call kustomize_apply,deploy/walkthrough/step-1)
else
	$(call kustomize_apply,$(ENV_KUSTOMIZE_PATH)/step-1)
endif

step-1-deploy: check-env build
	$(MAKE) step-1 ENV=$(ENV)
	$(call wait_for_install)

step-2: cluster-dependencies check-env ensure-namespace
ifeq ($(ENV_KUSTOMIZE_PATH),)
	$(call kustomize_apply,deploy/walkthrough/step-2)
else
	$(call kustomize_apply,$(ENV_KUSTOMIZE_PATH)/step-2)
endif

step-2-deploy: check-env build
	$(MAKE) step-2 ENV=$(ENV)
	$(call wait_for_install)

step-3: cluster-dependencies check-env ensure-namespace
ifeq ($(ENV_KUSTOMIZE_PATH),)
	$(call kustomize_apply,deploy/walkthrough/step-3)
else
	$(call kustomize_apply,$(ENV_KUSTOMIZE_PATH)/step-3)
endif

step-3-deploy: check-env build
	$(MAKE) step-3 ENV=$(ENV)
	$(call wait_for_install)

step-4: cluster-dependencies check-env ensure-namespace
ifeq ($(ENV_KUSTOMIZE_PATH),)
	$(call kustomize_apply,deploy/walkthrough/step-4)
else
	$(call kustomize_apply,$(ENV_KUSTOMIZE_PATH))
endif

step-4-deploy: check-env build
	$(MAKE) step-4 ENV=$(ENV)
	$(call wait_for_install)

# --------------------------------------------------------------------------- #
# Deploy (production-style)
# --------------------------------------------------------------------------- #

deploy: check-env check-composer-auth ensure-namespace
	KUSTOMIZE="$(KUSTOMIZE)" KUBECTL="$(KUBECTL)" IMAGE_REPO="$(IMAGE_REPO)" IMAGE_TAG="$(IMAGE_TAG)" ENV="$(ENV)" NAMESPACE="$(NAMESPACE)" NS_FLAG="$(NS_FLAG)" ENV_KUSTOMIZE_PATH="$(ENV_KUSTOMIZE_PATH)" ./deploy/deploy.sh

deploy-zero: check-env ensure-namespace
	KUSTOMIZE="$(KUSTOMIZE)" KUBECTL="$(KUBECTL)" IMAGE_REPO="$(IMAGE_REPO)" IMAGE_TAG="$(IMAGE_TAG)" ENV="$(ENV)" NAMESPACE="$(NAMESPACE)" NS_FLAG="$(NS_FLAG)" ENV_KUSTOMIZE_PATH="$(ENV_KUSTOMIZE_PATH)" ./deploy/deploy.sh --zero-downtime

deploy-maintenance: check-env ensure-namespace
	KUSTOMIZE="$(KUSTOMIZE)" KUBECTL="$(KUBECTL)" IMAGE_REPO="$(IMAGE_REPO)" IMAGE_TAG="$(IMAGE_TAG)" ENV="$(ENV)" NAMESPACE="$(NAMESPACE)" NS_FLAG="$(NS_FLAG)" ENV_KUSTOMIZE_PATH="$(ENV_KUSTOMIZE_PATH)" ./deploy/deploy.sh --maintenance

deploy-only: check-env ensure-namespace
	KUSTOMIZE="$(KUSTOMIZE)" KUBECTL="$(KUBECTL)" IMAGE_REPO="$(IMAGE_REPO)" IMAGE_TAG="$(IMAGE_TAG)" ENV="$(ENV)" NAMESPACE="$(NAMESPACE)" NS_FLAG="$(NS_FLAG)" ENV_KUSTOMIZE_PATH="$(ENV_KUSTOMIZE_PATH)" ./deploy/deploy.sh --skip-build

# --------------------------------------------------------------------------- #
# Backup & Restore
# --------------------------------------------------------------------------- #

backup: backup-db backup-media

backup-db:
	$(KUBECTL) $(NS_FLAG) create job --from=cronjob/db-backup db-backup-manual-$$(date +%s)
	@echo "Database backup job created. Watch with: kubectl get jobs $(NS_FLAG) -w"

backup-media:
	$(KUBECTL) $(NS_FLAG) create job --from=cronjob/media-backup media-backup-manual-$$(date +%s)
	@echo "Media backup job created. Watch with: kubectl get jobs $(NS_FLAG) -w"

backup-list:
	@KUBECTL="$(KUBECTL)" NS_FLAG="$(NS_FLAG)" ./deploy/bases/backup/backup.sh list

restore-db:
	@KUBECTL="$(KUBECTL)" NS_FLAG="$(NS_FLAG)" ./deploy/bases/backup/backup.sh restore-db $(BACKUP_NAME)

restore-media:
	@KUBECTL="$(KUBECTL)" NS_FLAG="$(NS_FLAG)" ./deploy/bases/backup/backup.sh restore-media $(BACKUP_NAME)

# --------------------------------------------------------------------------- #
# Services overview
# --------------------------------------------------------------------------- #

services:
	KUBECTL="$(KUBECTL)" HELM="$(HELM)" MINIKUBE="$(MINIKUBE)" ./deploy/bases/services/services.sh html services.html
	@(xdg-open services.html >/dev/null 2>&1 || open services.html >/dev/null 2>&1 || echo "Open services.html in your browser") &

SERVICES_PERSISTENT ?= false
DASHBOARD_PORT ?= 9091

services-server:
	$(KUSTOMIZE) build deploy/bases/services | $(KUBECTL) apply -f -
	@$(KUBECTL) rollout status deployment/services-dashboard --timeout=120s
	@if ! pgrep -xf ".*minikube dashboard --port.*" >/dev/null 2>&1; then \
		echo "Starting minikube dashboard on port $(DASHBOARD_PORT)..."; \
		$(MINIKUBE) dashboard --port=$(DASHBOARD_PORT) >/dev/null 2>&1 & \
		sleep 3; \
	fi
	@echo ""
	@echo "Kubernetes dashboard: http://127.0.0.1:$(DASHBOARD_PORT)/api/v1/namespaces/kubernetes-dashboard/services/http:kubernetes-dashboard:/proxy/"
	@echo "Services dashboard:   http://localhost:8080"
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
		echo "Cleaning up..."; \
		pkill -f "minikube dashboard --port" 2>/dev/null || true; \
		$(KUBECTL) delete -k deploy/bases/services --ignore-not-found; \
	fi

# --------------------------------------------------------------------------- #
# Teardown
# --------------------------------------------------------------------------- #

destroy: check-env ensure-namespace
ifneq ($(ENV_KUSTOMIZE_PATH),)
	@$(KUSTOMIZE) build $(ENV_KUSTOMIZE_PATH) 2>/dev/null | $(KUBECTL) delete $(NS_FLAG) -f - --ignore-not-found --wait=false 2>/dev/null || true
else
	@$(KUSTOMIZE) build deploy/walkthrough/step-4 2>/dev/null | $(KUBECTL) delete -f - --ignore-not-found --wait=false 2>/dev/null || \
		$(KUSTOMIZE) build deploy/walkthrough/step-3 2>/dev/null | $(KUBECTL) delete -f - --ignore-not-found --wait=false 2>/dev/null || \
		$(KUSTOMIZE) build deploy/walkthrough/step-2 2>/dev/null | $(KUBECTL) delete -f - --ignore-not-found --wait=false 2>/dev/null || \
		$(KUSTOMIZE) build deploy/walkthrough/step-1 2>/dev/null | $(KUBECTL) delete -f - --ignore-not-found --wait=false 2>/dev/null || true
endif
	$(KUBECTL) delete pvc $(NS_FLAG) data-db-0 data-elasticsearch-0 data-rabbitmq-0 --ignore-not-found --wait=false

destroy-monitoring:
	$(HELM) uninstall kibana --no-hooks 2>/dev/null || true
	$(HELM) uninstall fluent-bit 2>/dev/null || true
	$(HELM) uninstall elasticsearch --no-hooks 2>/dev/null || true
	$(HELM) uninstall kube-prometheus-stack 2>/dev/null || true
	$(HELM) uninstall loki 2>/dev/null || true
	$(KUBECTL) delete pvc -l app=elasticsearch-master --ignore-not-found
	$(KUBECTL) delete secret elasticsearch-master-certs elasticsearch-master-credentials kibana-kibana-es-token --ignore-not-found

destroy-services:
	@$(KUSTOMIZE) build deploy/bases/services 2>/dev/null | $(KUBECTL) delete -f - --ignore-not-found --wait=false 2>/dev/null || true

destroy-cluster:
	$(HELM) uninstall cert-manager 2>/dev/null || true
	$(HELM) uninstall ingress-nginx 2>/dev/null || true
	$(HELM) uninstall secret-gsenerator 2>/dev/null || true

destroy-all: destroy-everything

destroy-everything:
	@echo "Destroying all environments..."
	@for ns in default staging production; do \
		echo "--- $$ns ---"; \
		nf=""; [ "$$ns" != "default" ] && nf="-n $$ns"; \
		$(KUSTOMIZE) build $(CURDIR)/deploy/overlays/$$ns 2>/dev/null | $(KUBECTL) delete $$nf -f - --ignore-not-found --wait=false 2>/dev/null || \
		$(KUSTOMIZE) build $(CURDIR)/deploy/walkthrough/step-4 2>/dev/null | $(KUBECTL) delete $$nf -f - --ignore-not-found --wait=false 2>/dev/null || \
		$(KUSTOMIZE) build $(CURDIR)/deploy/walkthrough/step-3 2>/dev/null | $(KUBECTL) delete $$nf -f - --ignore-not-found --wait=false 2>/dev/null || \
		$(KUSTOMIZE) build $(CURDIR)/deploy/walkthrough/step-1 2>/dev/null | $(KUBECTL) delete $$nf -f - --ignore-not-found --wait=false 2>/dev/null || true; \
		$(KUBECTL) delete pvc $$nf data-db-0 data-elasticsearch-0 data-rabbitmq-0 --ignore-not-found --wait=false 2>/dev/null || true; \
	done
	@echo "--- monitoring ---"
	@$(HELM) uninstall kibana --no-hooks 2>/dev/null || true
	@$(HELM) uninstall fluent-bit 2>/dev/null || true
	@$(HELM) uninstall elasticsearch --no-hooks 2>/dev/null || true
	@$(HELM) uninstall kube-prometheus-stack 2>/dev/null || true
	@$(HELM) uninstall loki 2>/dev/null || true
	@$(KUBECTL) delete pvc -l app=elasticsearch-master --ignore-not-found 2>/dev/null || true
	@$(KUBECTL) delete secret elasticsearch-master-certs elasticsearch-master-credentials kibana-kibana-es-token --ignore-not-found 2>/dev/null || true
	@echo "--- services ---"
	@$(KUSTOMIZE) build $(CURDIR)/deploy/bases/services 2>/dev/null | $(KUBECTL) delete -f - --ignore-not-found --wait=false 2>/dev/null || true
	@echo "--- cluster ---"
	@$(HELM) uninstall cert-manager 2>/dev/null || true
	@$(HELM) uninstall ingress-nginx 2>/dev/null || true
	@$(HELM) uninstall secret-gsenerator 2>/dev/null || true
	@echo "--- namespaces ---"
	@$(KUBECTL) delete namespace staging production --ignore-not-found --wait=false 2>/dev/null || true
	@echo "All environments and resources destroyed."

.PHONY: check-tools check-composer-auth check-env minikube cluster-dependencies ensure-namespace default dev develop stage staging stag production prod monitoring logging-loki monitoring-loki-datasource monitoring-kibana build step-1 step-1-deploy step-2 step-2-deploy step-3 step-3-deploy step-4 step-4-deploy deploy deploy-zero deploy-maintenance deploy-only backup backup-db backup-media backup-list restore-db restore-media destroy destroy-monitoring destroy-services destroy-cluster destroy-all destroy-everything services services-server

# ![](https://repository-images.githubusercontent.com/244943894/d275c4fd-3345-49ff-87cc-6d064b39f0f0 "Magento® on Kubernetes")

Here you will find everything you need to **deploy Magento to a Kubernetes cluster**.

See our article on [how to run Magento on Kubernetes][mok-article] for a complete walkthrough of this setup.

We also offer [commercial support for running Magento on Kubernetes][mok-landing].

## Prerequisites

* Minikube or a Kubernetes cluster with NGINX Ingress controller and storage
  provisioning
* `kubectl` configured with the proper context
* Standalone version of [kustomize](https://kustomize.io/) v3.9.0 or newer
* `helm`
* `docker`
* `make`

## Compatibility

This project is developed and tested using [kind](https://kind.sigs.k8s.io/) with the [latest supported patch versions of Kubernetes](https://kubernetes.io/releases/).

## Quick Start

```bash
# 1. Start a Minikube cluster
make minikube

# 2. Export Composer auth credentials
export COMPOSER_AUTH='{"http-basic":{"repo.magento.com":{"username":"...","password":"..."}}}'

# 3. Build the Docker image and deploy with Varnish (recommended)
make step-3-deploy

# 4. (Optional) Install monitoring stack
make monitoring
```

Once pods are running, open a tunnel to access the site locally:

```bash
minikube tunnel
```

You may need to add the ClusterIP to `/etc/hosts`:

```
10.96.0.2 magento.test
```

## Make Targets

### Pre-flight

| Target | Description |
|--------|-------------|
| `make check-tools` | Verify all required CLI tools are installed |
| `make check-composer-auth` | Verify `COMPOSER_AUTH` env var is set |

### Cluster

| Target | Description |
|--------|-------------|
| `make minikube` | Start a Minikube cluster with required addons (ingress, storage, metrics-server) |
| `make cluster-dependencies` | Install Helm charts: cert-manager, nginx-ingress, secret-generator |

### Monitoring & Logging

| Target | Description |
|--------|-------------|
| `make monitoring` | Install Prometheus + Grafana (metrics, dashboards, alerts) |
| `make logging-loki` | Install Loki + Promtail (log aggregation via Grafana Explore) |
| `make monitoring-loki-datasource` | Add Loki as a datasource in Grafana (run after `logging-loki`) |
| `make monitoring-kibana` | Install Elasticsearch + Fluentbit + Kibana (log aggregation via Kibana) |

### Build

| Target | Description |
|--------|-------------|
| `make build` | Build the Docker image from `src/Dockerfile` (targets the `app` stage). Image is tagged with the current git short SHA. Requires `COMPOSER_AUTH` |

Override the image tag: `make build IMAGE_TAG=v1.2.3`

### Walkthrough Steps

These deploy progressive configurations. Each step includes `cluster-dependencies`.

| Target | Description |
|--------|-------------|
| `make step-1` | Minimal Magento 2 deployment |
| `make step-2` | Step 1 + Redis (cache & session) + HorizontalPodAutoscalers |
| `make step-3` | Step 2 + Varnish |
| `make step-3-deploy` | Build image + deploy step-3 (handles IngressClass conflicts automatically) |

### Deploy (Production-style)

The `deploy/deploy.sh` script powers these targets. It auto-detects whether a
**zero-downtime** (rolling update) or **maintenance-mode** deploy is needed by
running `setup:db:status` and `app:config:status` against the new image — similar
to how capistrano-magento2 handles deployments.

The deploy overlay (`deploy/deploy/`) is based on step-3 but removes the
`magento-install` Job (install is only needed on first deploy).

| Target | Description |
|--------|-------------|
| `make deploy` | Build + auto-detect deploy strategy |
| `make deploy-zero` | Build + force zero-downtime rolling update |
| `make deploy-maintenance` | Build + force maintenance-mode deploy (scale down, upgrade DB/config, scale up) |
| `make deploy-only` | Deploy without rebuilding the image (uses existing image) |

All deploy targets require `COMPOSER_AUTH` (except `deploy-only`).

**Maintenance-mode deploy flow:**
1. Enable maintenance mode on running pods
2. Scale down `magento-web` to 0
3. Suspend `magento-cron`
4. Apply new manifests (init containers handle `setup:upgrade` / `app:config:import`)
5. Wait for rollout
6. Resume cron, flush cache, disable maintenance mode

### Teardown

| Target | Description |
|--------|-------------|
| `make destroy` | Delete step-3 resources and PVCs (database, elasticsearch) |

## Image Tagging

The image tag defaults to the git short SHA, with `-dirty` appended if there are
uncommitted changes. Override with:

```bash
make build IMAGE_TAG=v1.2.3
make deploy IMAGE_TAG=v1.2.3
```

## Monitoring Deployment

```bash
# Watch pod status
kubectl get pods -w

# Watch jobs
kubectl get jobs -w

# Follow install job logs (first deploy)
kubectl logs -f job/magento-install

# Minikube dashboard
minikube dashboard --url
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| IngressClass conflict | `kubectl delete ingressclass nginx` (handled automatically by `step-3-deploy`) |
| Install job stuck/failed | `kubectl delete job magento-install` and re-run |
| Can't access site locally | Run `minikube tunnel` and add ClusterIP to `/etc/hosts` |

## Health Checks

The `magento-web` deployment includes readiness and liveness probes:

| Probe | Type | Endpoint | Port | Initial Delay | Period | Timeout | Failure Threshold |
|-------|------|----------|------|---------------|--------|---------|-------------------|
| Readiness | HTTP GET | `/health_check.php` | 8080 | 30s | 10s | 1s | 5 |
| Liveness | HTTP GET | `/health_check.php` | 8080 | 30s | 10s | 1s | 5 |

- **Readiness probe**: Pod won't receive traffic until the probe succeeds. If it
  fails, the pod is removed from Service endpoints.
- **Liveness probe**: If it fails 5 consecutive times, kubelet restarts the
  container.

The `magento-web` deployment also runs three **init containers** before the main
process starts:

1. `wait-for-db` — polls the database on port 3306 until it's reachable
2. `wait-for-elasticsearch` — polls Elasticsearch on port 9200
3. `setup` — runs `setup:db:status || setup:upgrade --keep-generated` and
   `app:config:status || app:config:import` to ensure DB schema and config are
   in sync with the deployed code

Additionally, two sidecar containers export metrics:

| Sidecar | Port | Purpose |
|---------|------|---------|
| `php-metrics-exporter` | 9253 | Exports PHP-FPM pool metrics for Prometheus |
| `nginx-metrics-exporter` | 9113 | Exports Nginx stub_status metrics for Prometheus |

## Secrets Management

Secrets are generated automatically using the [mittwald/kubernetes-secret-generator](https://github.com/mittwald/kubernetes-secret-generator)
Helm chart (installed by `make cluster-dependencies`).

Two `StringSecret` resources are defined:

**`database-credentials`** (`deploy/bases/database/credentials.yaml`):
| Key | Value |
|-----|-------|
| `MYSQL_USER` | `magento` (static) |
| `MYSQL_DATABASE` | `magento` (static) |
| `MYSQL_PASSWORD` | Auto-generated (base64, 20 chars) |
| `MYSQL_ROOT_PASSWORD` | Auto-generated (base64, 20 chars) |

**`magento-admin`** (`deploy/bases/app/credentials.yaml`):
| Key | Value |
|-----|-------|
| `ADMIN_URI`, `ADMIN_EMAIL`, `ADMIN_FIRSTNAME`, `ADMIN_LASTNAME`, `ADMIN_USER` | Static defaults |
| `ADMIN_PASSWORD` | Auto-generated (base32, 20 chars) |

These secrets are referenced by the `magento-web` deployment, `magento-cron`,
`magento-install` job, and the `db` StatefulSet.

### Production Secrets

For production, replace the secret-generator approach with one of:

- **[Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets)** — encrypt
  secrets in git using a cluster-side controller. Encrypt with `kubeseal`, commit
  the `SealedSecret` resource, and the controller decrypts it into a regular
  `Secret` in-cluster.
- **[External Secrets Operator](https://external-secrets.io/)** — sync secrets
  from external providers (AWS Secrets Manager, HashiCorp Vault, GCP Secret
  Manager, Azure Key Vault) into Kubernetes secrets automatically.

In either case, replace the `StringSecret` resources in the base manifests with
the appropriate `SealedSecret` or `ExternalSecret` resource, keeping the same
secret names and keys so no deployment manifests need to change.

## SSL/TLS with cert-manager

The ingress manifest (`deploy/bases/app/ingress/main.yaml`) is pre-configured
with cert-manager annotations:

```yaml
annotations:
  acme.cert-manager.io/http01-edit-in-place: "true"
  cert-manager.io/issue-temporary-certificate: "true"
  kubernetes.io/tls-acme: "true"
spec:
  tls:
  - hosts:
    - magento.test
    secretName: magento
```

cert-manager is installed by `make cluster-dependencies` with a default
`selfsigned` ClusterIssuer.

### Local Development (Minikube/kind)

A self-signed `ClusterIssuer` is included at
`deploy/overlays/kind/clusterissuer-selfsigned.yaml`. This is applied
automatically when using the `kind` overlay and generates a self-signed
certificate for `magento.test`.

### Production (Let's Encrypt)

To use Let's Encrypt certificates in production, create a `ClusterIssuer`:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
    - http01:
        ingress:
          class: nginx
```

Then update the ingress annotation in your overlay:

```yaml
cert-manager.io/cluster-issuer: letsencrypt-prod
```

Update the `ingressShim.defaultIssuerName` in `cluster-dependencies` to match,
or use per-ingress annotations to select the issuer.

## Production Deployment Guide

### Differences from Minikube

| Concern | Minikube | Production |
|---------|----------|------------|
| Cluster | `make minikube` | Managed Kubernetes (GKE, EKS, AKS) or self-hosted |
| Ingress | Built-in addon with ClusterIP | Cloud load balancer or dedicated ingress controller |
| Storage | Default storage provisioner | Cloud-backed PVs (gp3, pd-ssd) or NFS for shared media |
| Secrets | mittwald secret-generator | Sealed Secrets or External Secrets Operator |
| TLS | Self-signed | Let's Encrypt via cert-manager |
| Image registry | Local Minikube cache | Container registry (ECR, GCR, ACR, Docker Hub) |
| DNS | `/etc/hosts` entry | Real DNS pointing to the load balancer |

### Deploying to an External Cluster

1. **Build and push the image** to your container registry:
   ```bash
   make build IMAGE_TAG=v1.2.3
   docker tag mymagento/magento2:v1.2.3 registry.example.com/magento2:v1.2.3
   docker push registry.example.com/magento2:v1.2.3
   ```

2. **Update `IMAGE_REPO`** to point to your registry:
   ```bash
   make deploy IMAGE_REPO=registry.example.com/magento2 IMAGE_TAG=v1.2.3
   ```

3. **Create a production overlay** under `deploy/overlays/production/` to
   customize resources, replica counts, hostnames, and resource limits:
   ```yaml
   # deploy/overlays/production/kustomization.yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
   - ../../deploy   # based on the deploy overlay (step-3 without install job)
   patches:
   - path: patches/magento-web.yaml
   - path: patches/ingress.yaml
   ```

4. **Configure imagePullSecrets** if your registry requires authentication:
   ```bash
   kubectl create secret docker-registry regcred \
     --docker-server=registry.example.com \
     --docker-username=... \
     --docker-password=...
   ```

### CI/CD Pipeline

A typical pipeline:

```
push to main → build image → push to registry → make deploy-only IMAGE_TAG=<sha>
```

Example GitHub Actions workflow:

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4
    - name: Build and push
      run: |
        docker build --build-arg COMPOSER_AUTH="${{ secrets.COMPOSER_AUTH }}" \
          --target app -f src/Dockerfile -t $REGISTRY/magento2:${{ github.sha }} src/
        docker push $REGISTRY/magento2:${{ github.sha }}
    - name: Deploy
      run: |
        make deploy-only IMAGE_REPO=$REGISTRY/magento2 IMAGE_TAG=${{ github.sha }}
```

### Resource Sizing Guidelines

| Component | CPU Request | Memory Request | Notes |
|-----------|------------|----------------|-------|
| magento-web | 500m–2000m | 1Gi–4Gi | Scale horizontally via HPA |
| db (Percona) | 500m–2000m | 2Gi–8Gi | Consider managed MySQL (RDS, Cloud SQL) for production |
| elasticsearch | 500m–2000m | 2Gi–4Gi | Consider managed Elasticsearch/OpenSearch |
| redis | 100m–500m | 256Mi–1Gi | |
| varnish | 250m–1000m | 512Mi–2Gi | |

## Monitoring & Observability

### Setup

Install the monitoring stack after deploying Magento:

```bash
# Metrics: Prometheus + Grafana (dashboards, alerts)
make monitoring

# Then choose a logging backend:
make logging-loki                   # Option A: Loki (logs in Grafana Explore)
make monitoring-loki-datasource     #           Wire Loki into Grafana

make monitoring-kibana                    # Option B: EFK (logs in Kibana)
```

### What Gets Installed

| Command | Components |
|---------|------------|
| `make monitoring` | [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) (Prometheus, Grafana, Alertmanager, kube-state-metrics) + ServiceMonitors, dashboards, alert rules |
| `make logging-loki` | [Loki](https://grafana.github.io/helm-charts) + Promtail — collects stdout/stderr from all pods |
| `make monitoring-kibana` | Elasticsearch + Fluentbit + Kibana — collects stdout/stderr from all pods |

### Accessing Dashboards

```bash
# Grafana (default credentials: admin / admin)
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80

# Prometheus
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090

# Alertmanager
kubectl port-forward svc/kube-prometheus-stack-alertmanager 9093:9093

# Kibana (if using EFK, credentials: elastic / admin)
kubectl port-forward svc/kibana-kibana 5601:5601
```

### Metrics Collection

The `magento-web` deployment exposes metrics via two sidecar containers that are
automatically scraped by Prometheus through `ServiceMonitor` resources:

| Exporter | Port | Metrics Endpoint | Source |
|----------|------|------------------|--------|
| `php-metrics-exporter` ([hipages/php-fpm_exporter](https://github.com/hipages/php-fpm_exporter)) | 9253 | `/metrics` | PHP-FPM status (`tcp://127.0.0.1:9001/status`) |
| `nginx-metrics-exporter` ([nginx-prometheus-exporter](https://github.com/nginxinc/nginx-prometheus-exporter)) | 9113 | `/metrics` | Nginx stub_status (`http://127.0.0.1:6081/stub_status`) |

### Grafana Dashboards

Three dashboards are provisioned automatically as ConfigMaps (labeled
`grafana_dashboard: "1"` for sidecar auto-discovery):

| Dashboard | UID | Panels |
|-----------|-----|--------|
| **Magento Overview** | `magento-overview` | Ready pods, restarts, request rate, 5xx error rate, CPU/memory by pod, HTTP traffic, Nginx connections |
| **Magento PHP-FPM** | `magento-phpfpm` | FPM up/down, active/idle/total processes, pool saturation %, process history, accepted connections rate, slow requests, listen queue |
| **Magento Nginx** | `magento-nginx` | Nginx up/down, request rate, active/waiting connections, traffic by pod, connection states (reading/writing/waiting), accepted vs handled rate, dropped connections |

### Log Aggregation

All application logs (PHP, PHP-FPM, Nginx, Magento) are forwarded to container
stdout/stderr via supervisord. Choose your preferred logging backend:

#### Option A: Loki (Grafana Explore)

Query logs in Grafana under **Explore** → **Loki** datasource:

```logql
# All Magento web pod logs
{app="magento", component="web"}

# Filter for PHP errors
{app="magento", component="web"} |= "error" != "404"

# Cron job logs
{job_name=~"magento-cron.*"}

# Install job logs
{job_name="magento-install"}
```

#### Option B: EFK (Kibana)

Open Kibana at `http://localhost:5601` (after port-forward). Create an index
pattern matching `logstash-*` under **Stack Management** → **Index Patterns**,
then use **Discover** to search and filter logs:

- Filter by `kubernetes.labels.app: magento` for Magento logs
- Filter by `kubernetes.container.name: magento-web` for Nginx/PHP logs
- Use the search bar for full-text search across all fields

### Alerting Rules

A `PrometheusRule` resource (`deploy/bases/monitoring/prometheusrule.yaml`)
defines alerts across four groups:

| Group | Alert | Severity | Condition |
|-------|-------|----------|-----------|
| **Pod** | `MagentoPodRestarting` | warning | >3 restarts in 1h |
| **Pod** | `MagentoPodNotReady` | critical | Not ready for 5m |
| **Pod** | `MagentoDeploymentUnavailable` | critical | Unavailable replicas for 10m |
| **PHP-FPM** | `PHPFPMPoolSaturation` | warning | Active/total processes >85% for 5m |
| **PHP-FPM** | `PHPFPMSlowRequests` | warning | Slow request rate >0.1/s for 5m |
| **PHP-FPM** | `PHPFPMDown` | critical | Exporter reports FPM down for 2m |
| **Nginx** | `NginxHighErrorRate` | warning | 5xx rate >5% for 5m |
| **Nginx** | `NginxDown` | critical | Exporter reports Nginx down for 2m |
| **Cron** | `MagentoCronJobFailing` | warning | >3 failed jobs in 10m |

To configure alert notifications (Slack, email, PagerDuty), update the
Alertmanager configuration in the kube-prometheus-stack Helm values.

## TODO

- [ ] Add health probes for database, Redis, Elasticsearch, and Varnish
- [ ] Improve `deploy.sh` to support custom kustomize overlay path (for production overlays)
- [ ] Add backup/restore procedures for database and media
- [ ] Add multi-environment overlay examples (staging, production)
- [ ] Add `imagePullSecrets` support in base deployment manifests

## Contributing

Contributions (issues, pull-requests) are welcome!

Please refer to [CONTRIBUTING](CONTRIBUTING.md) to get started.

[mok-landing]: https://kiwee.eu/services/cloud-native-solutions-for-ecommerce/magento-2-on-kubernetes-in-the-cloud/
[mok-article]: https://kiwee.eu/magento-2-on-kubernetes/

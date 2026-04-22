# ![](https://repository-images.githubusercontent.com/244943894/d275c4fd-3345-49ff-87cc-6d064b39f0f0 "Magento® on Kubernetes")

Here you will find everything you need to **deploy Magento to a Kubernetes cluster**.

See our article on [how to run Magento on Kubernetes][mok-article] for a complete walkthrough of this setup.

We also offer [commercial support for running Magento on Kubernetes][mok-landing].

## Prerequisites

* Minikube (or any Kubernetes cluster)
* `kubectl`, `kustomize` (v3.9.0+), `helm`, `docker`, `make`

## Quick Start

```bash
# 1. Start a Minikube cluster
make minikube

# 2. Export Composer auth credentials
export COMPOSER_AUTH='{"http-basic":{"repo.magento.com":{"username":"...","password":"..."}}}'

# 3. Build and deploy — pick the step that fits your needs
make step-4-deploy dev   # recommended: full stack with backups

# 4. Install log aggregation (Elasticsearch + Kibana)
make monitoring-kibana

# 5. Open all dashboards + live services overview
make services-server
```

Each deploy step builds on the previous one. Pick the level you need:

```bash
make step-1-deploy dev   # Magento + DB + Elasticsearch
make step-2-deploy dev   # + Redis (cache/sessions) + autoscaling
make step-3-deploy dev   # + Varnish (full-page cache)
make step-4-deploy dev   # + RabbitMQ + consumer workers + automated backups (recommended)
```

All deploy targets build the Docker image, apply manifests, follow the install job logs, and wait for the deployment to be ready.

Add `magento.test` to `/etc/hosts` and open a tunnel:

```bash
minikube tunnel
# /etc/hosts: 10.96.0.2 magento.test
```

## Make Targets

### Cluster

| Target | Description |
|--------|-------------|
| `make minikube` | Start Minikube with required addons (ingress, storage, metrics-server) |
| `make cluster-dependencies` | Install Helm charts: cert-manager, nginx-ingress, secret-generator |

### Build & Deploy (Walkthrough)

| Target | Components | What it adds |
|--------|-----------|--------------|
| `make step-1-deploy` | Magento + DB + Elasticsearch | Base setup |
| `make step-2-deploy` | + Redis + HPA | Cache, sessions, autoscaling |
| `make step-3-deploy` | + Varnish | Full-page cache |
| `make step-4-deploy` | + RabbitMQ + Consumer workers + Backup CronJobs | Message queues, dedicated queue consumers, automated backups |

Apply-only targets (no build): `make step-1`, `make step-2`, `make step-3`, `make step-4`

Build image only: `make build` (override tag: `make build IMAGE_TAG=v1.2.3`)

### Multi-Environment

Every target requires an environment. Shortcuts are supported:

```bash
make step-4-deploy dev          # deploy to default namespace
make step-4-deploy stage        # deploy to staging namespace
make step-4-deploy prod         # deploy to production namespace
make deploy stage               # production-style deploy to staging
make destroy prod               # tear down production
make backup-db prod             # backup production database
```

| Shortcut | Environment | Namespace | Hostname | Web Replicas | Consumer Replicas |
|----------|-------------|-----------|----------|--------------|-------------------|
| `dev` / `default` | default | `default` | `magento.test` | 1 | 1 |
| `stage` / `staging` | staging | `staging` | `staging.magento.test` | 1 | 1 |
| `prod` / `production` | production | `production` | `magento.example.com` | 3 | 2 |

Running without an environment will fail with an error. Customize overlays in `deploy/overlays/staging/` and `deploy/overlays/production/`.

### Deploy (Production-style)

Auto-detects zero-downtime vs maintenance-mode based on `setup:db:status` and `app:config:status`.

| Target | Description |
|--------|-------------|
| `make deploy` | Build + auto-detect strategy |
| `make deploy-zero` | Force zero-downtime rolling update |
| `make deploy-maintenance` | Force maintenance-mode (scale down, upgrade, scale up) |
| `make deploy-only` | Deploy without building (uses existing image) |

### Monitoring & Logging

| Target | Description |
|--------|-------------|
| `make monitoring` | Prometheus + Grafana (metrics, dashboards, alerts) |
| `make monitoring-kibana` | Elasticsearch + Fluent Bit + Kibana (log aggregation) |
| `make logging-loki` | Loki + Promtail (logs in Grafana Explore) |
| `make monitoring-loki-datasource` | Wire Loki into Grafana |

### Services Dashboard

| Target | Description |
|--------|-------------|
| `make services-server` | Deploy live dashboard pod + minikube dashboard, password-protected |
| `make services` | Generate a static HTML page with all URLs/credentials |

Options for `services-server`:

```bash
make services-server                           # default: cleanup on Ctrl+C
make services-server SERVICES_PERSISTENT=true  # pod stays after Ctrl+C
```

### Backup & Restore

Daily automated DB backups run via CronJob at 2 AM UTC. Media backup CronJob (3 AM UTC) is suspended by default — enable with:

```bash
kubectl patch cronjob media-backup -p '{"spec":{"suspend":false}}'
```

Keep last 7 backups by default.

| Target | Description |
|--------|-------------|
| `make backup` | Trigger both DB + media backup now |
| `make backup-db` | Trigger database backup now |
| `make backup-media` | Trigger media backup now |
| `make backup-list` | Show available backups with sizes |
| `make restore-db` | Restore latest database backup |
| `make restore-media` | Restore latest media backup |

Restore a specific backup: `make restore-db BACKUP_NAME=db-20260328-020000.sql.gz`

Backups are also visible in the services dashboard under the **Backups** page.

### Teardown

| Target | Description |
|--------|-------------|
| `make destroy` | Delete all app resources and PVCs |
| `make destroy-monitoring` | Remove monitoring/logging stack |
| `make destroy-services` | Remove services dashboard |
| `make destroy-cluster` | Remove Helm cluster dependencies |
| `make destroy-all` | Remove everything |

## Health Checks

The `magento-web` deployment includes readiness/liveness probes on `/health_check.php:8080` and three init containers:

1. **wait-for-db** — polls MySQL on port 3306
2. **wait-for-elasticsearch** — polls ES on port 9200
3. **setup** — runs `setup:upgrade` / `app:config:import` if needed

## Secrets Management

Secrets are auto-generated by [mittwald/kubernetes-secret-generator](https://github.com/mittwald/kubernetes-secret-generator) (installed via `make cluster-dependencies`).

| Secret | Key | Value |
|--------|-----|-------|
| `database-credentials` | `MYSQL_USER` / `MYSQL_DATABASE` | `magento` (static) |
| | `MYSQL_PASSWORD` / `MYSQL_ROOT_PASSWORD` | Auto-generated (20 chars) |
| `magento-admin` | `ADMIN_USER`, `ADMIN_URI`, etc. | Static defaults |
| | `ADMIN_PASSWORD` | Auto-generated (20 chars) |
| `services-dashboard-credentials` | `username` | `admin` (static) |
| | `password` | Auto-generated (20 chars) |

Use `make services` or `make services-server` to view all credentials.

For production, replace with [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) or [External Secrets Operator](https://external-secrets.io/).

## Monitoring & Observability

### Grafana Dashboards

Three dashboards are auto-provisioned:

| Dashboard | Panels |
|-----------|--------|
| **Magento Overview** | Ready pods, restarts, request rate, 5xx errors, CPU/memory |
| **Magento PHP-FPM** | Active/idle processes, pool saturation, slow requests |
| **Magento Nginx** | Request rate, connections, traffic by pod |

### Log Aggregation

All Magento logs (PHP, Nginx, var/log, var/report) are forwarded to stdout via supervisord.

**Kibana** (`make monitoring-kibana`): Create index pattern `logstash-*`, then filter:
- `kubernetes.container.name: "magento-web"` for Magento/PHP logs
- `kubernetes.container.name: "nginx"` for Nginx access logs

**Loki** (`make logging-loki`): Query in Grafana Explore:
```logql
{app="magento", component="web"} |= "error"
```

### Alerting Rules

Alerts defined in `deploy/bases/monitoring/prometheusrule.yaml`:

| Alert | Severity | Condition |
|-------|----------|-----------|
| `MagentoPodRestarting` | warning | >3 restarts in 1h |
| `MagentoPodNotReady` | critical | Not ready for 5m |
| `MagentoDeploymentUnavailable` | critical | Replicas unavailable for 10m |
| `PHPFPMPoolSaturation` | warning | >85% processes used for 5m |
| `PHPFPMSlowRequests` | warning | Slow request rate >0.1/sec for 5m |
| `PHPFPMDown` | critical | PHP-FPM exporter reports down |
| `NginxHighErrorRate` | warning | 5xx rate >5% for 5m |
| `NginxDown` | critical | Nginx exporter reports down |
| `MagentoCronJobFailing` | warning | >3 failed jobs in 10m |

## SSL/TLS

cert-manager handles certificates automatically. Local dev uses a self-signed `ClusterIssuer`, which Chrome flags as untrusted — see [TRUSTING_LOCAL_TLS.md](TRUSTING_LOCAL_TLS.md) for three ways to fix it (quick per-cert import, `mkcert`-backed CA, or a manual OpenSSL CA).

For production, create a Let's Encrypt `ClusterIssuer`:

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

## Production Notes

| Concern | Minikube | Production |
|---------|----------|------------|
| Cluster | `make minikube` | Managed K8s (GKE, EKS, AKS) |
| Storage | Default provisioner | Cloud PVs (gp3, pd-ssd) |
| Secrets | secret-generator | Sealed Secrets / External Secrets |
| TLS | Self-signed | Let's Encrypt |
| Registry | Local Minikube cache | Container registry (ECR, GCR, ACR) |

Deploy to an external cluster:
```bash
make build IMAGE_TAG=v1.2.3
docker tag mymagento/magento2:v1.2.3 registry.example.com/magento2:v1.2.3
docker push registry.example.com/magento2:v1.2.3
make deploy IMAGE_REPO=registry.example.com/magento2 IMAGE_TAG=v1.2.3
```

### What was added

| Area | Original | Current |
|------|----------|---------|
| **Deploy steps** | 3 steps (base, Redis, Varnish) | 4 steps (+RabbitMQ, backup CronJobs) |
| **Deploy strategy** | `kustomize build \| kubectl apply` | Auto-detect zero-downtime vs maintenance-mode (`deploy.sh`) |
| **Environments** | Single namespace | Multi-env (dev/staging/production) with overlays |
| **Monitoring** | None | Prometheus + Grafana + dashboards + alerting rules |
| **Logging** | None | EFK (Elasticsearch + Fluent Bit + Kibana) or Loki |
| **Backups** | None | Automated DB + media backup CronJobs with rotation |
| **Services dashboard** | None | Live web UI with credentials, pod status, backup management |
| **Health probes** | magento-web only | All services (DB, ES, Redis, RabbitMQ, Varnish) |
| **PDBs** | None | All services protected |
| **NetworkPolicies** | None | Default-deny + per-component allow policies; cross-namespace isolation (requires Calico/Cilium CNI) |
| **Resource limits** | Partial | All services have explicit requests and limits |
| **RabbitMQ** | None | Full AMQP integration with `env.docker.php` |
| **Consumer workers** | Cron-based (`consumers_runner`) | Cron-driven by default via `cron_consumers_runner` + `CONSUMERS_WAIT_FOR_MESSAGES=0` (empty-queue exit, per-tick `--max-messages` cycle). Dedicated `magento-consumer` Deployment ships commented out in step-4; opt in by uncommenting `../../bases/consumer` + overlay patches and flipping `CRON_CONSUMERS_RUNNER=false`. |
| **Redis topology** | Single instance (3 DBs) | Three dedicated StatefulSets — `redis-cache` + `redis-page-cache` (ephemeral, LRU) + `redis-sessions` (1Gi PVC, AOF persistence, `noeviction`). `cache:flush` only evicts `redis-cache`; FPC and sessions survive. Per-role PDBs prevent simultaneous eviction during drains. |
| **Kustomize components** | None | `deploy/components/resource-limits-added/` — single-file toggle that re-applies the cpu-limit additions on `db` + `rabbitmq` + `varnish`. Comment its `patches:` block to revert those three containers to the pre-initiative state without touching base manifests. |
| **Image tagging** | Static | Git SHA with `-dirty` suffix, minikube docker-env |
| **Makefile** | 4 targets | 30+ targets with env support, install log streaming |
| **README** | Minimal | Full docs, troubleshooting, production guide |

## TODO

### High priority (production functionality)

- [ ] **Sealed Secrets / External Secrets** — replace the mittwald secret-generator (which stores plain-text secrets in etcd) with encrypted secret management. [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) encrypts secrets in git using asymmetric crypto (safe to commit), or [External Secrets Operator](https://external-secrets.io/) syncs from AWS Secrets Manager / Vault / GCP Secret Manager. Essential for any production deployment. Also needed for the encryption key (see above).

- [ ] **Pod anti-affinity & topology spread** — add `podAntiAffinity` to prevent multiple replicas of the same service landing on one node, and `topologySpreadConstraints` for multi-zone clusters. Without this, a single node failure can take down all magento-web replicas. In production with 3+ nodes, this is the difference between zero-downtime and full outage during hardware failures. Add as a production overlay patch.

- [ ] **Monitoring coverage gaps** — add PrometheusRules for: database connection count / slow queries, Redis memory usage / eviction rate / connected clients, RabbitMQ queue depth / consumer count / unacked messages, Elasticsearch cluster health (yellow/red) / JVM heap, PVC usage approaching capacity. Current alerts cover pods and Magento-specific metrics but miss infrastructure health entirely.

### Medium priority (scalability & architecture)

- [ ] **OpenSearch migration** — replace Elasticsearch 7.17 (EOL, last patch Dec 2024) with OpenSearch 2.x. Magento 2.4.6+ supports OpenSearch natively via `CONFIG__DEFAULT__CATALOG__SEARCH__ENGINE=opensearch`. Avoids Elastic licensing restrictions (SSPL), gets active security patches, and is a drop-in replacement. Requires updating the base StatefulSet image, `common.env` search engine config, and health check endpoint.

- [ ] **Media storage on S3** — use Magento's built-in remote storage module (`--remote-storage-driver=aws-s3`) to store `pub/media` on S3/MinIO instead of a shared PVC. The current `ReadWriteOnce` PVC can only be mounted on one node, which blocks multi-zone deployments and makes horizontal scaling of magento-web fragile. S3 also eliminates the need for media backup CronJobs and enables CDN integration.

- [ ] **Horizontal scaling for Varnish** — currently a single Varnish pod is a single point of failure for all cached traffic. Add an HPA and configure VCL for multi-instance caching (consistent hashing or shared storage). Consider using the Varnish `shard` director to distribute cache across pods.

- [ ] **Database read replicas** — add Percona XtraDB Cluster or a ProxySQL sidecar for read/write splitting. Heavy catalog browsing (category pages, layered navigation, search) generates read-heavy queries that can saturate a single MySQL instance. Read replicas offload SELECT queries while the primary handles writes.

- [ ] **Deploy rollback on failure** — `deploy.sh` currently relies on `kubectl rollout status` exit code but doesn't automatically roll back. Add `kubectl rollout undo deployment/magento-web` on non-zero exit, and trigger a pre-deploy database backup so failed migrations can be reversed.

### Nice to have (advanced operations)

- [ ] **Canary deployments** — integrate [Argo Rollouts](https://argoproj.github.io/rollouts/) or [Flagger](https://flagger.app/) for progressive traffic shifting (e.g. 5% -> 25% -> 100%) with automated rollback based on error rate or latency metrics. Currently deployments are all-or-nothing — a bad release impacts 100% of traffic immediately.

- [ ] **Startup probes** — add Kubernetes startup probes (separate from liveness) for slow-starting services like Elasticsearch and the Magento setup init container. Startup probes allow longer initial boot times without the liveness probe killing the container during startup. Currently mitigated by high `initialDelaySeconds` but startup probes are more precise.

- [ ] **Graceful shutdown / preStop hooks** — add `preStop` lifecycle hooks to drain connections before pod termination. Magento web pods should finish in-flight PHP requests (`sleep 5` or SIGTERM handling), Varnish should drain its connection pool, and RabbitMQ should stop accepting new messages. Prevents 502 errors during rolling updates.

- [~] **Resource quotas per namespace** — ready on branch [`resource-governance`](../../tree/resource-governance), pending verification before merge. Adds `ResourceQuota` + two `LimitRange`s (container `defaultRequest`/`default` + PVC 1–20Gi bounds) from `deploy/bases/quota/`, wired only into staging and production overlays; dev/kind/test stay unconstrained. Per-env `hard` caps are sized for the local minikube profile (`--cpus=4 --memory=16g`): staging requests cap 4 CPU / 12Gi (limits 10 CPU / 20Gi), production requests cap 6 CPU / 18Gi (limits 14 CPU / 28Gi), with object caps for pods/services/configmaps/secrets/PVCs + 30Gi storage. Running on a real staging/production cluster requires bumping these `hard` values. The branch also commits explicit `resources:` on every init container and the install Job so the quota can be enforced without breaking admission.

## Contributing

Contributions (issues, pull-requests) are welcome! See [CONTRIBUTING](CONTRIBUTING.md).

[mok-landing]: https://kiwee.eu/services/cloud-native-solutions-for-ecommerce/magento-2-on-kubernetes-in-the-cloud/
[mok-article]: https://kiwee.eu/magento-2-on-kubernetes/

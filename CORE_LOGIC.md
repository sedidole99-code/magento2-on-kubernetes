# Magento 2 on Kubernetes - Core Logic Analysis

> Analysis of the core codebase up to commit `80c1a9e` (excluding automated dependency updates).
> Based on 125 human-authored commits by Maciej Lewkowicz (primary), Vlad von Hraban, Tomasz Gajewski, and Alexander Pavlov.

---

## Table of Contents

1. [Project Overview](#project-overview)
2. [Architecture](#architecture)
3. [Container Design](#container-design)
4. [Kustomize Structure](#kustomize-structure)
5. [Step-Based Deployment Progression](#step-based-deployment-progression)
6. [Application Layer (Magento)](#application-layer-magento)
7. [Backing Services](#backing-services)
8. [Configuration Management](#configuration-management)
9. [Secret Management](#secret-management)
10. [Ingress & Networking](#ingress--networking)
11. [Monitoring & Observability](#monitoring--observability)
12. [Backup System](#backup-system)
13. [Services Dashboard](#services-dashboard)
14. [Deployment Strategy](#deployment-strategy)
15. [CI/CD Pipeline](#cicd-pipeline)
16. [Testing](#testing)
17. [Project Evolution](#project-evolution)

---

## Project Overview

This repository implements a production-grade deployment of Magento 2 (Adobe Commerce) on Kubernetes. It provides a complete infrastructure stack managed through Kustomize, with progressive deployment steps that build from a minimal setup to a full production configuration.

**Key design principles:**
- Environment variables as the single source of truth for configuration
- Kustomize base/overlay pattern for environment separation
- Progressive complexity through a walkthrough step system
- Smart deployment with automatic strategy selection (zero-downtime vs maintenance mode)
- Comprehensive observability with Prometheus, Grafana, and ELK stack options

---

## Architecture

### High-Level Component Map

```
                    Internet
                       |
                  [ Ingress ]
                  (TLS term.)
                       |
                  [ Varnish ]         (HTTP cache, 512MB, Magento VCL)
                       |
               [ magento-web ]        (Nginx + PHP-FPM via supervisord)
              /    |        \
         [ DB ]  [ ES ]  [ Redis ]    (Percona 8.0, ES 7.17, Redis 8.0)
                            |
                       [ RabbitMQ ]   (Message queue, 4.1-management)
```

### Pod Architecture

The magento-web Deployment uses a multi-container pod:

| Container | Purpose | Port(s) |
|-----------|---------|---------|
| **magento-web** | Nginx + PHP-FPM (supervisord) | 8080 (http), 8081 (proxy), 6081 (nginx-status), 9001 (fpm-status) |
| **php-metrics-exporter** | PHP-FPM Prometheus exporter | 9253 |
| **nginx-metrics-exporter** | Nginx Prometheus exporter | 9113 |

**Init containers** (sequential):
1. `wait-for-db` - Probes `db:3306` with netcat
2. `wait-for-elasticsearch` - Probes ES HTTP endpoint with curl
3. `setup` - Runs `setup:db:status` / `setup:upgrade` and `app:config:status` / `app:config:import`

---

## Container Design

### PHP Web Application Pod Pattern

The project uses a **single container running Nginx + PHP-FPM via supervisord**. This was an intentional architectural choice after evaluating multiple patterns:

| Pattern | Evaluated | Chosen |
|---------|-----------|--------|
| Apache + mod_php (single process) | Yes | No |
| Nginx + PHP-FPM in single container (supervisord) | Yes | **Yes** |
| Nginx + PHP-FPM in separate containers (same pod) | Yes | No |
| Nginx + PHP-FPM in separate pods | Yes | No |

**Rationale:** The single-container approach avoids the complexity of shared volumes for static assets between containers, eliminates the need for socket vs network communication configuration, and keeps the pod definition simple while still getting Nginx's performance for static content.

### Dockerfile Stages

The multi-stage Dockerfile (`src/Dockerfile`) builds from `php:8.2-fpm`:

- **base** - System dependencies, PHP extensions (bcmath, gd, intl, mysqli, opcache, pdo_mysql, soap, xsl, zip), APCu, Nginx installation
- **build** - Composer install, magerun binary, supervisord config
- **dev** - Development variant with dev dependencies and `php.ini-development`
- **app** (production) - Production-optimized with `php.ini-production`, static content pre-deployed, DI compiled, autoloader optimized, `MAGE_MODE=production`

---

## Kustomize Structure

### Directory Layout

```
deploy/
├── bases/                      # Reusable component definitions
│   ├── app/                    # Magento web, cron, install job, ingress, PVC, PDB
│   ├── database/               # Percona StatefulSet, credentials, my.cnf
│   ├── elasticsearch/          # ES StatefulSet, PDB
│   ├── redis/                  # Three Redis StatefulSets (cache/page-cache/sessions), per-role PDBs
│   ├── rabbitmq/               # RabbitMQ StatefulSet, credentials, PDB
│   ├── varnish/                # Varnish Deployment, VCL config, PDB
│   ├── backup/                 # DB/media backup CronJobs, backup PVC
│   ├── monitoring/             # Prometheus rules, Grafana dashboards, ELK values
│   └── services/               # Admin dashboard deployment, RBAC, scripts
├── walkthrough/                # Progressive deployment steps
│   ├── step-1/                 # App + DB + Elasticsearch
│   ├── step-2/                 # + Redis + HPA
│   ├── step-3/                 # + Varnish (ingress rerouted)
│   └── step-4/                 # + RabbitMQ + Backups
├── overlays/                   # Environment-specific overlays
│   ├── production/             # 3 replicas, 500m-1 CPU, 2-4Gi RAM
│   ├── staging/                # 1 replica, 250m CPU, 1Gi RAM
│   ├── test/                   # CI test environment (extends kind)
│   └── kind/                   # Local KIND cluster config
├── deploy-envs/                # Thin wrappers for deploy.sh
│   ├── production/             # overlays/production + remove install job
│   └── staging/                # overlays/staging + remove install job
└── deploy.sh                   # Smart deployment script
```

### Base/Overlay Pattern

Each **base** defines a self-contained component with its own `kustomization.yaml`, ConfigMapGenerators, and resource definitions. **Walkthrough steps** compose bases progressively. **Overlays** customize steps for specific environments via:

- `namespace` setting for environment isolation
- `patchesStrategicMerge` for resource limits and replica counts
- `configMapGenerator` with `behavior: merge` for URL/domain overrides
- `images` transforms for tag overrides
- `patchesJson6902` for complex transformations (e.g., ingress backend swap)

---

## Step-Based Deployment Progression

The walkthrough implements a progressive deployment pattern, each step building on the previous:

### Step 1: Minimal Application
**Components:** App + Database + Elasticsearch

The bare minimum to run Magento 2. Includes the web deployment, Percona database, Elasticsearch for catalog search, cron job, install job, and ingress.

### Step 2: Caching & Autoscaling
**Adds:** Redis + HorizontalPodAutoscaler

Introduces three separate Redis StatefulSets: `redis-cache` (default cache), `redis-page-cache` (full-page cache), `redis-sessions` (session storage with PVC + AOF persistence). Splitting the workloads means a `cache:flush` only evicts `redis-cache` — FPC survives; and session data is preserved across pod restarts. Adds HPA scaling magento-web between 2-5 replicas at 75% CPU threshold. Patches add `wait-for-redis` init containers to web deployment and install job; the init container loops through all three Redis hosts.

### Step 3: HTTP Cache
**Adds:** Varnish

Deploys Varnish with Magento-optimized VCL. The ingress is patched (JSON6902) to route traffic through Varnish instead of directly to magento-web. Varnish communicates with magento-web via PROXY protocol on port 8081.

### Step 4: Full Stack
**Adds:** RabbitMQ + Backup system

Adds RabbitMQ for async message processing and automated backup CronJobs. Patches add `wait-for-rabbitmq` init containers. All production and staging overlays build on this step.

---

## Application Layer (Magento)

### Web Deployment (`deploy/bases/app/magento-web.yaml`)

- **Update Strategy:** Rolling update (50% maxSurge, 30% maxUnavailable)
- **Health Checks:** Both readiness and liveness probe `/health_check.php` on port 8080 (30s initial delay, 10s period, 5 failure threshold)
- **Resources:** 250m CPU, 1Gi RAM (base; scaled per environment)
- **Volume:** `media` PVC (1Gi, ReadWriteOnce) mounted at `/var/www/html/pub/media` with subPath
- **PDB:** maxUnavailable: 1

### Cron Job (`deploy/bases/app/cron/magento.yaml`)

- **Schedule:** `* * * * *` (every minute; Magento's internal scheduler controls actual execution)
- **Concurrency:** `Forbid` (prevents overlapping)
- **Init container:** `wait-for-web` - curls `/health_check.php` to ensure app is ready
- **Command:** `php bin/magento cron:run`
- **Resources:** 50m-500m CPU (burstable), 1-4Gi RAM
- **Critical config:** All cron groups run in single process mode (`USE_SEPARATE_PROCESS=0`) to prevent container termination before completion

### Install Job (`deploy/bases/app/jobs/install.yaml`)

- **TTL:** 600s after completion (auto-cleanup)
- **Init containers:** `set-volume-ownership` (chown 33:33 for www-data), `wait-for-db`, `wait-for-elasticsearch`
- **Steps:**
  1. Run `./bin/install.sh` (custom installation script)
  2. Generate performance fixtures from `setup/performance-toolkit/profiles/ce/mok.xml`
  3. Set all indexers to "schedule" mode via magerun
  4. Reset indices and flush cache
- **Note:** Immutable pod template - must be deleted and recreated per release. Removed in deploy-envs for subsequent deploys (install job is only for initial setup).

### Nginx Configuration

The embedded Nginx configuration (`deploy/bases/app/config/nginx/`) provides:

- **Upstream:** PHP-FPM on port 9000 via Kubernetes DNS
- **Static asset caching:** 1-year expiry for static and media files
- **Security:** Denies access to `.user.ini`, `/setup`, `/update`, sensitive media directories (`/media/customer/`, `/media/downloadable/`, `/media/import/`)
- **Performance:** Gzip level 6, FastCGI buffering (1024 x 4k), PHP memory limit 756M, max execution 18000s
- **Status endpoint:** `/stub_status` on port 6081 for metrics exporter

---

## Backing Services

### Database - Percona 8.0 (`deploy/bases/database/`)

| Aspect | Configuration |
|--------|--------------|
| **Kind** | StatefulSet (1 replica) |
| **Storage** | 10Gi PVC, subPath: `mysql` |
| **Resources** | 100m-1 CPU, 1Gi RAM |
| **Init container** | `set-volume-ownership` (chown 1001:1001) |
| **Health checks** | `mysqladmin ping` (readiness: 15s delay, liveness: 30s delay) |

**Key my.cnf tuning:**
- `innodb_buffer_pool_size=512M` with 4 instances of 128M chunks
- `innodb_log_file_size=256M` (2 log files)
- `innodb_flush_method=O_DIRECT` (bypass OS cache)
- `innodb_flush_log_at_trx_commit=2` (balance performance/safety)
- `max_allowed_packet=256M`
- `log_bin_trust_function_creators=1` (required for Magento triggers)

### Elasticsearch 7.17 (`deploy/bases/elasticsearch/`)

| Aspect | Configuration |
|--------|--------------|
| **Kind** | StatefulSet (1 replica, single-node cluster) |
| **Storage** | 1Gi PVC, subPath: `data` |
| **Resources** | 250m-500m CPU, 1Gi RAM |
| **JVM** | `-Xms512m -Xmx512m` |
| **Security** | `xpack.security.enabled=false` |
| **Health checks** | HTTP GET `/_cluster/health?local=true` (readiness: 20s, liveness: 60s) |

Initially deployed via Elastic Cloud on Kubernetes (ECK) operator, later simplified to a native StatefulSet (commit `0f4f951`).

### Redis 8.0 (`deploy/bases/redis/`)

Three independent StatefulSets, each a single replica with its own Service and per-role PodDisruptionBudget. All three carry label `app: redis` (so the existing `allow-redis` NetworkPolicy and all `magento-*` egress rules apply unchanged) plus a `role: cache|page-cache|sessions` label.

| Instance | Service | Storage | Redis flags | Resources (req / limit) |
|----------|---------|---------|-------------|-------------------------|
| `redis-cache` | `redis-cache:6379` | `emptyDir` | `--maxmemory 512mb --maxmemory-policy allkeys-lru` | 50m / 500m CPU, 256Mi / 1Gi RAM |
| `redis-page-cache` | `redis-page-cache:6379` | `emptyDir` | `--maxmemory 1024mb --maxmemory-policy allkeys-lru` | 50m / 500m CPU, 512Mi / 2Gi RAM |
| `redis-sessions` | `redis-sessions:6379` | `VolumeClaimTemplate` 1Gi at `/data` | `--appendonly yes --appendfsync everysec --maxmemory 256mb --maxmemory-policy noeviction` | 50m / 200m CPU, 128Mi / 512Mi RAM |

All three use health checks via `redis-cli ping` (readiness: 5s, liveness: 15s).

**Why split:** On the single-instance model, `bin/magento cache:flush` (run on every deploy by `deploy.sh`) wiped the default cache AND triggered memory pressure that evicted FPC entries — defeating the point of a full-page cache. Sessions also shared RAM with the caches, so a large cache population could log users out. The split lets a cache flush touch only `redis-cache`, keeps FPC intact, and gives sessions their own instance with disk persistence so restarts don't destroy user sessions. `src/app/etc/env.docker.php` already supported three independent `REDIS_*` env-var groups; the change was purely K8s topology + ConfigMap.

### Varnish 7.7 (`deploy/bases/varnish/`)

| Aspect | Configuration |
|--------|--------------|
| **Kind** | Deployment (stateless, 1 replica) |
| **Storage** | None (512MB in-memory cache store) |
| **Resources** | 50m-500m CPU, 512Mi-1Gi RAM |
| **Ports** | 8080 (http), 8081 (PROXY protocol), 6081 (admin/purge) |
| **Health checks** | TCP socket on port 8080 |

**VCL highlights:**
- Backend: `magento-web:8081` with health probe at `/health_check.php`
- PURGE support via `X-Magento-Tags-Pattern` and `X-Pool` headers (admin port only)
- Grace period: 3 days (serve stale content when backend unhealthy)
- Bypasses: checkout, catalogsearch, health check URLs
- GraphQL-aware header processing for `/graphql` paths
- Strips marketing parameters (utm, gclid, etc.)
- ESI support for text content
- Access log via `varnishncsa` on stdout

### RabbitMQ 4.1 (`deploy/bases/rabbitmq/`)

| Aspect | Configuration |
|--------|--------------|
| **Kind** | StatefulSet (1 replica) |
| **Storage** | 1Gi PVC at `/var/lib/rabbitmq` |
| **Resources** | 50m CPU (no limit), 256-512Mi RAM |
| **Ports** | 5672 (AMQP), 15672 (management UI) |
| **Health checks** | `rabbitmq-diagnostics check_port_connectivity` / `ping` |

---

## Configuration Management

### Environment Variable Flow

Configuration flows through a layered system:

```
1. Explicit env vars (DB_HOST=db, DB_NAME/DB_USER/DB_PASS from secrets)
      ↓
2. ConfigMap "config" (common.env: Elasticsearch, URLs, cron, mode)
      ↓
3. ConfigMap "additional" (step-specific: Redis, Varnish, AMQP settings)
      ↓
4. Secret "magento-admin" (admin credentials)
      ↓
5. Runtime: app/etc/env.docker.php reads all ENV vars
      ↓
6. Magento CONFIG__ pattern overrides database-stored config
```

### Magento CONFIG__ Pattern

Magento 2 natively reads environment variables in the format `CONFIG__<SCOPE>__<PATH>` and translates them to configuration values, locking them in the admin panel:

```
CONFIG__DEFAULT__CATALOG__SEARCH__ENGINE=elasticsearch7
  → catalog/search/engine = elasticsearch7

CONFIG__DEFAULT__SYSTEM__CRON__DEFAULT__USE_SEPARATE_PROCESS=0
  → system/cron/default/use_separate_process = 0
```

### Runtime Configuration (`env.docker.php`)

The file `src/app/etc/env.docker.php` is a PHP configuration file that reads environment variables at runtime via `getenv()` and constructs Magento's configuration array. This approach avoids baking credentials into the container image while supporting dynamic configuration:

- **Database:** `DB_HOST`, `DB_NAME`, `DB_USER`, `DB_PASS`
- **Session storage:** `REDIS_SESSION_HOST`/`PORT`/`DB` or `MEMCACHED_SESSION_HOST`
- **Cache backend:** `REDIS_CACHE_HOST`/`PORT`/`DB`
- **Full-page cache:** `REDIS_FPC_HOST`/`PORT`/`DB`
- **Message queue:** `AMQP_HOST`/`PORT`/`USER`/`PASSWORD`/`VIRTUALHOST`
- **HTTP cache:** `VARNISH_HOST`/`PORT`
- **Encryption:** `KEY`
- **Mode:** `MAGE_MODE`

### ConfigMap Merging via Kustomize

Base ConfigMaps are defined in `deploy/bases/app/kustomization.yaml`:
- `nginx` - Nginx configuration files
- `config` - Base environment (common.env)
- `additional` - Service-specific config (initially empty)

Each walkthrough step and overlay merges additional values:
- Step 2 adds Redis connection vars to `additional`
- Step 3 adds Varnish/FPC config to `additional`
- Step 4 adds AMQP config to `additional`
- Environment overlays merge domain-specific URLs into `config` with `behavior: merge`

---

## Secret Management

Secrets are auto-generated using the **mittwald/kubernetes-secret-generator** (StringSecret CRD):

### Database Credentials (`deploy/bases/database/credentials.yaml`)
- `MYSQL_USER`: "magento" (static)
- `MYSQL_DATABASE`: "magento" (static)
- `MYSQL_PASSWORD`: Auto-generated (20 chars, base64)
- `MYSQL_ROOT_PASSWORD`: Auto-generated (20 chars, base64)
- `forceRegenerate: false` (persists across updates)

### Admin Credentials (`deploy/bases/app/credentials.yaml`)
- `ADMIN_URI`: "admin", `ADMIN_EMAIL`: "admin@example.com"
- `ADMIN_FIRSTNAME`: "Jane", `ADMIN_LASTNAME`: "Doe", `ADMIN_USER`: "admin"
- `ADMIN_PASSWORD`: Auto-generated (20 chars, base32)

### RabbitMQ Credentials (`deploy/bases/rabbitmq/credentials.yaml`)
- `RABBITMQ_DEFAULT_USER`: "magento" (static)
- `RABBITMQ_DEFAULT_PASS`: Auto-generated (20 chars, base32)

### Services Dashboard Credentials (`deploy/bases/services/credentials.yaml`)
- `admin` / auto-generated password for HTTP basic auth

---

## Ingress & Networking

### Ingress Configuration (`deploy/bases/app/ingress/main.yaml`)

- **TLS:** cert-manager integration with automatic certificate provisioning
- **Host:** `magento.test` (base), overridden per environment
- **Annotations:** Proxy buffer 256k, 4 buffers, 60s timeouts, SSL redirect off
- **Routing:** Default backend and path-based routing to magento-web:8080

### Traffic Flow by Step

| Step | Ingress Target | Flow |
|------|---------------|------|
| Step 1 | magento-web:8080 | Client -> Ingress -> magento-web |
| Step 2 | magento-web:8080 | Client -> Ingress -> magento-web |
| Step 3+ | varnish:8080 | Client -> Ingress -> Varnish -> magento-web:8081 (PROXY) |

The ingress backend is swapped via JSON6902 patch in step-3, redirecting traffic through Varnish. Varnish connects to the backend via PROXY protocol on port 8081, while the admin/purge API is accessible internally on port 6081.

### Environment Domains

| Environment | Domain | TLS Secret |
|------------|--------|------------|
| Base/Dev | magento.test | magento |
| Staging | staging.magento.test | magento-staging |
| Production | magento.example.com | magento-production |

---

## Monitoring & Observability

### Prometheus Metrics Collection

Two ServiceMonitors scrape metrics every 15 seconds:
- **magento-phpfpm** - PHP-FPM metrics from `hipages/php-fpm_exporter` sidecar (port 9253)
- **magento-nginx** - Nginx metrics from `nginx/nginx-prometheus-exporter` sidecar (port 9113)

### Alerting Rules (PrometheusRule)

**Pod alerts:**
- `MagentoPodRestarting` - Warning if >3 restarts in 1 hour
- `MagentoPodNotReady` - Critical if not ready for >5 minutes
- `MagentoDeploymentUnavailable` - Critical if replicas unavailable >10 minutes

**PHP-FPM alerts:**
- `PHPFPMPoolSaturation` - Warning if active processes >85% of total
- `PHPFPMSlowRequests` - Warning if slow request rate >0.1/sec for 5 min
- `PHPFPMDown` - Critical if exporter reports down

**Nginx alerts:**
- `NginxHighErrorRate` - Warning if 5xx errors >5% for 5 min
- `NginxDown` - Critical if exporter reports down

**Cron alerts:**
- `MagentoCronJobFailing` - Warning if >3 failures in 10 minutes

### Grafana Dashboards

Three pre-built dashboards auto-provisioned via ConfigMaps (label `grafana_dashboard: "1"`):

1. **Magento Overview** - Ready pods, restarts, request rate, error rate, CPU/memory per pod, HTTP traffic, Nginx connections
2. **PHP-FPM** - Pool up/down, active/idle/total processes, saturation percentage, connection rate, slow requests, listen queue
3. **Nginx** - Up/down, request rate, active/waiting connections, accepted vs handled connections, dropped connections

### Logging Stack Options

**Option A: ELK Stack** (Elasticsearch + Fluent Bit + Kibana)
- Configured via Helm values files in `deploy/bases/monitoring/`
- Fluent Bit collects container stdout and ships to Elasticsearch
- Kibana provides log search and visualization

**Option B: Loki + Promtail** (via Makefile target `make logging-loki`)

**Application logging:** Magento logs are redirected to stdout using `graycoreio/magento2-stdlogging` module (commit `127e9fd`), following the Twelve-Factor App methodology.

---

## Backup System

### Database Backup (`deploy/bases/backup/cronjob/db-backup.yaml`)

- **Schedule:** Daily at 2:00 AM UTC
- **Method:** `mysqldump --single-transaction --quick --lock-tables=false`
- **Output:** `db-{TIMESTAMP}.sql.gz` (gzip compressed)
- **Retention:** 7 most recent backups (older auto-deleted)
- **Storage:** 10Gi `backup` PVC
- **Init container:** `wait-for-db` ensures database is reachable

### Media Backup (`deploy/bases/backup/cronjob/media-backup.yaml`)

- **Schedule:** Daily at 3:00 AM UTC (currently **suspended**)
- **Method:** `tar -czf` of `/var/www/html/pub/media`
- **Output:** `media-{TIMESTAMP}.tar.gz`
- **Retention:** 7 most recent backups
- **Deadline:** 1 hour max runtime

### Restore Operations (`deploy/bases/backup/backup.sh`)

A utility script supporting three operations:
- `./backup.sh list` - Lists available DB and media backups
- `./backup.sh restore-db [filename]` - Restores database from backup (latest if no filename)
- `./backup.sh restore-media [filename]` - Restores media files from backup

Uses ephemeral `kubectl run` pods with the backup and media PVCs mounted.

---

## Services Dashboard

A unified admin portal (`deploy/bases/services/`) providing cluster visibility:

### Architecture

Three-container pod + init container:
1. **generate-htpasswd** (init) - Creates `.htpasswd` from auto-generated credentials
2. **web** (Nginx) - Serves HTML dashboard, proxies API, serves backup file downloads
3. **collector** (kubectl) - Polls cluster state every 30s, writes JSON to shared volume
4. **api** (busybox/netcat) - Lightweight HTTP server for backup deletion

### Features

- **Environment tabs:** View Dev/Staging/Production namespace status
- **Service cards:** Connection details, credentials, images for all services (Magento, DB, ES, Redis, Varnish, RabbitMQ, Grafana, Prometheus, Kibana)
- **Pod status table:** Name, ready state, status (color-coded), restarts, age
- **Backup management:** List, download, restore commands, delete with confirmation
- **RBAC:** ClusterRole with read access to secrets, pods, services, deployments, statefulsets, namespaces

### Data Collection

- **Static data** (30-min refresh): Credentials, container images
- **Dynamic data** (30-sec refresh): Pod status, service endpoints, Helm releases, backup inventory
- **Output:** JSON files per namespace (`env-default.json`, `env-staging.json`, `env-production.json`)

---

## Deployment Strategy

### Smart Deployment (`deploy/deploy.sh`)

The deploy script automatically selects the optimal deployment strategy:

```
New Image Built
      ↓
Pre-deploy Check (ephemeral pod with new image)
├── php bin/magento setup:db:status    → exit 0? (no DB changes)
└── php bin/magento app:config:status  → exit 0? (no config changes)
      ↓
Both exit 0?
├── YES → Zero-Downtime (rolling update)
│         1. kubectl apply (new manifests)
│         2. Wait for rollout
│         3. cache:flush on running pod
│
└── NO  → Maintenance Mode
          1. maintenance:enable on current pods
          2. cache:flush
          3. Scale to 0 replicas
          4. Suspend magento-cron
          5. kubectl apply (init containers run setup:upgrade)
          6. Wait for rollout
          7. Resume magento-cron
          8. cache:flush + maintenance:disable
```

**Image tagging:** Git short SHA, with `-dirty` suffix if uncommitted changes exist.

**Makefile targets:**
- `make deploy <env>` - Auto-detect strategy
- `make deploy-zero <env>` - Force zero-downtime
- `make deploy-maintenance <env>` - Force maintenance mode
- `make deploy-only <env>` - Deploy pre-built image (skip build)

---

## CI/CD Pipeline

### GitHub Actions Workflows

**main.yml** - Full integration test:
- **Trigger:** Push and pull requests
- **Matrix:** Kubernetes v1.27.3, v1.28.0, v1.29.0
- **Steps:** KIND cluster -> Tool setup -> `skaffold build` -> `skaffold run` -> `skaffold verify` (e2e tests)

**walkthrough.yml** - Step validation:
- **Trigger:** Pull requests only
- **Tests:** Sequential deployment of step-1, step-2, step-3 with verification after each

### Skaffold Integration (`skaffold.yaml`, API v4beta10)

- **Build:** Docker images for `kiweeteam/magento2` (app target) and `kiweeteam/magento2-cypress` (test runner)
- **Deploy:** Kustomize manifests from `deploy/overlays/test`
- **Helm deps:** cert-manager, nginx-ingress, secret-generator auto-installed
- **Verify:** Cypress e2e tests run as Kubernetes Job
- **File sync:** `composer.json`, `composer.lock`, `app/etc/config.php` synced without rebuild
- **Port forwarding:** Ingress controller ports 80/443

### Local Development

```bash
make minikube                  # Start local cluster
make cluster-dependencies      # Install Helm charts (cert-manager, ingress, secret-gen)
make build                     # Build Docker image (requires COMPOSER_AUTH)
make step-1                    # Deploy minimal stack
# ... iterate through steps or use full deploy
```

---

## Testing

### E2E Tests (Cypress + Cucumber)

**Location:** `test/e2e/`

**Test scenario:** Full checkout flow using BDD (Gherkin):
1. Navigate to product page (`/simple-product-1.html`)
2. Add product to cart
3. Fill shipping form (email, name, address, region, phone)
4. Select flat-rate shipping
5. Complete payment
6. Verify order success page (`/checkout/onepage/success`)

**Configuration:**
- Viewport: 1280x800
- Timeouts: 30s (commands, requests, page load)
- Base URL: `https://magento.test/`
- Pre-check: curl with 9 retries to verify app readiness

---

## Project Evolution

### Phase 1: Foundation (Nov 2019 - Mar 2020)
- Initial commit and 4-step progressive deployment
- Step-1: App + DB + ES (ECK operator)
- Step-2: + Redis + HPA
- Step-3: + Varnish with VCL
- Step-4: Originally additional features (later restructured)

### Phase 2: Infrastructure Modernization (2021-2022)
- Kubernetes compatibility updates (1.18 -> 1.21 -> 1.24)
- Added Dockerfile to repository
- ECK operator replaced with native StatefulSet
- PHP-FPM + Nginx merged into single container with supervisord
- Skaffold integration for local development
- Test automation with Cypress

### Phase 3: CI/CD & Magento Upgrades (2023)
- Migrated from Jenkins to GitHub Actions
- Magento upgraded to 2.4.6 line (progressive patch releases)
- Elasticsearch reorganized from step-2 to step-1
- Step-4 (original) removed; Varnish moved earlier
- Custom Dockerfile removed (external image building)

### Phase 4: Production Hardening (2024)
- Database stability fixes (mount paths, AppArmor, triggers, config tuning)
- Volume ownership fixes (3 progressive commits)
- Prometheus metrics exporters (PHP-FPM, Nginx)
- Alerting rules and Grafana dashboards
- Session storage made configurable
- Password randomization via StringSecret CRD
- Varnish incomplete response fix
- PROXY protocol support
- php.ini configuration
- Renovate adoption for automated dependency management
- Directory restructured: `deploy/overlays` and `deploy/walkthrough`
- Domain changed from `magento2.local` to `magento.test`

### Phase 5: Current State (2025)
- Magento 2.4.6-p11 on PHP 8.2.29
- Percona 8.0, Elasticsearch 7.17.28, Redis 8.0.2, Varnish 7.7, RabbitMQ 4.1
- Full observability stack (Prometheus, Grafana, optional ELK/Loki)
- Automated backups with dashboard management
- Smart deployment with auto-strategy selection
- CI testing across Kubernetes 1.27-1.29

### Key Contributors
- **Maciej Lewkowicz** - Primary author (111 commits), architecture, all major features
- **Vlad von Hraban** - Infrastructure fixes, Makefile updates, ES security, step cleanup (9 commits)
- **Tomasz Gajewski** - Magento version update (1 commit)
- **Alexander Pavlov** - Helm chart fix for secret-generator (1 commit)

---

## Resource Summary

### Per-Environment Resource Budgets

| Component | Base (requests) | Base (limits) | Production (requests) | Production (limits) |
|-----------|----------------|---------------|----------------------|---------------------|
| magento-web | 250m / 1Gi | 250m / 1Gi | 500m / 2Gi | 1 / 4Gi |
| php-metrics | 50m / 128Mi | 50m / 128Mi | 50m / 128Mi | 50m / 128Mi |
| nginx-metrics | 50m / 128Mi | 50m / 128Mi | 50m / 128Mi | 50m / 128Mi |
| magento-cron | 50m / 1Gi | 500m / 4Gi | 50m / 1Gi | 500m / 4Gi |
| database | 100m / 1Gi | 1 / 1Gi | 500m / 2Gi | 1 / 4Gi |
| elasticsearch | 250m / 1Gi | 500m / 1Gi | 250m / 1Gi | 500m / 1Gi |
| redis-cache | 50m / 256Mi | 500m / 1Gi | 50m / 256Mi | 500m / 1Gi |
| redis-page-cache | 50m / 512Mi | 500m / 2Gi | 50m / 512Mi | 500m / 2Gi |
| redis-sessions | 50m / 128Mi | 200m / 512Mi | 50m / 128Mi | 200m / 512Mi |
| varnish | 50m / 512Mi | 500m / 1Gi | 50m / 512Mi | 500m / 1Gi |
| rabbitmq | 50m / 256Mi | - / 512Mi | 50m / 256Mi | - / 512Mi |

### Key Design Decisions

1. **Supervisord over separate containers** - Simplicity over strict single-process-per-container
2. **Kustomize over Helm** - Better transparency for learning, straightforward overlays
3. **StringSecret CRD** - Auto-generated credentials without external secret management
4. **No Redis persistence** - Acceptable data loss on restart for cache/session data
5. **Single-node stateful services** - Simplicity for demo/small deployments; notes for production scaling
6. **Image digest pinning** - Most images pinned by SHA256 digest for reproducibility (except RabbitMQ)
7. **PodDisruptionBudgets on all services** - Ensures availability during cluster maintenance
8. **Stdout logging** - Follows Twelve-Factor methodology; sidecars replaced by PSR-3 stdout logging

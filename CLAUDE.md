# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Keeping this file current

CLAUDE.md is the primary briefing for every new Claude session on this repo. If it drifts out of date, Claude will produce confident but wrong suggestions.

**Any change that affects architecture, topology, deploy flow, or cross-component contracts MUST update CLAUDE.md in the same commit.** Examples that trigger an update:

- A new base under `deploy/bases/` or a new walkthrough step
- A new container or init container in an existing pod
- A new cross-component dependency (pod X now talks to service Y)
- A new cluster-wide concern (NetworkPolicies, RBAC, quotas, PDBs)
- A change to how env vars / secrets / configmaps flow into pods
- A new deploy strategy or change to `deploy.sh` decision logic
- A new category of Makefile targets

Before closing an architectural task, re-read the relevant Architecture subsection and ask: *"Could a new Claude session, reading only CLAUDE.md, produce advice that's now stale?"* If yes, update. Small bugfixes, docs, or code inside existing structures do not need CLAUDE.md changes.

## What This Is

A production-grade Kubernetes deployment system for Magento 2 (Adobe Commerce). The repo contains no application code — it provides Kubernetes manifests (Kustomize), a multi-stage Dockerfile, deployment scripts, monitoring, backups, and a services dashboard.

## Common Commands

### Prerequisites

```bash
# Required tools: minikube, kubectl, kustomize (v3.9.0+), helm, docker, make
export COMPOSER_AUTH='{"http-basic":{"repo.magento.com":{"username":"...","password":"..."}}}'
```

### Build & Deploy

```bash
make minikube                    # Start local cluster (K8s v1.35.4, 4 CPU, 16GB)
make cluster-dependencies        # Install Helm charts (cert-manager, nginx-ingress, secret-generator)
make build                       # Build Docker image (tag: git SHA, appends -dirty if uncommitted)
make step-4-deploy dev           # Build + deploy full stack (recommended)
```

Every target requires an environment suffix: `dev`/`default`, `stage`/`staging`, `prod`/`production`.

### Step-by-Step Deployment (each builds on previous)

```bash
make step-1-deploy dev           # Magento + DB + Elasticsearch
make step-2-deploy dev           # + Redis + HPA autoscaling
make step-3-deploy dev           # + Varnish HTTP cache
make step-4-deploy dev           # + RabbitMQ + consumer workers + backup CronJobs
```

Apply-only (no build): `make step-1 dev`, `make step-2 dev`, etc.

### Production-Style Deploy

```bash
make deploy dev                  # Auto-detect zero-downtime vs maintenance mode
make deploy-zero dev             # Force rolling update
make deploy-maintenance dev      # Force maintenance mode (scales down, upgrades, scales up)
make deploy-only dev             # Deploy existing image (skip build)
```

### Monitoring & Logging

```bash
make monitoring                  # Prometheus + Grafana
make monitoring-kibana           # Elasticsearch + Fluent Bit + Kibana
make logging-loki                # Loki + Promtail
```

### Services Dashboard

```bash
make services dev              # Generate static HTML with all URLs/credentials
make services-server           # Deploy live dashboard pod (cleanup on Ctrl+C)
```

### Backup & Restore

```bash
make backup dev                  # Trigger DB + media backup now
make backup-list dev             # List available backups
make restore-db dev BACKUP_NAME=db-20260328-020000.sql.gz
```

### Teardown

```bash
make destroy dev                 # Delete app + PVCs for one environment
make destroy-everything          # Remove all environments + monitoring + cluster deps
```

### CI (GitHub Actions)

CI runs `skaffold build` → `skaffold run` → `skaffold verify` (Cypress e2e) across K8s v1.27.3, v1.28.0, v1.29.0 using KIND clusters. The walkthrough workflow tests step-1 through step-3 sequentially on PRs.

### E2E Tests

Tests live in `test/e2e/` using Cypress + Cucumber. The single test scenario runs a full checkout flow (product page → add to cart → shipping → payment → success page). Tests run inside the cluster via `skaffold verify`.

## Architecture

### Kustomize Layout

```
deploy/
├── bases/           # 9 independent components (app, database, elasticsearch, redis,
│                    #   rabbitmq, varnish, backup, consumer, monitoring, services)
├── walkthrough/     # Progressive steps: step-1 → step-2 → step-3 → step-4
│                    #   Each step references the previous + adds a base
├── overlays/        # Environment configs (production, staging, test, kind)
│                    #   Customize via namespace, patches, configMapGenerator merge
└── deploy-envs/     # Thin wrappers for deploy.sh (removes install job for re-deploys)
                     #   Install job is immutable — must be deleted before re-creation
```

Steps compose progressively: step-1 (app+db+es) → step-2 (+redis+HPA) → step-3 (+varnish, ingress rerouted) → step-4 (+rabbitmq+cron-driven consumers+backups). All overlays build on step-4. The dedicated `magento-consumer` Deployment base ships with step-4 but is **commented out by default** — queue consumers run from `magento-cron` via `cron_consumers_runner`. To switch to the persistent-worker model, uncomment `../../bases/consumer` in `deploy/walkthrough/step-4/kustomization.yaml`, uncomment the matching patch lines in the overlays, and flip `CRON_CONSUMERS_RUNNER` to `false` in `additional.env`.

The `redis` base ships **three separate StatefulSets** — `redis-cache` (default cache, ephemeral, LRU 512mb), `redis-page-cache` (FPC, ephemeral, LRU 1024mb), `redis-sessions` (sessions, `VolumeClaimTemplate` 1Gi + AOF persistence, `noeviction`). All three carry label `app: redis` with an additional `role: cache|page-cache|sessions` label. Magento reads three independent env-var groups (`REDIS_CACHE_*`, `REDIS_FPC_*`, `REDIS_SESSION_*`) via `src/app/etc/env.docker.php` — each points at its own Service. `bin/magento cache:flush` only touches `redis-cache`; FPC survives.

### Container Architecture

The `magento-web` pod runs 3 containers + 3 init containers:
- **Init:** `wait-for-db` (netcat), `wait-for-elasticsearch` (curl), `setup` (runs `setup:upgrade`/`app:config:import` if needed)
- **Main:** `magento-web` (Nginx + PHP-FPM via supervisord), `php-metrics-exporter`, `nginx-metrics-exporter`

The `magento-consumer` pod (step-4+, **opt-in**) runs 1 container + 2 init containers:
- **Init:** `wait-for-web` (curl health_check.php), `wait-for-rabbitmq` (netcat)
- **Main:** `magento-consumer` (starts all queue consumers via `queue:consumers:start` with `--max-messages` restart cycle)

When the dedicated pod is disabled (the default), `magento-cron` spawns consumers every cron tick, each running until `CRON_CONSUMERS_MAX_MESSAGES` messages or an empty queue (via `CONSUMERS_WAIT_FOR_MESSAGES=0`). `CRON_CONSUMERS_LIST` is empty in step-4 — Magento treats an empty list as *run every declared consumer*, so whatever `queue_consumer.xml` declarations the image ships (core + custom modules) are what runs. Curate per-env by overriding `CRON_CONSUMERS_LIST` (comma-separated) in an overlay's `additional.env` via `configMapGenerator` merge.

### Configuration Flow

Environment variables flow through layers (later overrides earlier):
1. Explicit `env:` (DB_HOST, DB credentials from secrets)
2. ConfigMap `config` (common.env: ES, URLs, cron, mode)
3. ConfigMap `additional` (step-specific: Redis, Varnish, AMQP — merged per step)
4. Secret `magento-admin` (admin credentials)

At runtime, `src/app/etc/env.docker.php` reads env vars via `getenv()` to build Magento's config array. Magento's `CONFIG__DEFAULT__*` pattern sets admin-locked values from env vars. `CRON_CONSUMERS_RUNNER` is tri-state: `true` (step-4 default) populates `cron_consumers_runner` with `cron_run=true`, `max_messages=$CRON_CONSUMERS_MAX_MESSAGES`, and `consumers=explode(',', $CRON_CONSUMERS_LIST)` so `magento-cron` spawns a curated subset; `false` writes an explicit disabled block and leaves spawning to the dedicated `magento-consumer` Deployment; unset leaves Magento's own default. `CONSUMERS_WAIT_FOR_MESSAGES=0` sets `queue.consumers_wait_for_messages` so any `queue:consumers:start` process — cron-spawned or Deployment-spawned — exits on an empty queue instead of polling indefinitely.

### Smart Deploy (`deploy/deploy.sh`)

Auto-detects strategy by running `setup:db:status` + `app:config:status` against the new image:
- Both exit 0 → **zero-downtime** rolling update
- Either non-zero → **maintenance mode** (scale down web+consumer → upgrade → scale up)

In maintenance mode, `deploy.sh` scales down both `magento-web` and `magento-consumer`, suspends `magento-cron`, applies new manifests, then waits for all rollouts.

### NetworkPolicies (zero-trust pod-to-pod)

Each base in `deploy/bases/<component>/networkpolicy.yaml` ships with its own NetworkPolicy, wired into the kustomization alongside the Deployment/StatefulSet. The model is default-deny plus explicit allows:

- **`default-deny-all`** (in `deploy/bases/app/networkpolicy.yaml`) — catch-all that denies all ingress and egress for every pod in the namespace unless another policy allows it.
- **Per-backend allow policies** — `allow-db`, `allow-redis`, `allow-rabbitmq`, `allow-elasticsearch` permit ingress only from magento pods labelled `app=magento,component=(web|cron|install|consumer)` (and `app=backup,component=db` for db-backup). `allow-redis` covers all three `redis-*` StatefulSets via the shared `app: redis` label; three per-role PodDisruptionBudgets (`redis-cache`, `redis-page-cache`, `redis-sessions`) prevent simultaneous eviction of sessions + FPC during node drains.
- **Edge & workload policies** — `allow-ingress-nginx` (external 80/443 + egress to varnish/web + kube-apiserver), `allow-varnish`, `allow-magento-web` (egress fans out to every backend), `allow-magento-cron`, `allow-magento-install`, `allow-magento-consumer`, `allow-db-backup`, `allow-media-backup`, `allow-secret-generator` (kube-apiserver egress for StringSecret CRD), and `allow-varnish` plus `allow-monitoring` where applicable.
- **Namespace isolation** — per-env backend and workload policies (`allow-db`, `allow-redis`, `allow-rabbitmq`, `allow-elasticsearch`, `allow-magento-*`) use `podSelector` without a `namespaceSelector`, so a pod in `staging` cannot reach `db.production.svc.cluster.local:3306` even if it carries allowed labels. Each env's data plane is network-isolated.
- **Cluster-global edge exception** — the ingress controller is installed cluster-wide (runs in `default`) but must reach varnish/magento-web in every env namespace. So `allow-ingress-nginx`'s egress to varnish/magento-web and `allow-varnish`'s ingress from the controller both use `namespaceSelector: {}` alongside the `app.kubernetes.io/instance: ingress-nginx` selector. Any future cluster-global component (e.g. a webhook that must talk into every env) follows the same pattern: keep tenant-isolating backend rules strict, and carve out explicit cross-namespace exceptions only at the edge.
- **DNS** — every policy includes an explicit egress to `kube-system`/`k8s-app=kube-dns` on UDP+TCP 53. Adding a new component requires this egress or the pod loses name resolution.

**Requires a CNI that enforces NetworkPolicies** (Calico, Cilium). Minikube's default bridge CNI silently ignores them — `make minikube` passes `--cni=calico`.

When adding a new pod or service: give it a distinct label, create an allow-policy for its ingress, and add explicit egress rules for every backend it talks to (plus kube-dns). A pod with no matching allow-policy is fully isolated by `default-deny-all`.

### Secrets

Auto-generated by mittwald/kubernetes-secret-generator (`StringSecret` CRD). Credentials for database, admin, RabbitMQ, and services dashboard are generated on first apply with `forceRegenerate: false`.

### Image Build

Multi-stage Dockerfile in `src/Dockerfile`: `base` (PHP 8.2-fpm + extensions + Nginx) → `build` (Composer install) → `app` (production: DI compile, static deploy, opcache). Image tagged with git short SHA; appends `-dirty` if there are uncommitted changes.

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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
make minikube                    # Start local cluster (K8s v1.24.0, 4 CPU, 16GB)
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
make step-4-deploy dev           # + RabbitMQ + backup CronJobs
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
├── bases/           # 8 independent components (app, database, elasticsearch, redis,
│                    #   rabbitmq, varnish, backup, monitoring, services)
├── walkthrough/     # Progressive steps: step-1 → step-2 → step-3 → step-4
│                    #   Each step references the previous + adds a base
├── overlays/        # Environment configs (production, staging, test, kind)
│                    #   Customize via namespace, patches, configMapGenerator merge
└── deploy-envs/     # Thin wrappers for deploy.sh (removes install job for re-deploys)
                     #   Install job is immutable — must be deleted before re-creation
```

Steps compose progressively: step-1 (app+db+es) → step-2 (+redis+HPA) → step-3 (+varnish, ingress rerouted) → step-4 (+rabbitmq+backups). All overlays build on step-4.

### Container Architecture

The `magento-web` pod runs 3 containers + 3 init containers:
- **Init:** `wait-for-db` (netcat), `wait-for-elasticsearch` (curl), `setup` (runs `setup:upgrade`/`app:config:import` if needed)
- **Main:** `magento-web` (Nginx + PHP-FPM via supervisord), `php-metrics-exporter`, `nginx-metrics-exporter`

### Configuration Flow

Environment variables flow through layers (later overrides earlier):
1. Explicit `env:` (DB_HOST, DB credentials from secrets)
2. ConfigMap `config` (common.env: ES, URLs, cron, mode)
3. ConfigMap `additional` (step-specific: Redis, Varnish, AMQP — merged per step)
4. Secret `magento-admin` (admin credentials)

At runtime, `src/app/etc/env.docker.php` reads env vars via `getenv()` to build Magento's config array. Magento's `CONFIG__DEFAULT__*` pattern sets admin-locked values from env vars.

### Smart Deploy (`deploy/deploy.sh`)

Auto-detects strategy by running `setup:db:status` + `app:config:status` against the new image:
- Both exit 0 → **zero-downtime** rolling update
- Either non-zero → **maintenance mode** (scale down → upgrade → scale up)

### Secrets

Auto-generated by mittwald/kubernetes-secret-generator (`StringSecret` CRD). Credentials for database, admin, RabbitMQ, and services dashboard are generated on first apply with `forceRegenerate: false`.

### Image Build

Multi-stage Dockerfile in `src/Dockerfile`: `base` (PHP 8.2-fpm + extensions + Nginx) → `build` (Composer install) → `app` (production: DI compile, static deploy, opcache). Image tagged with git short SHA; appends `-dirty` if there are uncommitted changes.

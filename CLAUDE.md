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
make deploy-status dev           # One-shot deploy classifier; exit 0=HEALTHY, 1=FAILED, 2=IN PROGRESS, 3=NOT DEPLOYED
make deploy-status all           # Worst-of-three across dev/staging/production (CI-gate-friendly)
make deploy-watch dev            # Auto-refreshing variant; exits after 3 consecutive HEALTHY ticks
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
├── bases/           # 12 independent components (app, database, elasticsearch, opensearch,
│                    #   redis, rabbitmq, varnish, backup, consumer, monitoring, services,
│                    #   imgproxy)
│                    #   (`elasticsearch` and `opensearch` are a toggle pair — exactly one
│                    #   is referenced from `step-1/kustomization.yaml` at a time)
├── components/      # Kustomize Components (mix-ins). resource-limits-added toggles
│                    #   the cpu-limit additions on db/rabbitmq/varnish. proxysql adds
│                    #   read replicas + ProxySQL. imgproxy routes catalog product images
│                    #   through on-the-fly transcoding (off in dev/staging, on in production).
├── walkthrough/     # Progressive steps: step-1 → step-2 → step-3 → step-4
│                    #   Each step references the previous + adds a base
├── overlays/        # Environment configs (production, staging, test, kind)
│                    #   Customize via namespace, patches, configMapGenerator merge
└── deploy-envs/     # Thin wrappers for deploy.sh (removes install job for re-deploys)
                     #   Install job is immutable — must be deleted before re-creation
```

Steps compose progressively: step-1 (app+db+es) → step-2 (+redis+HPA) → step-3 (+varnish, ingress rerouted) → step-4 (+rabbitmq+cron-driven consumers+backups). All overlays build on step-4. The dedicated `magento-consumer` Deployment base ships with step-4 but is **commented out by default** — queue consumers run from `magento-cron` via `cron_consumers_runner`. To switch to the persistent-worker model, uncomment `../../bases/consumer` in `deploy/walkthrough/step-4/kustomization.yaml`, uncomment the matching patch lines in the overlays, and flip `CRON_CONSUMERS_RUNNER` to `false` in `additional.env`.

The `redis` base ships **three separate StatefulSets** — `redis-cache` (default cache, ephemeral, LRU 512mb), `redis-page-cache` (FPC, ephemeral, LRU 1024mb), `redis-sessions` (sessions, `VolumeClaimTemplate` 1Gi + AOF persistence, `noeviction`). All three carry label `app: redis` with an additional `role: cache|page-cache|sessions` label. Magento reads three independent env-var groups (`REDIS_CACHE_*`, `REDIS_FPC_*`, `REDIS_SESSION_*`) via `src/app/etc/env.docker.php` — each points at its own Service. `bin/magento cache:flush` only touches `redis-cache`; FPC survives.

`deploy/components/` holds Kustomize Components — mix-ins attached via a `components:` entry in a parent kustomization. `resource-limits-added` (wired into `deploy/walkthrough/step-4/kustomization.yaml`) re-applies the cpu limit on `db` + `rabbitmq` and the full `limits:` block on `varnish`. Those three fields are **not inline** in the base manifests; they exist only when the Component's `patches:` block is active. Commenting it out reverts those three containers to the pre-initiative ("Partial") state on step-4 and every overlay that inherits step-4 (`staging`, `production`); step-1/2/3 standalone builds and the `kind`/`test` overlays never include the Component, so they always render without those added limits.

### Container Architecture

The `magento-web` pod runs 3 containers + 3 init containers:
- **Init:** `wait-for-db` (netcat), `wait-for-search` (curl — polls the active search backend; OpenSearch by default, ES if toggled), `setup` (runs `setup:upgrade`/`app:config:import` if needed)
- **Main:** `magento-web` (Nginx + PHP-FPM via supervisord), `php-metrics-exporter`, `nginx-metrics-exporter`

The `magento-consumer` pod (step-4+, **opt-in**) runs 1 container + 2 init containers:
- **Init:** `wait-for-web` (curl health_check.php), `wait-for-rabbitmq` (netcat)
- **Main:** `magento-consumer` (starts all queue consumers via `queue:consumers:start` with `--max-messages` restart cycle)

When the dedicated pod is disabled (the default), `magento-cron` spawns consumers every cron tick, each running until `CRON_CONSUMERS_MAX_MESSAGES` messages or an empty queue (via `CONSUMERS_WAIT_FOR_MESSAGES=0`). `CRON_CONSUMERS_LIST` is empty in step-4 — Magento treats an empty list as *run every declared consumer*, so whatever `queue_consumer.xml` declarations the image ships (core + custom modules) are what runs. Curate per-env by overriding `CRON_CONSUMERS_LIST` (comma-separated) in an overlay's `additional.env` via `configMapGenerator` merge.

### Autoscaling (HPA)

Step-2 adds `deploy/walkthrough/step-2/hpa/magento-web.yaml` — a CPU-utilization HPA on `magento-web` with `averageUtilization: 75`, base range `1–5` replicas. The `production` overlay patches it to `3–10`; staging inherits the step-2 defaults. Because the HPA computes utilization as a percentage of `requests.cpu`, any edit that strips `requests.cpu` from the `magento-web` container breaks autoscaling — `kubectl get hpa` reports `<unknown>/75%` and no scale events fire. No other workload is autoscaled.

### PodDisruptionBudgets

Every workload base ships a PDB alongside its Deployment/StatefulSet: `magento-web`, `magento-consumer`, `db`, `elasticsearch`, `rabbitmq`, `varnish`, plus three per-role PDBs for `redis-cache` / `redis-page-cache` / `redis-sessions`. They block voluntary disruptions (node drains, cluster upgrades) from evicting all replicas at once, and the three Redis PDBs specifically prevent simultaneous eviction of sessions + FPC during node drains. Adding a new workload requires a PDB entry — otherwise a drain can evict its only replica.

### Backup System

Step-4 adds two CronJobs in `deploy/bases/backup/`: `db-backup` (daily 02:00 UTC, active) and `media-backup` (daily 03:00 UTC, `suspend: true` by default — enable with `kubectl patch cronjob media-backup -p '{"spec":{"suspend":false}}'`). Both keep the last `BACKUP_RETENTION=7` artifacts and write to a shared `backup` PVC (`ReadWriteOnce`). `make backup` / `make backup-db` / `make backup-media` trigger on-demand Jobs from the CronJob spec; `make backup-list` and `make restore-db BACKUP_NAME=…` work against the same PVC. The services dashboard mounts the PVC read-only for its backup-management UI — never run dashboard pods concurrently with active backup Jobs on different nodes (RWO collision).

### Monitoring Stack

Three stacks ship as separate Makefile targets and are **not part of the walkthrough** (each installs into its own namespace or uses Helm releases directly):

- `make monitoring` — kube-prometheus-stack (Prometheus + Grafana). `deploy/bases/monitoring/servicemonitor.yaml` scrapes the PHP-FPM and Nginx exporters in `magento-web`; `prometheusrule.yaml` carries 9 alerts (pod restarts/unavailable, PHP-FPM saturation/slow requests/down, Nginx error rate/down, cron failures). Three Grafana dashboards (Magento Overview / PHP-FPM / Nginx) are auto-provisioned from `deploy/bases/monitoring/dashboards/`.
- `make monitoring-kibana` — ECK-operator Elasticsearch + Fluent Bit tail of container logs + Kibana for log exploration. Index pattern: `logstash-*`.
- `make logging-loki` — Loki + Promtail. `make monitoring-loki-datasource` wires Loki into the Grafana from the first stack.

### Services Dashboard

`deploy/bases/services/` is a **standalone kustomization** — not referenced from any walkthrough step. `make services-server` builds it directly and deploys a `services-dashboard` pod with three containers: `nginx` (serves `index.html` + `backups.html` behind basic-auth from `services-dashboard-credentials`), `collector` (kubectl-based sidecar polling cluster state + parsing the backup PVC), and `api` (busybox endpoint for the HTML pages). A ServiceAccount with a read-only ClusterRole over workloads/pods plus a namespaced Role to trigger backup Jobs is shipped alongside. The pod mounts the `backup` PVC read-only; if a backup Job is running on a different node, pod scheduling will fail on the RWO constraint.

### Configuration Flow

Environment variables flow through layers (later overrides earlier):
1. Explicit `env:` (DB_HOST, DB credentials from secrets)
2. ConfigMap `config` (common.env: ES, URLs, cron, mode)
3. ConfigMap `additional` (step-specific: Redis, Varnish, AMQP — merged per step)
4. Secret `magento-admin` (admin credentials)

At runtime, `src/app/etc/env.docker.php` reads env vars via `getenv()` to build Magento's config array. Magento's `CONFIG__DEFAULT__*` pattern sets admin-locked values from env vars. Search-engine config flows through `CONFIG__DEFAULT__CATALOG__SEARCH__OPENSEARCH_SERVER_*` / `ENGINE=opensearch` env vars via `app:config:import` (writes to `app/etc/config.php`, not `env.php`); `src/app/etc/env.docker.php` does not carry search config. `CRON_CONSUMERS_RUNNER` is tri-state: `true` (step-4 default) populates `cron_consumers_runner` with `cron_run=true`, `max_messages=$CRON_CONSUMERS_MAX_MESSAGES`, and `consumers=explode(',', $CRON_CONSUMERS_LIST)` so `magento-cron` spawns a curated subset; `false` writes an explicit disabled block and leaves spawning to the dedicated `magento-consumer` Deployment; unset leaves Magento's own default. `CONSUMERS_WAIT_FOR_MESSAGES=0` sets `queue.consumers_wait_for_messages` so any `queue:consumers:start` process — cron-spawned or Deployment-spawned — exits on an empty queue instead of polling indefinitely.

### Database read replicas (opt-in via `deploy/components/proxysql/`)

Off by default; **on in `deploy/overlays/production`**. Enabling the component adds three things atomically: a 2-replica MySQL async-GTID replica StatefulSet (`db-replica`), a 2-replica ProxySQL Cluster StatefulSet (`proxysql`) doing read/write split, and a Service swap. The `db` Service's selector is patched to `app: proxysql` with `targetPort: 6033` — Magento's existing `DB_HOST=db` env var transparently routes through ProxySQL with no application-side changes. A new `db-primary` Service (selector `app: db`, port 3306) is added for primary-only work; the `db-backup` CronJob is auto-repointed at it because `mysqldump --master-data=2` needs deterministic GTID positions. **Operator-habit gotcha**: `db.<ns>` no longer resolves to the primary — runbooks doing `kubectl exec ... -- mysql -h db ...` for `SHOW MASTER STATUS` etc. must switch to `db-primary.<ns>`. **Schema-migration paths bypass ProxySQL by construction**: the component patches `Job/magento-install`'s `magento-setup` container and `Deployment/magento-web`'s `setup` init container to `DB_HOST=db-primary`, because `setup:install`/`setup:upgrade` mix DDL + `LOCK TABLES` + post-DDL verification SELECTs on the same connection — through ProxySQL the verification SELECT matches rule 50 (→ hg=10) while the session is locked to hg=0 by the DDL, raising error 9006. `transaction_persistent=1` doesn't cover this (it only handles explicit `BEGIN`/`COMMIT`, not lock-induced session pinning). The web pod's *main* container intentionally stays on `DB_HOST=db` so live traffic still gets read splitting; only the migration paths (install Job, setup init container, db-backup CronJob) are repointed. Replicas are bootstrapped via the MySQL 8.0 CLONE plugin (donor user `clone_user@%` granted `BACKUP_ADMIN`, set up by the one-shot `db-primary-bootstrap` Job that also creates `replica_user` and `monitor`); the bootstrap deliberately omits `INSTALL PLUGIN clone` because `plugin_load_add = mysql_clone.so` in the patched `mycnf` ConfigMap loads it on every start. Read-after-write is handled by `mysql_query_rules` 30–33 pinning SELECTs against `quote*`/`sales_*`/`checkout_*`/`customer_(entity|address_entity|grid_flat)` to hostgroup 0, plus `transaction_persistent=1` and `mysql-monitor_writer_is_also_reader=1` (so reads degrade to primary if all replicas exceed `max_replication_lag=30` simultaneously). Magento's `mysql_users` row in ProxySQL is populated by a manual `proxysql-users-reload-template` Job (run on first deploy and after `database-credentials` rotation) — until that Job runs, frontend connections error with "User has no rules to access this hostgroup". **Cut-over deploy must run as `make deploy-maintenance prod`**: `deploy.sh`'s `setup:db:status` / `app:config:status` checks both return 0 (Service swaps and `my.cnf` deltas don't affect schema status), so it would pick zero-downtime by default and produce a 2–10 min mixed-routing window where some PHP-FPM workers still hold direct-MySQL connections. **Binlog disk caveat**: enabling `log_bin` on the primary writes binlogs to its 10 GiB PVC; `binlog_expire_logs_seconds=604800` keeps 7 days, which can be multi-GiB/day under heavy writes — raise the primary PVC to 20–50 GiB in `deploy/overlays/production/patches/database.yaml` before binlogs ever fill the volume. Component composes cleanly with `resource-limits-added` (the only other Component) — both are `kind: Component` and stack via the same `components:` field. See `deploy/components/proxysql/README.md` for opt-in steps, query-rule tuning from `stats_mysql_query_digest`, the manual reconcile command, and rotation procedure.

### imgproxy on-the-fly image optimization (toggle via `deploy/components/imgproxy/`)

Off by default in dev and staging; **on in `deploy/overlays/production`**. Enabling the component adds an `imgproxy` Deployment (image: `darthsim/imgproxy:v3.27`), ClusterIP Service on port 8080, NetworkPolicy, PDB (`minAvailable: 1`), and HPA (base 1–5 replicas, CPU 75%). It also replaces the `nginx` ConfigMap in magento-web with a version that proxies `/media/catalog/product/...` requests through imgproxy for in-memory WebP/AVIF transcode (`IMGPROXY_AUTO_WEBP=true`, `IMGPROXY_AUTO_AVIF=true`, `IMGPROXY_QUALITY=85`). Routes not in that path (`/media/wysiwyg/`, `/static/`, theme assets, favicon) continue serving directly via `try_files`.

**Toggle is one comment line per env** (kind and test overlays never see the toggle because they reference step-3, not step-4):
1. `deploy/walkthrough/step-4/kustomization.yaml` — `# - ../../components/imgproxy` (commented; off in dev).
2. `deploy/overlays/staging/kustomization.yaml` — `# - ../../components/imgproxy` (commented; off in staging).
3. `deploy/overlays/production/kustomization.yaml` — `- ../../components/imgproxy` (uncommented; on in production).

**PVC mount + RWO co-scheduling**: imgproxy mounts the existing `media` PVC read-only at `/local/media`; `IMGPROXY_LOCAL_FILESYSTEM_ROOT=/local` maps imgproxy URLs of the form `/unsafe/plain/local:///media/catalog/product/<path>` to files on that mount. Because the media PVC is `ReadWriteOnce`, a second RWO mount on a different node is refused by the CSI driver. imgproxy therefore carries a `podAffinity` with `requiredDuringSchedulingIgnoredDuringExecution` on `app=magento,component=web` so the scheduler always co-locates imgproxy on the same node as magento-web (the node that already holds the PVC binding). Once the S3 media TODO lands, the podAffinity and the PVC mount are removed in the same PR.

**Signing-deferred threat model**: `IMGPROXY_ALLOW_INSECURE=true` is set intentionally — nginx's `proxy_pass` generates unsigned URLs and imgproxy rejects them unless this flag is set. The security boundary is the ClusterIP Service (unreachable from outside the cluster) plus the `allow-imgproxy` NetworkPolicy that restricts ingress to pods with `app=magento,component=web` on port 8080. No URL signing key (`IMGPROXY_KEY` / `IMGPROXY_SALT`) is configured. Future hardening: a Magento-side custom module that rewrites `<img src>` to include an HMAC signature, after which `IMGPROXY_ALLOW_INSECURE` can be removed.

**nginx ConfigMap drift invariant**: the component ships `deploy/components/imgproxy/patches/nginx-magento2.conf` — a full copy of the base `deploy/bases/app/config/nginx/magento2.conf` with the imgproxy location blocks prepended. `configMapGenerator: behavior: replace` swaps the whole ConfigMap when the component is active. **Any PR that edits `deploy/bases/app/config/nginx/magento2.conf` MUST also update `deploy/components/imgproxy/patches/nginx-magento2.conf` in the same commit**, or imgproxy-enabled deployments silently diverge from the base nginx config (missing location fixes, header changes, etc.).

**NetworkPolicy egress-list stacking invariant**: Kustomize's strategic-merge on `egress:` lists in NetworkPolicy is a full replacement (no merge key), so when both `proxysql` and `imgproxy` components are active (production), only the **last** component's egress patch on `allow-magento-web` survives. imgproxy must be declared **after** proxysql in the `components:` list and imgproxy's `allow-magento-web` egress patch MUST be a superset — it includes both the `proxysql:6033` rule (from the proxysql component) AND the `imgproxy:8080` rule. **Adding a new backend that magento-web must reach requires updating both component egress patches in the same commit**, or the last-patch wins and the earlier rules are silently dropped.

**Cache-path normalization**: Magento's HTML emits product image URLs as `/media/catalog/product/cache/<hash>/<a>/<b>/<file>.jpg` — pointing at a pre-resized lossy file Magento generated on catalog save. nginx strips the `cache/<hash>/` segment in the `proxy_pass` URL so imgproxy reads the original at `/local/media/catalog/product/<a>/<b>/<file>.jpg`. Without this strip, imgproxy would re-encode an already-lossy image and quality would degrade with no size benefit. A second location block handles the rare direct-original path (`/media/catalog/product/<a>/<b>/<file>.jpg` without a cache prefix) via a negative lookahead `(?!cache/)`.

**Production HPA bounds**: the production overlay patches the imgproxy HPA to `minReplicas: 2 / maxReplicas: 10` via `deploy/overlays/production/patches/imgproxy-hpa.yaml`. The base HPA (in `deploy/bases/imgproxy/`) defaults to 1–5. Staging inherits the base defaults. Production min of 2 avoids a cold-start stall on the first transcode burst after a deploy.

**Cut-over deploy caveat**: enabling imgproxy in production for the first time changes the `nginx` ConfigMap hash → magento-web's pod-template hash changes → rolling update of magento-web. With `maxSurge: 50%` and the media PVC bound as RWO to one node, the surge replica may fail to bind the PVC on a different node and stall. `deploy.sh` auto-detects zero-downtime (no schema change, no `app:config` change), but **first-enable MUST run as `make deploy-maintenance prod`** to avoid a stalled rolling surge. Subsequent deploys that do not touch the nginx ConfigMap do not re-roll magento-web and `make deploy prod` (zero-downtime) is fine.

**Fallback on imgproxy 5xx**: both imgproxy location blocks carry `proxy_intercept_errors on` + `error_page 502 503 504 = /get.php$is_args$args`. On any imgproxy outage or 5xx, nginx re-issues the request to `get.php` — the same PHP fallback path the base `/media/` location uses for missing files. Magento's `get.php` falls back to the original image on disk (possibly from its own pre-resize cache), so users see the original image rather than a 502 error page.

### Search engine (toggle between `deploy/bases/opensearch/` and `deploy/bases/elasticsearch/`)

Default: **OpenSearch 2.19.5** (`opensearchproject/opensearch:2.19.5`), pod label `app: opensearch`, Service `opensearch:9200`. Fallback: Elasticsearch 7.17.28, pod label `app: elasticsearch`, Service `elasticsearch:9200` — kept in `deploy/bases/elasticsearch/` (unchanged) for operators who need the ES licensing model or cannot migrate.

**Toggle is three comment swaps** (no NP edits needed — all NetworkPolicies in `bases/app/`, `bases/consumer/`, and `components/proxysql/patches/` allow egress to both labels simultaneously):
1. `deploy/walkthrough/step-1/kustomization.yaml` — activate `../../bases/opensearch` or `../../bases/elasticsearch`.
2. `deploy/bases/app/config/common.env` — swap the active env-var trio (OpenSearch: `OPENSEARCH_SERVER_HOSTNAME`/`_PORT`/`ENGINE=opensearch`; ES7: `ELASTICSEARCH7_SERVER_HOSTNAME`/`_PORT`/`ENGINE=elasticsearch7`).
3. `deploy/bases/app/magento-web.yaml` and `deploy/bases/app/jobs/install.yaml` — the `wait-for-search` init container's `args` interpolate the hostname/port var by name; update the interpolation to match the active trio.

`deploy-status.sh` detects whichever StatefulSet (`opensearch` or `elasticsearch`) is present — no changes needed on toggle. The services dashboard is equally engine-aware.

**Existing-data caveat**: `app:config:import` does not overwrite existing `core_config_data` rows. On a populated cluster, run `php bin/magento config:set catalog/search/engine opensearch` (and matching hostname/port keys) after toggling, or destroy + redeploy. See README "Search engine toggle" section.

**Security**: both bases run with security/X-Pack disabled (internal-only cluster). OpenSearch uses `DISABLE_SECURITY_PLUGIN=true` **alone** — the container entrypoint translates that into `-Eplugins.security.disabled=true`, so setting the same key as a separate env var (e.g. `name: plugins.security.disabled`) trips `setting [plugins.security.disabled] already set, saw [true] and [true]` and the pod CrashLoops. ES uses `xpack.security.enabled=false`.

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

Auto-generated by mittwald/kubernetes-secret-generator (`StringSecret` CRD). Credentials for database, admin, RabbitMQ, and services dashboard are generated on first apply with `forceRegenerate: false`. `make destroy` deletes the `StringSecret` CRs; the underlying `Secret` objects normally get GC'd via owner references, but if any linger after destroy (`kubectl -n <env> get secret …-credentials`), delete them manually before re-deploying — otherwise the new `StringSecret` reuses the old random password and any downstream rows that need to match (notably ProxySQL's `mysql_users` row, populated by the `proxysql-users-reload-template` Job) silently drift out of sync.

### Image Build

Multi-stage Dockerfile in `src/Dockerfile`: `base` (PHP 8.2-fpm + extensions + Nginx) → `build` (Composer install) → `app` (production: DI compile, static deploy, opcache). Image tagged with git short SHA; appends `-dirty` if there are uncommitted changes.

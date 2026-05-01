# ProxySQL + MySQL read replicas (opt-in component)

## What it ships

- **2 ProxySQL pods** (`StatefulSet/proxysql`) in cluster mode (no SPOF). Configured for read/write split, connection multiplexing, lag-aware routing.
- **2 MySQL replicas** (`StatefulSet/db-replica`) — Percona 8.0, async GTID-based, bootstrapped from the primary via the MySQL 8.0 CLONE plugin.
- **A new `db-primary` Service** that selects the primary StatefulSet pods directly. Used by the backup CronJob and operators for primary-only work.
- **A patched `db` Service** — selector swapped to `app: proxysql`, targetPort `6033`. Magento's existing `DB_HOST=db` transparently routes through ProxySQL.
- **A one-shot bootstrap Job** that creates `replica_user`, `clone_user`, and `monitor` on the primary.
- **A manual users-reload Job template** for re-syncing the Magento DB user into ProxySQL after credential rotation.

## How to enable

Already enabled in `deploy/overlays/production/kustomization.yaml`:

```yaml
components:
- ../../components/proxysql
```

To enable in another overlay (staging/dev/test), add the same line. Footprint: ~2 GiB extra memory (2 ProxySQL + 2 replicas), ~25 GiB extra disk (2 × 10 GiB replica PVCs + binlog growth on primary). Not recommended on minikube unless `--memory 24g` or higher.

## First-time apply

The first apply enables binlogs/GTID on the primary and triggers a one-time rolling restart (~30–60 s blip). Run it as a maintenance-mode deploy:

```bash
make deploy-maintenance prod
```

`deploy.sh`'s auto-detection (`setup:db:status` + `app:config:status`) does **not** notice Service-selector swaps or `my.cnf` changes — both checks return 0 and it would pick zero-downtime by default. A rolling deploy here produces a 2–10 minute window where existing PHP-FPM workers retain direct-to-MySQL connections while new workers go through ProxySQL — functional but mixed routing, harder to debug if anything fails. Maintenance mode (`deploy.sh` scales web+consumer to 0, suspends cron, applies, scales back up) gives a clean cut-over. After the first cut-over, normal `make deploy prod` is fine — no further forced restarts.

After the deploy:

```bash
# 1. Verify the primary picked up GTID/binlogs
kubectl exec sts/db -- mysql -uroot -p"$ROOT_PASS" -e "SHOW MASTER STATUS\G; SELECT @@gtid_mode, @@enforce_gtid_consistency, @@server_id;"

# 2. Wait for replicas to clone + start replicating (CLONE takes a few minutes)
kubectl rollout status sts/db-replica --timeout=10m

# 3. Confirm replication health on each replica
kubectl exec db-replica-0 -- mysql -uroot -p"$ROOT_PASS" -e "SHOW REPLICA STATUS\G" \
  | grep -E 'Replica_(IO|SQL)_Running|Seconds_Behind_Source'
# Expect: Replica_IO_Running: Yes, Replica_SQL_Running: Yes

# 4. Trigger the users-reload Job — first apply leaves mysql_users empty
kubectl -n production create job --from=job/proxysql-users-reload-template \
  proxysql-users-reload-$(date +%s)
kubectl -n production wait --for=condition=complete job/proxysql-users-reload-* --timeout=2m

# 5. Verify ProxySQL backend pool
kubectl exec proxysql-0 -- mysql -h127.0.0.1 -P6032 -uadmin -p"$ADMIN_PASSWORD" \
  -e "SELECT hostgroup_id, hostname, status FROM runtime_mysql_servers"
# Expect: hg=0 db-primary ONLINE; hg=10 lists both db-replica-* ONLINE.
# (mysql-monitor_writer_is_also_reader=1 affects the monitor module's lag
# check semantics — it does NOT auto-populate mysql_servers with the writer
# in the reader hostgroup. Lag-driven failover from hg=10 to hg=0 still
# works via the SHUNNED_REPLICATION_LAG path: when both replicas exceed
# max_replication_lag=30 simultaneously, ProxySQL falls back to the writer.)
```

Until step 4 runs, Magento connections through ProxySQL fail with "ProxySQL Error: User 'magento' has no rules to access this hostgroup". This is by design — the bootstrap config ships a placeholder; the real password comes from `database-credentials` via the manual Job so it's never embedded in a ConfigMap.

## Operator-habit gotcha

After this Component is enabled, `db.<ns>` resolves to ProxySQL, **not** to the primary. Anything that says "connect to `db`" — runbooks, `kubectl exec deploy/services-dashboard -- mysql -h db…`, ad-hoc `SHOW MASTER STATUS;` — now lands on ProxySQL with reader-hostgroup routing and might hit a replica. For schema mutations, binlog inspection, and any work that must hit the primary, use `db-primary.<ns>` explicitly:

```bash
kubectl exec deploy/some-pod -- mysql -h db-primary -uroot -p"$ROOT_PASS" \
  -e "SHOW MASTER STATUS\G"
```

Three manifests are auto-repointed at `db-primary` by the component:

- `db-backup` CronJob — `mysqldump` needs deterministic GTID positions.
- `magento-install` Job (the `magento-setup` container) — `setup:install` does DDL + `LOCK TABLES` + post-DDL verification SELECTs on the same connection.
- `magento-web`'s `setup` init container — `setup:upgrade` and `app:config:import` have the same lock-then-SELECT pattern.

For all three, routing through ProxySQL produces error 9006 ("connection is locked to hostgroup 0 but trying to reach hostgroup 10"): the DDL/`LOCK TABLES`/temp-table session pinning sticks the session to the writer, then a verification SELECT matches rule 50 and ProxySQL aborts instead of silently sticking. `transaction_persistent=1` only covers explicit `BEGIN`/`COMMIT`; it does not save lock-induced pinning. The fix is to bypass ProxySQL for schema work, which is what these patches do.

Everything else (live `magento-web` traffic, `magento-cron`, `magento-consumer`, the `wait-for-db` init containers) keeps `DB_HOST=db` and goes through ProxySQL — that's where the read-split actually pays off.

## Read-after-write: rule-based pinning

`mysql_query_rules` rules 30–33 in `proxysql/config/proxysql.cnf` pin SELECTs that touch `quote*`, `sales_*`, `checkout_*`, and `customer_(entity|address_entity|grid_flat)` to hostgroup 0 (writer). This catches autocommit INSERT-then-SELECT outside `BEGIN`/`COMMIT` — those would otherwise slip past `transaction_persistent=1` and read stale data from a lagging replica.

Inside transactions, `transaction_persistent=1` keeps the entire transaction on hostgroup 0 as a second line of defence.

To extend the pinning list after observing real traffic for ≥ 1 week:

```bash
kubectl exec proxysql-0 -- mysql -h127.0.0.1 -P6032 -uadmin -p"$ADMIN_PASSWORD" -e "
  SELECT hostgroup, digest_text, count_star
    FROM stats_mysql_query_digest
    ORDER BY count_star DESC
    LIMIT 50"
```

Look for SELECT digests on hostgroup 10 that touch tables you know are mutated by the same request (e.g., `inventory_*` if you're using MSI). Add a new `match_pattern` rule with an unused `rule_id` between 33 and 40, then redeploy the component (the ConfigMap hash changes and the StatefulSet rolls).

## Reconcile model

This component does **not** ship a scheduled config-reconcile CronJob. Two reasons:

1. **Human runtime tuning matters.** Adding/adjusting `mysql_query_rules` from `stats_mysql_query_digest` analysis is the explicit ongoing maintenance path. A scheduled reload would overwrite that tuning within an hour.
2. **Component re-apply is the natural reconcile point.** When the ConfigMap changes, kustomize's hash mechanism rolls the StatefulSet and the new pod boots from the updated config (the container starts ProxySQL with `--initial`).

For a manual reconcile after editing runtime tables on a single pod:

```bash
kubectl exec proxysql-0 -- mysql -h127.0.0.1 -P6032 -uadmin -p"$ADMIN_PASSWORD" -e "
  LOAD MYSQL SERVERS TO RUNTIME;
  LOAD MYSQL QUERY RULES TO RUNTIME;
  LOAD MYSQL USERS TO RUNTIME;
  SAVE MYSQL VARIABLES TO DISK;
  SAVE MYSQL SERVERS TO DISK;
  SAVE MYSQL QUERY RULES TO DISK;
  SAVE MYSQL USERS TO DISK;"
```

ProxySQL Cluster sync propagates to the other pod within `cluster_check_interval_ms=200` ms.

## Failure modes

| Symptom | Likely cause | Diagnostic |
|---|---|---|
| Magento can't connect via `db` | mysql_users table empty (first-deploy) | `kubectl create job --from=job/proxysql-users-reload-template ...` |
| `9006 ProxySQL Error: connection is locked to hostgroup 0 but trying to reach hostgroup 10` during `setup:install`/`setup:upgrade` | An ad-hoc workload running schema work is pointed at `db` instead of `db-primary` | Confirm the failing workload is one of the three auto-repointed manifests — if it's something else (custom Job, manual `kubectl exec ...`), set `DB_HOST=db-primary` for that path. The component already patches `magento-install`, `magento-web`'s `setup` init container, and `db-backup`. |
| Same 9006 from steady-state app traffic (not setup) | A digest hit rule 50 while the session was pinned by a write you don't have a rule for | `SELECT digest_text FROM stats_mysql_query_digest WHERE errors > 0` to find the table; add a `match_pattern` rule with an unused `rule_id` between 33 and 40 pinning it to `destination_hostgroup=0` |
| All backends marked OFFLINE | Monitor password mismatch | Verify `monitor-credentials` Secret has same value as the user on `db-primary` (the bootstrap Job creates `monitor@%` from this Secret — they should match by construction) |
| All hg=10 replicas SHUNNED_REPLICATION_LAG | One or both replicas stalled | `SHOW REPLICA STATUS\G` on each replica; `mysql-monitor_writer_is_also_reader=1` ensures reads still succeed (fall back to primary) |
| Replica crash-loops after cluster delete | StatefulSet PVC retains an old data dir from before CLONE | Delete the PVC: `kubectl delete pvc data-db-replica-N` then restart the pod — bootstrap-replica.sh re-runs CLONE |
| `INSTALL PLUGIN clone` errors on Job re-run | The Job tried to install the clone plugin, but `plugin_load_add` already loaded it | Already handled — bootstrap Job deliberately omits `INSTALL PLUGIN`. If you see this error, you've added it manually somewhere |

## Rotating the database-credentials Secret

```bash
# 1. Force regeneration on the primary's credentials
kubectl annotate secret database-credentials secretgenerator.mittwald.de/regenerate=true

# 2. Wait for the StringSecret operator to refresh
kubectl get secret database-credentials -o jsonpath='{.data.MYSQL_PASSWORD}' | base64 -d

# 3. Rotate the password on the primary's MySQL itself
kubectl exec sts/db -- mysql -uroot -p"$OLD_ROOT_PASS" -e "
  ALTER USER 'magento'@'%' IDENTIFIED BY '$NEW_PASS'"

# 4. Re-sync ProxySQL's mysql_users with the new password
kubectl create job --from=job/proxysql-users-reload-template \
  proxysql-users-reload-$(date +%s)

# 5. Roll Magento pods so they pick up the new Secret values
kubectl rollout restart deploy/magento-web sts/magento-cron deploy/magento-consumer
```

## Removing the component

To revert to single-primary topology:

1. Comment out `../../components/proxysql` in `deploy/overlays/production/kustomization.yaml`.
2. `make deploy-maintenance prod` — the Service swap reverses (`db` selector goes back to `app: db`, targetPort 3306).
3. The `db-primary` Service, `db-replica` StatefulSet, ProxySQL StatefulSet, and bootstrap Job are pruned by `kubectl apply --prune` (or manually deleted).
4. The primary's binlogs and GTID stay enabled — they're harmless extras. To revert `my.cnf` cleanly, the next deploy will pick up the base `my.cnf` again (since the component's `behavior: replace` is no longer active) and the ConfigMap hash flip will roll the primary one more time.
5. The `database-credentials` Secret is unaffected; Magento pods continue to use it directly against the primary.

## Do you actually need ProxySQL?

Worth asking before going live. ProxySQL earns its keep when:

- PHP-FPM connection saturation has been a real problem (the multiplexer is the main win).
- Read load exceeds what a single beefy primary can serve, even after Varnish + Redis FPC are tuned (the read split is the second win).
- You want lag-aware routing or to add/remove replicas without the app caring (the operational win).

If your current load comfortably fits in one Percona node and Varnish+Redis hit rates are healthy (>90% FPC, >95% Varnish on cacheable paths), introducing ProxySQL adds an admin surface, a SQLite admin DB, ProxySQL Cluster sync semantics, and a query-rule tuning chore — all of which are real ongoing costs. Plain Magento → primary, with `make monitoring` watching DB CPU and connections, is one fewer thing to operate.

The component is opt-in for this reason. Turning it on is a real choice; default-off keeps the simple case simple.

## Before going live (downstream-deployer checklist)

This repo ships a working *local-cluster* template. The defaults here are sized for development and low-stakes staging; production traffic on a real cluster needs the deployer to add several things that are intentionally out of scope for this repo:

| Concern | Default here | What real production needs |
|---|---|---|
| Primary PVC | 10 GiB | 50–100 GiB (binlogs at `binlog_expire_logs_seconds=604800` can eat multi-GiB/day). Bump in `deploy/overlays/production/patches/database.yaml`. |
| Replica PVCs | 10 GiB each | Match the primary's data-volume size budget — replicas hold the full dataset. |
| Backup destination | Single `backup` PVC inside the cluster | Offsite copy (S3 / Azure Blob / GCS) with KMS-at-rest, lifecycle/retention rules, and a *tested* restore drill. The cluster losing the backup PVC is otherwise total data loss. |
| Restore RTO | Untested | Run `make restore-db` against a non-prod namespace, place a test order, time it. Document the runbook. Repeat quarterly. |
| Primary failover | Manual (no controller) | Either accept manual failover with a written runbook + SLA window, or add MySQL InnoDB Cluster (Group Replication + Router) / `orchestrator` / a similar controller. **Choose explicitly — not choosing is the actual bug.** |
| Alerting | None on DB layer | Prometheus rules on `Seconds_Behind_Source`, `runtime_mysql_servers.status`, `stats_mysql_connection_pool.ConnUsed/ConnFree`, PVC fill ratio (`kubelet_volume_stats_used_bytes / capacity_bytes`). The kube-prometheus-stack from `make monitoring` is already wired for magento-web — extend with a ServiceMonitor for ProxySQL's stats interface. |
| Load test | None | k6/Locust against the cluster at expected peak × 1.5 for 30+ minutes, watching ProxySQL stats and replica lag throughout. Without numbers, "production ready" is a guess. |
| Multi-AZ | Single-zone (whatever your cluster is) | Spread primary, replicas, and ProxySQL pods across availability zones via topology-spread constraints or per-zone node pools. Async replication doesn't help against a single-zone outage if everything is in that zone. |
| TLS in-cluster | Plain TCP | Enable TLS on Percona + ProxySQL if your threat model includes node compromise or compliance requires encryption-in-transit on the cluster network. |
| Query-rule tuning | Rules 30–33 cover quote/sales/checkout/customer | Real Magento (especially with extensions) will surface read-after-write digests these rules don't catch. Schedule a recurring weekly review:`SELECT hostgroup, count_star, errors, substr(digest_text,1,80) FROM stats_mysql_query_digest WHERE errors > 0 OR (hostgroup = 0 AND digest_text LIKE 'SELECT%') ORDER BY count_star DESC LIMIT 50` Anything on hg=0 that isn't a write/transaction-locked is a candidate to move to hg=10; anything with `errors > 0` is a 9006 you haven't pinned yet. |
| `mysql_users` rotation | Manual (`proxysql-users-reload-template` Job) | Wire the reload to your secret-rotation pipeline so a `database-credentials` change automatically triggers the Job. Otherwise a forgotten reload silently breaks frontend connections. |
| Destroy cleanup | StringSecret CRs are deleted; the underlying Secrets are GC'd via owner-ref, but if the operator's GC fails they linger | After `make destroy`, verify `kubectl -n <env> get secret proxysql-credentials database-credentials monitor-credentials db-replica-credentials` returns NotFound. If any linger, delete manually before re-deploying — otherwise the new StringSecret reuses the old random password and ProxySQL's `mysql_users` row drifts out of sync with the primary. |

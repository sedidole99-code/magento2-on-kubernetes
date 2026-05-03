#!/usr/bin/env bash
# deploy/deploy-status.sh — report whether a Magento deploy is healthy, in
# progress, or broken. Read-only; never mutates cluster state.
#
# Usage:
#   deploy/deploy-status.sh <namespace>   # default | staging | production
#   deploy/deploy-status.sh all           # iterates default, staging, production
#
# Exit codes (worst across all envs in 'all' mode):
#   0  HEALTHY        deploy completed and pods are Ready
#   1  FAILED         install Job failed, pods crash-looping, or images won't pull
#   2  IN PROGRESS    install Job still running, or pods rolling
#   3  NOT DEPLOYED   namespace missing

set -uo pipefail

KUBECTL="${KUBECTL:-kubectl}"

# --- output helpers ---------------------------------------------------------
# Colors when stdout is a TTY, or FORCE_COLOR=1 (for `watch -c` and similar
# wrappers that pipe stdout but render ANSI back to the terminal).
if [[ "${FORCE_COLOR:-}" == "1" ]] \
   || { [[ -t 1 ]] && command -v tput >/dev/null 2>&1 \
        && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; }; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_DIM=$'\033[2m';  C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=; C_GRN=; C_YEL=; C_BLU=; C_DIM=; C_BLD=; C_RST=
fi
ok()   { printf "  ${C_GRN}✓${C_RST} %s\n" "$*"; }
work() { printf "  ${C_YEL}…${C_RST} %s\n" "$*"; }
bad()  { printf "  ${C_RED}✗${C_RST} %s\n" "$*"; }
note() { printf "    ${C_DIM}%s${C_RST}\n" "$*"; }

# kubectl jsonpath that always returns a string (empty -> default)
jp() {
  local ns=$1 kind=$2 name=$3 path=$4 default=${5:-}
  local out
  out=$($KUBECTL -n "$ns" get "$kind" "$name" -o jsonpath="$path" 2>/dev/null) || true
  echo "${out:-$default}"
}

# --- single-namespace status ------------------------------------------------
status_one() {
  local ns=$1
  local label
  case "$ns" in
    default)    label="dev" ;;
    staging)    label="stage" ;;
    production) label="prod" ;;
    *)          label="$ns" ;;
  esac

  printf "\n${C_BLD}[%s] namespace=%s${C_RST}\n" "$label" "$ns"

  if ! $KUBECTL get ns "$ns" >/dev/null 2>&1; then
    bad "namespace not found"
    note "no deploy has run, or 'make destroy $label' wiped it"
    printf "${C_BLD}→ %sNOT DEPLOYED%s${C_RST}\n" "$C_YEL" "$C_RST"
    return 3
  fi

  local has_proxysql=0
  $KUBECTL -n "$ns" get sts proxysql >/dev/null 2>&1 && has_proxysql=1

  local issues=0 in_progress=0

  # ---- pods in bad states ---------------------------------------------------
  # Capture name + reason for any container stuck in CrashLoopBackOff /
  # ImagePullBackOff / ErrImagePull / CreateContainerError / OOMKilled.
  local bad_pods
  bad_pods=$($KUBECTL -n "$ns" get pods --no-headers 2>/dev/null \
    | awk '$3 ~ /CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerError|OOMKilled|Error/ {print "    "$1" ("$3", restarts="$4")"}')
  if [[ -n "$bad_pods" ]]; then
    bad "pods in bad state:"
    echo "$bad_pods"
    issues=$((issues+1))
  fi

  # ---- magento-install Job --------------------------------------------------
  # The Job has ttlSecondsAfterFinished set, so on healthy deploys it gets
  # GC'd shortly after Complete. We treat "Job missing + magento-web Ready"
  # as evidence the install ran successfully and was reaped.
  if $KUBECTL -n "$ns" get job magento-install >/dev/null 2>&1; then
    local succ=$(jp "$ns" job magento-install '{.status.succeeded}' 0)
    local fail=$(jp "$ns" job magento-install '{.status.failed}'    0)
    local actv=$(jp "$ns" job magento-install '{.status.active}'    0)

    if [[ "$succ" == "1" ]]; then
      local dur=$(jp "$ns" job magento-install '{.status.completionTime}' )
      ok "magento-install: Complete${dur:+ ($dur)}"
    elif [[ "$fail" -gt 0 ]]; then
      bad "magento-install: FAILED ($fail pod(s))"
      note "logs:    $KUBECTL -n $ns logs job/magento-install -c magento-setup"
      note "events:  $KUBECTL -n $ns describe job/magento-install"
      issues=$((issues+1))
    elif [[ "$actv" -gt 0 ]]; then
      # Identify which step we're on — init container name, or last log line
      local pod
      pod=$($KUBECTL -n "$ns" get pod -l job-name=magento-install \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
      local step="starting"
      if [[ -n "$pod" ]]; then
        local init_running
        init_running=$($KUBECTL -n "$ns" get pod "$pod" \
          -o jsonpath='{.status.initContainerStatuses[?(@.state.running)].name}' 2>/dev/null) || true
        local main_running
        main_running=$($KUBECTL -n "$ns" get pod "$pod" \
          -o jsonpath='{.status.containerStatuses[?(@.state.running)].name}' 2>/dev/null) || true
        if [[ -n "$main_running" ]]; then
          step="installing schema + content"
        elif [[ -n "$init_running" ]]; then
          step="waiting on init: $init_running"
        fi
      fi
      work "magento-install: Running — $step"
      if [[ -n "$pod" && "$step" == "installing schema"* ]]; then
        local progress
        progress=$($KUBECTL -n "$ns" logs "$pod" -c magento-setup --tail=80 2>/dev/null \
          | grep -E 'Module |reindex|Total execution time|installation completed|Index mode|cache flushed' \
          | tail -1)
        [[ -n "$progress" ]] && note "$progress"
      fi
      in_progress=1
    else
      work "magento-install: state unknown (no active/succeeded/failed counters yet)"
      in_progress=1
    fi
  else
    # Job not in the cluster. Two possibilities: it never ran (real failure),
    # or it ran, completed, and got TTL-reaped. Distinguish via downstream
    # evidence: a Ready magento-web pod can only exist if the install Job
    # finished (its `setup` init container needs the schema). If web is also
    # not Ready, the install genuinely never ran.
    local web_ready=$(jp "$ns" deploy magento-web '{.status.readyReplicas}' 0)
    local web_desired=$(jp "$ns" deploy magento-web '{.spec.replicas}' 0)
    if [[ "$web_ready" -gt 0 && "$web_ready" == "$web_desired" ]]; then
      ok "magento-install: Complete (Job already TTL-reaped)"
    else
      bad "magento-install Job missing and magento-web is not Ready"
      note "deploy aborted before the install Job was applied — check 'kubectl apply' output"
      issues=$((issues+1))
    fi
  fi

  # ---- StatefulSets ---------------------------------------------------------
  local sts_expected=(db rabbitmq redis-cache redis-page-cache redis-sessions)
  [[ $has_proxysql == 1 ]] && sts_expected+=(db-replica proxysql)
  # Detect which search backend is deployed (opensearch default, elasticsearch alternate)
  local has_opensearch=0 has_elasticsearch_search=0
  $KUBECTL -n "$ns" get sts opensearch >/dev/null 2>&1 && has_opensearch=1 || true
  $KUBECTL -n "$ns" get sts elasticsearch >/dev/null 2>&1 && has_elasticsearch_search=1 || true
  if [[ $has_opensearch == 1 && $has_elasticsearch_search == 1 ]]; then
    note "both opensearch and elasticsearch StatefulSets present — exactly one is expected; check step-1/kustomization.yaml"
    sts_expected+=(opensearch elasticsearch)
  elif [[ $has_opensearch == 1 ]]; then
    sts_expected+=(opensearch)
  elif [[ $has_elasticsearch_search == 1 ]]; then
    sts_expected+=(elasticsearch)
  else
    note "search backend StatefulSet not found in namespace; expected opensearch (default) or elasticsearch (toggle)"
    sts_expected+=(opensearch)
  fi
  local s ready desired
  for s in "${sts_expected[@]}"; do
    if ! $KUBECTL -n "$ns" get sts "$s" >/dev/null 2>&1; then
      bad "StatefulSet/$s missing"
      issues=$((issues+1))
      continue
    fi
    ready=$(jp "$ns" sts "$s" '{.status.readyReplicas}' 0)
    desired=$(jp "$ns" sts "$s" '{.spec.replicas}' 0)
    if [[ "$ready" == "$desired" && "$ready" != "0" ]]; then
      ok "StatefulSet/$s: $ready/$desired Ready"
    else
      work "StatefulSet/$s: $ready/$desired Ready (rolling)"
      in_progress=1
    fi
  done

  # ---- Deployments ----------------------------------------------------------
  # magento-consumer is opt-in: only present if uncommented in the overlay or
  # walkthrough (cron-driven consumers are the default). Probe before adding.
  local d
  local deploys=(magento-web varnish)
  if $KUBECTL -n "$ns" get deploy magento-consumer >/dev/null 2>&1; then
    deploys+=(magento-consumer)
  fi
  if $KUBECTL -n "$ns" get deploy imgproxy >/dev/null 2>&1; then
    deploys+=(imgproxy)
  fi
  for d in "${deploys[@]}"; do
    if ! $KUBECTL -n "$ns" get deploy "$d" >/dev/null 2>&1; then
      bad "Deployment/$d missing"
      issues=$((issues+1))
      continue
    fi
    ready=$(jp "$ns" deploy "$d" '{.status.readyReplicas}' 0)
    desired=$(jp "$ns" deploy "$d" '{.spec.replicas}' 0)
    if [[ "$ready" == "$desired" && "$ready" != "0" ]]; then
      ok "Deployment/$d: $ready/$desired Ready"
    else
      work "Deployment/$d: $ready/$desired Ready (rolling)"
      in_progress=1
    fi
  done

  # ---- ProxySQL component (prod) -------------------------------------------
  if [[ $has_proxysql == 1 ]]; then
    # Both Jobs have ttlSecondsAfterFinished and self-reap. Missing Job +
    # downstream evidence of success ⇒ treat as Complete (same heuristic
    # as magento-install above). For users-reload that evidence is a Ready
    # magento-web pod — its /health_check.php hits ProxySQL with the magento
    # user, so a Ready web pod proves users are loaded.
    if $KUBECTL -n "$ns" get job db-primary-bootstrap >/dev/null 2>&1; then
      local b_succ=$(jp "$ns" job db-primary-bootstrap '{.status.succeeded}' 0)
      local b_fail=$(jp "$ns" job db-primary-bootstrap '{.status.failed}'    0)
      if [[ "$b_succ" == "1" ]]; then
        ok "db-primary-bootstrap Job: Complete"
      elif [[ "$b_fail" -gt 0 ]]; then
        bad "db-primary-bootstrap Job: FAILED"
        note "logs: $KUBECTL -n $ns logs job/db-primary-bootstrap"
        issues=$((issues+1))
      else
        work "db-primary-bootstrap Job: Running"
        in_progress=1
      fi
    else
      # Missing — Ready replicas prove the bootstrap created clone_user/replica_user
      local r0=$(jp "$ns" pod db-replica-0 '{.status.phase}' "")
      if [[ "$r0" == "Running" ]]; then
        ok "db-primary-bootstrap Job: Complete (Job already TTL-reaped)"
      else
        bad "db-primary-bootstrap Job: missing and replicas are not Running"
        issues=$((issues+1))
      fi
    fi

    if $KUBECTL -n "$ns" get job proxysql-users-reload-template >/dev/null 2>&1; then
      local u_succ=$(jp "$ns" job proxysql-users-reload-template '{.status.succeeded}' 0)
      local u_fail=$(jp "$ns" job proxysql-users-reload-template '{.status.failed}'    0)
      if [[ "$u_succ" == "1" ]]; then
        ok "proxysql-users-reload Job: Complete"
      elif [[ "$u_fail" -gt 0 ]]; then
        bad "proxysql-users-reload Job: FAILED"
        note "logs: $KUBECTL -n $ns logs job/proxysql-users-reload-template"
        issues=$((issues+1))
      else
        work "proxysql-users-reload Job: Running"
        in_progress=1
      fi
    else
      local web_ready=$(jp "$ns" deploy magento-web '{.status.readyReplicas}' 0)
      if [[ "$web_ready" -gt 0 ]]; then
        ok "proxysql-users-reload Job: Complete (Job already TTL-reaped)"
      else
        bad "proxysql-users-reload Job: missing and magento-web has no Ready replicas"
        note "trigger: $KUBECTL -n $ns create job --from=job/proxysql-users-reload-template proxysql-users-reload-\$(date +%s)"
        issues=$((issues+1))
      fi
    fi

    # Replication health on each replica
    local i
    for i in 0 1; do
      if [[ "$($KUBECTL -n "$ns" get pod db-replica-$i -o jsonpath='{.status.phase}' 2>/dev/null)" != "Running" ]]; then
        continue
      fi
      local rep_out
      rep_out=$($KUBECTL -n "$ns" exec "db-replica-$i" -c db-replica -- \
        bash -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW REPLICA STATUS\G" 2>/dev/null' 2>/dev/null) || true
      if echo "$rep_out" | grep -q "Replica_IO_Running: Yes" \
         && echo "$rep_out" | grep -q "Replica_SQL_Running: Yes"; then
        local lag
        lag=$(echo "$rep_out" | awk '/Seconds_Behind_Source:/ {print $2}')
        ok "db-replica-$i replication: Yes/Yes (lag ${lag}s)"
      else
        bad "db-replica-$i replication: BROKEN"
        local err
        err=$(echo "$rep_out" | awk '/Last_(IO|SQL)_Error:/ && $2!="" {sub(/^[^:]+: */,""); print; exit}')
        [[ -n "$err" ]] && note "$err"
        issues=$((issues+1))
      fi
    done
  fi

  # ---- magento-cron recent runs --------------------------------------------
  if $KUBECTL -n "$ns" get cronjob magento-cron >/dev/null 2>&1; then
    # `make deploy-maintenance` suspends magento-cron before scaling web to 0
    # and unsuspends it after scaling back up. While suspended the last 5 Jobs
    # are stale (from before the patch) — reporting "last N Complete" against
    # them is technically true but misleading. Treat suspended as IN PROGRESS.
    local cron_suspended=$(jp "$ns" cronjob magento-cron '{.spec.suspend}' false)
    if [[ "$cron_suspended" == "true" ]]; then
      work "magento-cron: SUSPENDED (deploy-maintenance in progress, or manually paused)"
      in_progress=1
    else
      # Last 5 magento-cron Jobs by creation time. -o jsonpath spits one
      # field-per-job; we count successes and any failures.
      local cron_states
      cron_states=$($KUBECTL -n "$ns" get jobs --sort-by=.metadata.creationTimestamp -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].name}{"|"}{.status.succeeded}{"|"}{.status.failed}{"\n"}{end}' 2>/dev/null \
        | awk -F'|' '$1=="magento-cron"' | tail -5)
      if [[ -z "$cron_states" ]]; then
        note "magento-cron: no Jobs spawned yet (CronJob fires every minute; first install run can suspend it)"
      else
        local n_ok n_bad
        n_ok=$(echo "$cron_states" | awk -F'|' '$2=="1"' | wc -l)
        n_bad=$(echo "$cron_states" | awk -F'|' '$3 && $3>"0"' | wc -l)
        if [[ "$n_bad" -gt 0 ]]; then
          bad "magento-cron: $n_bad of last 5 runs FAILED"
          issues=$((issues+1))
        else
          ok "magento-cron: last $n_ok run(s) Complete"
        fi
      fi
    fi
  fi

  # ---- summary --------------------------------------------------------------
  printf "${C_BLD}→ "
  if [[ $issues -gt 0 ]]; then
    printf "%sFAILED%s — %d issue(s); see lines marked ✗ above${C_RST}\n" "$C_RED" "$C_RST" "$issues"
    return 1
  elif [[ $in_progress -gt 0 ]]; then
    printf "%sIN PROGRESS%s${C_RST}\n" "$C_YEL" "$C_RST"
    return 2
  else
    printf "%sHEALTHY%s${C_RST}\n" "$C_GRN" "$C_RST"
    return 0
  fi
}

# --- target dispatch (one pass) --------------------------------------------
# Run status for the given target and return the worst-case rank as exit code.
# Ranking (worst → best): FAILED(1) > IN_PROGRESS(2) > NOT_DEPLOYED(3) > HEALTHY(0)
run_target() {
  local target=$1
  case "$target" in
    all)
      local overall=0 rc
      for ns in default staging production; do
        status_one "$ns"
        rc=$?
        case "$rc" in
          1) overall=1 ;;
          2) [[ $overall -ne 1 ]] && overall=2 ;;
          3) [[ $overall -eq 0 ]] && overall=3 ;;
        esac
      done
      printf "\n${C_BLD}OVERALL: ${C_RST}"
      case "$overall" in
        0) printf "${C_GRN}HEALTHY${C_RST}\n" ;;
        1) printf "${C_RED}FAILED${C_RST}\n" ;;
        2) printf "${C_YEL}IN PROGRESS${C_RST}\n" ;;
        3) printf "${C_YEL}NOT DEPLOYED${C_RST}\n" ;;
      esac
      return $overall
      ;;
    default|staging|production)
      status_one "$target"
      return $?
      ;;
    *)
      echo "Unknown target: $target (use default|staging|production|all)" >&2
      return 64
      ;;
  esac
}

# --- watch loop -------------------------------------------------------------
# Refreshes status with a state-driven cadence: 3s while IN PROGRESS so the
# user sees init containers turning over, 10s once HEALTHY/FAILED so the API
# server doesn't get hammered. Auto-exits after STABLE_THRESHOLD consecutive
# HEALTHY ticks — kubectl get -w never tells you "deploy is done"; this does.
STABLE_THRESHOLD=3
watch_loop() {
  local target=$1
  local stable_count=0 iter=0 rc delay
  trap 'printf "\n${C_DIM}interrupted${C_RST}\n"; exit 130' INT TERM
  while :; do
    iter=$((iter+1))
    # \033[H homes cursor, \033[2J clears the whole screen.
    printf '\033[H\033[2J'
    printf "${C_BLD}deploy-status %s — refresh #%d at %s${C_RST}\n" \
      "$target" "$iter" "$(date '+%Y-%m-%d %H:%M:%S')"
    run_target "$target"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      stable_count=$((stable_count+1))
      if [[ $stable_count -ge $STABLE_THRESHOLD ]]; then
        printf "\n${C_GRN}stable for %d consecutive checks — exiting${C_RST}\n" "$stable_count"
        return 0
      fi
    else
      stable_count=0
    fi
    case "$rc" in
      0) delay=10 ;;  # HEALTHY: settle period before auto-exit
      1) delay=10 ;;  # FAILED: don't poll fast — user will read the failure
      2) delay=3  ;;  # IN PROGRESS: things turn over every few seconds
      3) delay=5  ;;  # NOT DEPLOYED: waiting for namespace to appear
      *) delay=5  ;;
    esac
    printf "\n${C_DIM}next refresh in %ds (Ctrl-C to exit; auto-exit after %d HEALTHY checks; on tick %d/%d)${C_RST}\n" \
      "$delay" "$STABLE_THRESHOLD" "$stable_count" "$STABLE_THRESHOLD"
    sleep "$delay"
  done
}

# --- main -------------------------------------------------------------------
target=""
watch=0
while (( $# )); do
  case "$1" in
    -w|--watch) watch=1 ;;
    -h|--help)
      cat <<EOF
Usage: $0 <default|staging|production|all> [--watch|-w]

Reports whether a Magento deploy is HEALTHY, IN PROGRESS, FAILED, or NOT DEPLOYED.

  --watch, -w   loop, refreshing every 3s during IN PROGRESS / 10s otherwise;
                clears the screen each tick; auto-exits after 3 HEALTHY ticks.

Exit codes (single-env or worst-of in 'all' mode):
  0  HEALTHY      1  FAILED      2  IN PROGRESS      3  NOT DEPLOYED
EOF
      exit 0
      ;;
    -*) echo "Unknown flag: $1" >&2; exit 64 ;;
    *)  if [[ -z "$target" ]]; then target=$1; else
          echo "Unexpected extra argument: $1" >&2; exit 64
        fi ;;
  esac
  shift
done
if [[ -z "$target" ]]; then
  echo "Usage: $0 <default|dev|staging|stage|production|prod|all> [--watch|-w]" >&2
  exit 64
fi

# Resolve friendly aliases so direct invocation matches the make-target UX.
case "$target" in
  dev|develop) target=default ;;
  stage|stag)  target=staging ;;
  prod)        target=production ;;
esac
case "$target" in
  default|staging|production|all) ;;
  *) echo "Unknown target: $target (use default|staging|production|all)" >&2; exit 64 ;;
esac

if (( watch )); then
  watch_loop "$target"
else
  run_target "$target"
fi
exit $?

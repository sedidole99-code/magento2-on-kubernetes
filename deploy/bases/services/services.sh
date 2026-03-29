#!/usr/bin/env bash
#
# Cluster services data collection and rendering.
# Shared by both the local static HTML and the in-cluster dashboard pod.
#
# Usage:
#   ./deploy/services.sh html [file]     Generate static HTML (default: services.html)
#   ./deploy/services.sh serve [dir]     Collection loop for pod (writes JSON to dir)
#
set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"
HELM="${HELM:-helm}"
MINIKUBE="${MINIKUBE:-minikube}"
ENVIRONMENTS="default staging production"

# =========================================================================== #
# Helpers (all accept optional namespace flag as last arg)
# =========================================================================== #

je() { printf '%s' "${1:-n/a}" | sed 's/\\/\\\\/g;s/"/\\"/g'; }

ns_exists() {
  [ "$1" = "default" ] && return 0
  $KUBECTL get namespace "$1" >/dev/null 2>&1
}

secret_value() {
  local nf="$3"
  $KUBECTL get secret $nf "$1" -o jsonpath="{.data.$2}" 2>/dev/null | base64 -d 2>/dev/null || echo "n/a"
}

pod_image() {
  local label="$1" container="${2:-}" nf="$3"
  if [ -n "$container" ]; then
    $KUBECTL get pods $nf -l "$label" -o jsonpath="{.items[0].spec.containers[?(@.name==\"$container\")].image}" 2>/dev/null || echo "n/a"
  else
    $KUBECTL get pods $nf -l "$label" -o jsonpath="{.items[0].spec.containers[0].image}" 2>/dev/null || echo "n/a"
  fi
}

svc_endpoint() {
  local svc="$1" nf="$2"
  $KUBECTL get svc $nf "$svc" -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}' 2>/dev/null || echo "n/a"
}

helm_app_version() {
  local release="$1"
  if command -v "$HELM" >/dev/null 2>&1; then
    $HELM list -o json 2>/dev/null | python3 -c "
import sys, json
for r in json.load(sys.stdin):
    if r['name'] == '$release':
        print(r.get('app_version', 'n/a')); sys.exit()
print('n/a')" 2>/dev/null || echo "n/a"
  else
    echo "n/a"
  fi
}

# =========================================================================== #
# Collect all data for a single namespace → JSON file
# =========================================================================== #

collect_env() {
  local ns="$1" output="$2"
  local nf=""
  [ "$ns" != "default" ] && nf="-n $ns"

  echo >&2 "[$(date)] Collecting data for namespace: $ns"

  # Check if namespace exists and has magento deployed
  if ! ns_exists "$ns"; then
    cat > "${output}.tmp" <<EOF
{"exists": false, "namespace": "$ns"}
EOF
    mv "${output}.tmp" "$output"
    return
  fi

  # Check if magento-web deployment exists in this namespace
  local has_magento="false"
  if $KUBECTL get deployment $nf magento-web >/dev/null 2>&1; then
    has_magento="true"
  fi

  # Static: credentials
  local admin_user admin_pass admin_email admin_uri
  admin_user=$(secret_value magento-admin ADMIN_USER "$nf")
  admin_pass=$(secret_value magento-admin ADMIN_PASSWORD "$nf")
  admin_email=$(secret_value magento-admin ADMIN_EMAIL "$nf")
  admin_uri=$(secret_value magento-admin ADMIN_URI "$nf")

  local db_user db_pass db_root_pass db_name
  db_user=$(secret_value database-credentials MYSQL_USER "$nf")
  db_pass=$(secret_value database-credentials MYSQL_PASSWORD "$nf")
  db_root_pass=$(secret_value database-credentials MYSQL_ROOT_PASSWORD "$nf")
  db_name=$(secret_value database-credentials MYSQL_DATABASE "$nf")

  local rabbitmq_user rabbitmq_pass
  rabbitmq_user=$(secret_value rabbitmq-credentials RABBITMQ_DEFAULT_USER "$nf")
  rabbitmq_pass=$(secret_value rabbitmq-credentials RABBITMQ_DEFAULT_PASS "$nf")

  local es_log_pass
  es_log_pass=$(secret_value elasticsearch-master-credentials password "$nf")

  # Static: images
  local img_magento img_db img_es img_redis img_varnish img_rabbitmq
  img_magento=$(pod_image "app=magento,component=web" "magento-web" "$nf")
  img_db=$(pod_image "app=db" "" "$nf")
  img_es=$(pod_image "app=elasticsearch" "" "$nf")
  img_redis=$(pod_image "app=redis" "" "$nf")
  img_varnish=$(pod_image "app=varnish" "" "$nf")
  img_rabbitmq=$(pod_image "app=rabbitmq" "" "$nf")

  # Dynamic: services
  local svc_magento svc_db svc_es svc_redis svc_varnish svc_rabbitmq
  local svc_grafana svc_prometheus svc_kibana svc_services svc_k8s_dash
  svc_magento=$(svc_endpoint magento-web "$nf")
  svc_db=$(svc_endpoint db "$nf")
  svc_es=$(svc_endpoint elasticsearch "$nf")
  svc_redis=$(svc_endpoint redis "$nf")
  svc_varnish=$(svc_endpoint varnish "$nf")
  svc_rabbitmq=$(svc_endpoint rabbitmq "$nf")
  svc_grafana=$(svc_endpoint kube-prometheus-stack-grafana "$nf")
  svc_prometheus=$(svc_endpoint kube-prometheus-stack-prometheus "$nf")
  svc_kibana=$(svc_endpoint kibana-kibana "$nf")
  svc_services=$(svc_endpoint services-dashboard "$nf")
  svc_k8s_dash=$($KUBECTL get svc kubernetes-dashboard -n kubernetes-dashboard -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}' 2>/dev/null || echo "n/a")

  # Dynamic: pods
  local pods_running pods_total
  pods_running=$($KUBECTL get pods $nf --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
  pods_total=$($KUBECTL get pods $nf --no-headers 2>/dev/null | wc -l | tr -d ' ')

  local pods_json="["
  local first=true
  while read -r name ready status restarts age; do
    [ -z "$name" ] && continue
    $first && first=false || pods_json+=","
    pods_json+="{\"name\":\"$(je "$name")\",\"ready\":\"$(je "$ready")\",\"status\":\"$(je "$status")\",\"restarts\":\"$(je "$restarts")\",\"age\":\"$(je "$age")\"}"
  done < <($KUBECTL get pods $nf --no-headers 2>/dev/null || true)
  pods_json+="]"

  # Helm releases (only for default namespace)
  local helm_json="[]"
  if [ "$ns" = "default" ]; then
    helm_json="["
    first=true
    while read -r name; do
      [ -z "$name" ] && continue
      $first && first=false || helm_json+=","
      helm_json+="{\"name\":\"$(je "$name")\"}"
    done < <($KUBECTL get secrets -l owner=helm,status=deployed --no-headers \
      -o custom-columns='NAME:.metadata.labels.name' 2>/dev/null | sort -u || true)
    helm_json+="]"
  fi

  # Backups (from mounted PVC — only available in the dashboard pod)
  local db_backups_json="[]" media_backups_json="[]"
  if [ -d /backup/db ] && [ "$ns" = "default" ]; then
    db_backups_json="["
    first=true
    while read -r size month day time name; do
      [ -z "$name" ] && continue
      local bname human
      bname=$(basename "$name")
      human=$(numfmt --to=iec "$size" 2>/dev/null || echo "${size}B")
      $first && first=false || db_backups_json+=","
      db_backups_json+="{\"name\":\"$(je "$bname")\",\"size\":\"$(je "$human")\",\"date\":\"$(je "$month $day $time")\"}"
    done < <(ls -lt /backup/db/db-*.sql.gz 2>/dev/null | awk '{print $5, $6, $7, $8, $9}')
    db_backups_json+="]"
  fi
  if [ -d /backup/media ] && [ "$ns" = "default" ]; then
    media_backups_json="["
    first=true
    while read -r size month day time name; do
      [ -z "$name" ] && continue
      local bname human
      bname=$(basename "$name")
      human=$(numfmt --to=iec "$size" 2>/dev/null || echo "${size}B")
      $first && first=false || media_backups_json+=","
      media_backups_json+="{\"name\":\"$(je "$bname")\",\"size\":\"$(je "$human")\",\"date\":\"$(je "$month $day $time")\"}"
    done < <(ls -lt /backup/media/media-*.tar.gz 2>/dev/null | awk '{print $5, $6, $7, $8, $9}')
    media_backups_json+="]"
  fi

  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  cat > "${output}.tmp" <<EOF
{
  "exists": true,
  "namespace": "$ns",
  "has_magento": $has_magento,
  "updated": "$ts",
  "magento": {
    "admin_user": "$(je "$admin_user")",
    "admin_password": "$(je "$admin_pass")",
    "admin_email": "$(je "$admin_email")",
    "admin_uri": "$(je "$admin_uri")",
    "image": "$(je "$img_magento")"
  },
  "database": {
    "user": "$(je "$db_user")",
    "password": "$(je "$db_pass")",
    "root_password": "$(je "$db_root_pass")",
    "name": "$(je "$db_name")",
    "image": "$(je "$img_db")"
  },
  "elasticsearch": { "image": "$(je "$img_es")" },
  "redis": { "image": "$(je "$img_redis")" },
  "varnish": { "image": "$(je "$img_varnish")" },
  "rabbitmq": { "user": "$(je "$rabbitmq_user")", "password": "$(je "$rabbitmq_pass")", "image": "$(je "$img_rabbitmq")" },
  "kibana": { "es_password": "$(je "$es_log_pass")" },
  "helm_releases": $helm_json,
  "pods_running": $pods_running,
  "pods_total": $pods_total,
  "services": {
    "magento_web": "$(je "$svc_magento")",
    "db": "$(je "$svc_db")",
    "elasticsearch": "$(je "$svc_es")",
    "redis": "$(je "$svc_redis")",
    "varnish": "$(je "$svc_varnish")",
    "rabbitmq": "$(je "$svc_rabbitmq")",
    "grafana": "$(je "$svc_grafana")",
    "prometheus": "$(je "$svc_prometheus")",
    "kibana": "$(je "$svc_kibana")",
    "services_dashboard": "$(je "$svc_services")"
  },
  "k8s_dashboard_svc": "$(je "$svc_k8s_dash")",
  "backups": {
    "db": $db_backups_json,
    "media": $media_backups_json
  },
  "pods": $pods_json
}
EOF
  mv "${output}.tmp" "$output"
}

# =========================================================================== #
# HTML renderer (for local static page — kept for `make services`)
# =========================================================================== #

render_html() {
  local output="${1:-services.html}"
  echo >&2 "Generating static HTML is deprecated. Use 'make services-server' for the live dashboard."
  echo >&2 "Writing minimal redirect page to $output"
  cat > "$output" <<'HTMLEOF'
<!DOCTYPE html>
<html><head><title>m2kube Services</title></head>
<body style="background:#0f172a;color:#e2e8f0;font-family:monospace;padding:3rem;text-align:center">
<h1>m2kube Services</h1>
<p>Run <code>make services-server</code> for the live dashboard.</p>
</body></html>
HTMLEOF
}

# =========================================================================== #
# Serve mode — collection loop for the in-cluster pod
# =========================================================================== #

serve() {
  umask 022
  local data_dir="${1:-/data}"
  local static_interval="${STATIC_INTERVAL:-1800}"
  local dynamic_interval="${DYNAMIC_INTERVAL:-30}"

  # Initial collection for all environments
  for ns in $ENVIRONMENTS; do
    collect_env "$ns" "$data_dir/env-${ns}.json"
  done

  local last_collect now
  last_collect=$(date +%s)

  echo >&2 "Serve loop started. Interval: ${dynamic_interval}s, Static: ${static_interval}s"

  while true; do
    sleep 5
    now=$(date +%s)

    # Check for refresh trigger
    if [ -f "$data_dir/.refresh" ]; then
      rm -f "$data_dir/.refresh"
      for ns in $ENVIRONMENTS; do
        collect_env "$ns" "$data_dir/env-${ns}.json"
      done
      last_collect=$now
      continue
    fi

    if [ $((now - last_collect)) -ge "$dynamic_interval" ]; then
      for ns in $ENVIRONMENTS; do
        collect_env "$ns" "$data_dir/env-${ns}.json"
      done
      last_collect=$now
    fi
  done
}

# =========================================================================== #
# API mode — minimal HTTP server for delete operations
# =========================================================================== #

api() {
  BACKUP_DIR="${1:-/backup}"
  DATA_DIR="${2:-/data}"
  PORT=9090

  echo "API server starting on port $PORT" >&2

  cat > /tmp/api-handler.sh <<'HANDLER'
#!/bin/sh
read -r method path _

while read -r header; do
  header=$(echo "$header" | tr -d '\r')
  [ -z "$header" ] && break
done

response_body='{"ok":false,"error":"not found"}'
status="404 Not Found"

path=$(echo "$path" | tr -d '\r')

case "$method" in
  DELETE)
    case "$path" in
      /api/backup/db/*)
        filename=$(basename "$path")
        if echo "$filename" | grep -qE '^db-[0-9]{8}-[0-9]{6}\.sql\.gz$'; then
          if [ -f "$BACKUP_DIR/db/$filename" ]; then
            rm -f "$BACKUP_DIR/db/$filename"
            response_body="{\"ok\":true,\"deleted\":\"$filename\"}"
            status="200 OK"
            echo "Deleted: db/$filename" >&2; touch "$DATA_DIR/.refresh"
          fi
        else
          response_body='{"ok":false,"error":"invalid filename"}'
          status="400 Bad Request"
        fi
        ;;
      /api/backup/media/*)
        filename=$(basename "$path")
        if echo "$filename" | grep -qE '^media-[0-9]{8}-[0-9]{6}\.tar\.gz$'; then
          if [ -f "$BACKUP_DIR/media/$filename" ]; then
            rm -f "$BACKUP_DIR/media/$filename"
            response_body="{\"ok\":true,\"deleted\":\"$filename\"}"
            status="200 OK"
            echo "Deleted: media/$filename" >&2; touch "$DATA_DIR/.refresh"
          fi
        else
          response_body='{"ok":false,"error":"invalid filename"}'
          status="400 Bad Request"
        fi
        ;;
    esac
    ;;
  OPTIONS)
    response_body=""
    status="204 No Content"
    ;;
esac

len=$(echo -n "$response_body" | wc -c)
printf "HTTP/1.1 %s\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: DELETE, OPTIONS\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" \
  "$status" "$len" "$response_body"
HANDLER

  chmod +x /tmp/api-handler.sh
  export BACKUP_DIR DATA_DIR

  while true; do
    nc -ll -p "$PORT" -e /tmp/api-handler.sh 2>/dev/null || \
    nc -l -p "$PORT" -e /tmp/api-handler.sh 2>/dev/null || \
    { echo "nc failed, retrying..." >&2; sleep 1; }
  done
}

# =========================================================================== #
# Main
# =========================================================================== #

case "${1:-html}" in
  html)   render_html "${2:-services.html}" ;;
  serve)  serve "${2:-/data}" ;;
  api)    api "${2:-/backup}" "${3:-/data}" ;;
  *)      echo "Usage: $0 {html [file] | serve [dir] | api [backup-dir] [data-dir]}" >&2; exit 1 ;;
esac

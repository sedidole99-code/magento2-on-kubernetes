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

# =========================================================================== #
# Helpers
# =========================================================================== #

je() { printf '%s' "${1:-n/a}" | sed 's/\\/\\\\/g;s/"/\\"/g'; }

secret_value() {
  $KUBECTL get secret "$1" -o jsonpath="{.data.$2}" 2>/dev/null | base64 -d 2>/dev/null || echo "n/a"
}

pod_image() {
  local label="$1" container="${2:-}"
  if [ -n "$container" ]; then
    $KUBECTL get pods -l "$label" -o jsonpath="{.items[0].spec.containers[?(@.name==\"$container\")].image}" 2>/dev/null || echo "n/a"
  else
    $KUBECTL get pods -l "$label" -o jsonpath="{.items[0].spec.containers[0].image}" 2>/dev/null || echo "n/a"
  fi
}

svc_endpoint() {
  $KUBECTL get svc "$1" -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}' 2>/dev/null || echo "n/a"
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
# Data collection — static (credentials, images, helm versions)
# =========================================================================== #

collect_static() {
  echo >&2 "[$(date)] Collecting static data..."

  S_ADMIN_USER=$(secret_value magento-admin ADMIN_USER)
  S_ADMIN_PASSWORD=$(secret_value magento-admin ADMIN_PASSWORD)
  S_ADMIN_EMAIL=$(secret_value magento-admin ADMIN_EMAIL)
  S_ADMIN_URI=$(secret_value magento-admin ADMIN_URI)

  S_DB_USER=$(secret_value database-credentials MYSQL_USER)
  S_DB_PASSWORD=$(secret_value database-credentials MYSQL_PASSWORD)
  S_DB_ROOT_PASSWORD=$(secret_value database-credentials MYSQL_ROOT_PASSWORD)
  S_DB_NAME=$(secret_value database-credentials MYSQL_DATABASE)

  S_ES_LOG_PASSWORD=$(secret_value elasticsearch-master-credentials password)

  S_IMG_MAGENTO=$(pod_image "app=magento,component=web" "magento-web")
  S_IMG_DB=$(pod_image "app=db")
  S_IMG_ES=$(pod_image "app=elasticsearch")
  S_IMG_REDIS=$(pod_image "app=redis")
  S_IMG_VARNISH=$(pod_image "app=varnish")

  # Helm releases (from secrets — works without helm CLI)
  S_HELM_JSON="["
  local first=true
  while read -r name; do
    [ -z "$name" ] && continue
    $first && first=false || S_HELM_JSON+=","
    S_HELM_JSON+="{\"name\":\"$(je "$name")\"}"
  done < <($KUBECTL get secrets -l owner=helm,status=deployed --no-headers \
    -o custom-columns='NAME:.metadata.labels.name' 2>/dev/null | sort -u || true)
  S_HELM_JSON+="]"

  # Helm app versions (only when helm + python3 are available, i.e. local)
  S_VER_CERTMGR=$(helm_app_version cert-manager)
  S_VER_INGRESS=$(helm_app_version ingress-nginx)
  S_VER_SECRETGEN=$(helm_app_version secret-gsenerator)
  S_VER_PROMETHEUS=$(helm_app_version kube-prometheus-stack)
  S_VER_ES_LOG=$(helm_app_version elasticsearch)
  S_VER_FLUENTBIT=$(helm_app_version fluent-bit)
  S_VER_KIBANA=$(helm_app_version kibana)
  S_VER_LOKI=$(helm_app_version loki)
}

# =========================================================================== #
# Data collection — dynamic (pods, services, cluster state)
# =========================================================================== #

collect_dynamic() {
  echo >&2 "[$(date)] Collecting dynamic data..."

  D_SVC_MAGENTO=$(svc_endpoint magento-web)
  D_SVC_DB=$(svc_endpoint db)
  D_SVC_ES=$(svc_endpoint elasticsearch)
  D_SVC_REDIS=$(svc_endpoint redis)
  D_SVC_VARNISH=$(svc_endpoint varnish)
  D_SVC_GRAFANA=$(svc_endpoint kube-prometheus-stack-grafana)
  D_SVC_PROMETHEUS=$(svc_endpoint kube-prometheus-stack-prometheus)
  D_SVC_KIBANA=$(svc_endpoint kibana-kibana)
  D_SVC_SERVICES_DASHBOARD=$(svc_endpoint services-dashboard)
  D_SVC_K8S_DASHBOARD=$($KUBECTL get svc kubernetes-dashboard -n kubernetes-dashboard -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}' 2>/dev/null || echo "n/a")

  D_PODS_RUNNING=$($KUBECTL get pods --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
  D_PODS_TOTAL=$($KUBECTL get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')
  D_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  D_TIMESTAMP_LOCAL=$(date '+%Y-%m-%d %H:%M:%S %Z')
  D_MINIKUBE_IP=$($MINIKUBE ip 2>/dev/null || echo "n/a")

  # Pod list for JSON output
  D_PODS_JSON="["
  local first=true
  while read -r name ready status restarts age; do
    [ -z "$name" ] && continue
    $first && first=false || D_PODS_JSON+=","
    D_PODS_JSON+="{\"name\":\"$(je "$name")\",\"ready\":\"$(je "$ready")\",\"status\":\"$(je "$status")\",\"restarts\":\"$(je "$restarts")\",\"age\":\"$(je "$age")\"}"
  done < <($KUBECTL get pods --no-headers 2>/dev/null || true)
  D_PODS_JSON+="]"

  # Backup listings (from mounted PVC at /backup)
  D_DB_BACKUPS_JSON="["
  first=true
  if [ -d /backup/db ]; then
    while read -r size month day time name; do
      [ -z "$name" ] && continue
      local bname human
      bname=$(basename "$name")
      human=$(numfmt --to=iec "$size" 2>/dev/null || echo "${size}B")
      $first && first=false || D_DB_BACKUPS_JSON+=","
      D_DB_BACKUPS_JSON+="{\"name\":\"$(je "$bname")\",\"size\":\"$(je "$human")\",\"date\":\"$(je "$month $day $time")\"}"
    done < <(ls -lt /backup/db/db-*.sql.gz 2>/dev/null | awk '{print $5, $6, $7, $8, $9}')
  fi
  D_DB_BACKUPS_JSON+="]"

  D_MEDIA_BACKUPS_JSON="["
  first=true
  if [ -d /backup/media ]; then
    while read -r size month day time name; do
      [ -z "$name" ] && continue
      local bname human
      bname=$(basename "$name")
      human=$(numfmt --to=iec "$size" 2>/dev/null || echo "${size}B")
      $first && first=false || D_MEDIA_BACKUPS_JSON+=","
      D_MEDIA_BACKUPS_JSON+="{\"name\":\"$(je "$bname")\",\"size\":\"$(je "$human")\",\"date\":\"$(je "$month $day $time")\"}"
    done < <(ls -lt /backup/media/media-*.tar.gz 2>/dev/null | awk '{print $5, $6, $7, $8, $9}')
  fi
  D_MEDIA_BACKUPS_JSON+="]"
}

# =========================================================================== #
# JSON renderers (for serve mode)
# =========================================================================== #

render_json_static() {
  cat > "${1}.tmp" <<EOF
{
  "updated": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "magento": {
    "admin_user": "$(je "$S_ADMIN_USER")",
    "admin_password": "$(je "$S_ADMIN_PASSWORD")",
    "admin_email": "$(je "$S_ADMIN_EMAIL")",
    "admin_uri": "$(je "$S_ADMIN_URI")",
    "image": "$(je "$S_IMG_MAGENTO")"
  },
  "database": {
    "user": "$(je "$S_DB_USER")",
    "password": "$(je "$S_DB_PASSWORD")",
    "root_password": "$(je "$S_DB_ROOT_PASSWORD")",
    "name": "$(je "$S_DB_NAME")",
    "image": "$(je "$S_IMG_DB")"
  },
  "elasticsearch": { "image": "$(je "$S_IMG_ES")" },
  "redis": { "image": "$(je "$S_IMG_REDIS")" },
  "varnish": { "image": "$(je "$S_IMG_VARNISH")" },
  "kibana": { "es_password": "$(je "$S_ES_LOG_PASSWORD")" },
  "helm_releases": $S_HELM_JSON,
  "versions": {
    "cert_manager": "$(je "$S_VER_CERTMGR")",
    "ingress": "$(je "$S_VER_INGRESS")",
    "secret_generator": "$(je "$S_VER_SECRETGEN")",
    "prometheus": "$(je "$S_VER_PROMETHEUS")",
    "elasticsearch_logging": "$(je "$S_VER_ES_LOG")",
    "fluent_bit": "$(je "$S_VER_FLUENTBIT")",
    "kibana": "$(je "$S_VER_KIBANA")",
    "loki": "$(je "$S_VER_LOKI")"
  }
}
EOF
  mv "${1}.tmp" "$1"
}

render_json_dynamic() {
  cat > "${1}.tmp" <<EOF
{
  "updated": "$D_TIMESTAMP",
  "pods_running": $D_PODS_RUNNING,
  "pods_total": $D_PODS_TOTAL,
  "minikube_ip": "$(je "$D_MINIKUBE_IP")",
  "services": {
    "magento_web": "$(je "$D_SVC_MAGENTO")",
    "db": "$(je "$D_SVC_DB")",
    "elasticsearch": "$(je "$D_SVC_ES")",
    "redis": "$(je "$D_SVC_REDIS")",
    "varnish": "$(je "$D_SVC_VARNISH")",
    "grafana": "$(je "$D_SVC_GRAFANA")",
    "prometheus": "$(je "$D_SVC_PROMETHEUS")",
    "kibana": "$(je "$D_SVC_KIBANA")",
    "services_dashboard": "$(je "$D_SVC_SERVICES_DASHBOARD")"
  },
  "k8s_dashboard_svc": "$(je "$D_SVC_K8S_DASHBOARD")",
  "backups": {
    "db": $D_DB_BACKUPS_JSON,
    "media": $D_MEDIA_BACKUPS_JSON
  },
  "pods": $D_PODS_JSON
}
EOF
  mv "${1}.tmp" "$1"
}

# =========================================================================== #
# HTML renderer (for local static page)
# =========================================================================== #

render_html() {
  collect_static
  collect_dynamic

  local output="${1:-services.html}"

  cat > "$output" <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>m2kube — Dev Services</title>
<style>
  :root { --bg: #0f172a; --card: #1e293b; --border: #334155; --text: #e2e8f0; --muted: #94a3b8; --accent: #38bdf8; --green: #4ade80; --yellow: #fbbf24; --red: #f87171; }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, monospace; background: var(--bg); color: var(--text); padding: 2rem; line-height: 1.6; }
  h1 { font-size: 1.5rem; margin-bottom: 0.25rem; }
  .subtitle { color: var(--muted); font-size: 0.85rem; margin-bottom: 2rem; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(420px, 1fr)); gap: 1.5rem; }
  .card { background: var(--card); border: 1px solid var(--border); border-radius: 8px; padding: 1.25rem; }
  .card h2 { font-size: 1rem; color: var(--accent); margin-bottom: 1rem; border-bottom: 1px solid var(--border); padding-bottom: 0.5rem; }
  table { width: 100%; border-collapse: collapse; }
  td { padding: 0.3rem 0; font-size: 0.85rem; vertical-align: top; }
  td:first-child { color: var(--muted); white-space: nowrap; padding-right: 1rem; width: 40%; }
  td:last-child { word-break: break-all; }
  .mono { font-family: 'SF Mono', 'Fira Code', monospace; font-size: 0.8rem; }
  .cmd { background: #0f172a; border: 1px solid var(--border); border-radius: 4px; padding: 0.5rem 0.75rem; font-size: 0.8rem; font-family: monospace; color: var(--green); margin-top: 0.5rem; display: block; }
  a { color: var(--accent); text-decoration: none; }
  a:hover { text-decoration: underline; }
  .badge { display: inline-block; padding: 0.1rem 0.5rem; border-radius: 4px; font-size: 0.75rem; font-weight: 600; }
  .badge-green { background: rgba(74,222,128,0.15); color: var(--green); }
  .badge-yellow { background: rgba(251,191,36,0.15); color: var(--yellow); }
</style>
</head>
<body>
<h1>m2kube — Development Services</h1>
<p class="subtitle">Generated: ${D_TIMESTAMP_LOCAL} &middot; Pods: ${D_PODS_RUNNING}/${D_PODS_TOTAL} running &middot; Minikube IP: ${D_MINIKUBE_IP}</p>

<div class="grid">

<div class="card">
  <h2>Magento Storefront</h2>
  <table>
    <tr><td>Frontend URL</td><td><a href="https://magento.test/" target="_blank">https://magento.test/</a></td></tr>
    <tr><td>Admin URL</td><td><a href="https://magento.test/${S_ADMIN_URI}" target="_blank">https://magento.test/${S_ADMIN_URI}</a></td></tr>
    <tr><td>Admin User</td><td class="mono">${S_ADMIN_USER}</td></tr>
    <tr><td>Admin Password</td><td class="mono">${S_ADMIN_PASSWORD}</td></tr>
    <tr><td>Admin Email</td><td class="mono">${S_ADMIN_EMAIL}</td></tr>
    <tr><td>Image</td><td class="mono">${S_IMG_MAGENTO}</td></tr>
    <tr><td>Service</td><td class="mono">magento-web (${D_SVC_MAGENTO})</td></tr>
  </table>
</div>

<div class="card">
  <h2>Database (Percona)</h2>
  <table>
    <tr><td>Host</td><td class="mono">db:3306</td></tr>
    <tr><td>Service</td><td class="mono">${D_SVC_DB}</td></tr>
    <tr><td>Database</td><td class="mono">${S_DB_NAME}</td></tr>
    <tr><td>User</td><td class="mono">${S_DB_USER}</td></tr>
    <tr><td>Password</td><td class="mono">${S_DB_PASSWORD}</td></tr>
    <tr><td>Root Password</td><td class="mono">${S_DB_ROOT_PASSWORD}</td></tr>
    <tr><td>Image</td><td class="mono">${S_IMG_DB}</td></tr>
  </table>
  <code class="cmd">kubectl port-forward svc/db 3306:3306</code>
</div>

<div class="card">
  <h2>Elasticsearch (Magento Search)</h2>
  <table>
    <tr><td>Host</td><td class="mono">elasticsearch:9200</td></tr>
    <tr><td>Service</td><td class="mono">${D_SVC_ES}</td></tr>
    <tr><td>Security</td><td><span class="badge badge-yellow">disabled</span></td></tr>
    <tr><td>Image</td><td class="mono">${S_IMG_ES}</td></tr>
  </table>
  <code class="cmd">kubectl port-forward svc/elasticsearch 9200:9200</code>
</div>

<div class="card">
  <h2>Redis</h2>
  <table>
    <tr><td>Host</td><td class="mono">redis:6379</td></tr>
    <tr><td>Service</td><td class="mono">${D_SVC_REDIS}</td></tr>
    <tr><td>DB 0</td><td>Cache</td></tr>
    <tr><td>DB 1</td><td>Full Page Cache</td></tr>
    <tr><td>DB 2</td><td>Sessions</td></tr>
    <tr><td>Image</td><td class="mono">${S_IMG_REDIS}</td></tr>
  </table>
  <code class="cmd">kubectl port-forward svc/redis 6379:6379</code>
</div>

<div class="card">
  <h2>Varnish</h2>
  <table>
    <tr><td>Host</td><td class="mono">varnish:8080</td></tr>
    <tr><td>Service</td><td class="mono">${D_SVC_VARNISH}</td></tr>
    <tr><td>Cache Size</td><td>512 MB</td></tr>
    <tr><td>Admin Port</td><td class="mono">6081</td></tr>
    <tr><td>Image</td><td class="mono">${S_IMG_VARNISH}</td></tr>
  </table>
</div>

<div class="card">
  <h2>Grafana</h2>
  <table>
    <tr><td>URL</td><td><a href="http://localhost:3000" target="_blank">http://localhost:3000</a></td></tr>
    <tr><td>Service</td><td class="mono">${D_SVC_GRAFANA}</td></tr>
    <tr><td>Username</td><td class="mono">admin</td></tr>
    <tr><td>Password</td><td class="mono">admin</td></tr>
    <tr><td>Chart Version</td><td class="mono">${S_VER_PROMETHEUS}</td></tr>
  </table>
  <code class="cmd">kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80</code>
</div>

<div class="card">
  <h2>Prometheus</h2>
  <table>
    <tr><td>URL</td><td><a href="http://localhost:9090" target="_blank">http://localhost:9090</a></td></tr>
    <tr><td>Service</td><td class="mono">${D_SVC_PROMETHEUS}</td></tr>
    <tr><td>Chart Version</td><td class="mono">${S_VER_PROMETHEUS}</td></tr>
  </table>
  <code class="cmd">kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090</code>
</div>

<div class="card">
  <h2>Kibana</h2>
  <table>
    <tr><td>URL</td><td><a href="http://localhost:5601" target="_blank">http://localhost:5601</a></td></tr>
    <tr><td>Service</td><td class="mono">${D_SVC_KIBANA}</td></tr>
    <tr><td>Username</td><td class="mono">elastic</td></tr>
    <tr><td>Password</td><td class="mono">${S_ES_LOG_PASSWORD}</td></tr>
    <tr><td>ES Host</td><td class="mono">elasticsearch-master:9200</td></tr>
    <tr><td>Chart Version</td><td class="mono">${S_VER_KIBANA}</td></tr>
  </table>
  <code class="cmd">kubectl port-forward svc/kibana-kibana 5601:5601</code>
</div>

<div class="card">
  <h2>Helm Releases</h2>
  <table>
    <tr><td>cert-manager</td><td class="mono">${S_VER_CERTMGR}</td></tr>
    <tr><td>nginx-ingress</td><td class="mono">${S_VER_INGRESS}</td></tr>
    <tr><td>secret-generator</td><td class="mono">${S_VER_SECRETGEN}</td></tr>
    <tr><td>kube-prometheus-stack</td><td class="mono">${S_VER_PROMETHEUS}</td></tr>
    <tr><td>elasticsearch (logging)</td><td class="mono">${S_VER_ES_LOG}</td></tr>
    <tr><td>fluent-bit</td><td class="mono">${S_VER_FLUENTBIT}</td></tr>
    <tr><td>kibana</td><td class="mono">${S_VER_KIBANA}</td></tr>
    <tr><td>loki</td><td class="mono">${S_VER_LOKI}</td></tr>
  </table>
</div>

<div class="card">
  <h2>Cluster</h2>
  <table>
    <tr><td>Minikube IP</td><td class="mono">${D_MINIKUBE_IP}</td></tr>
    <tr><td>Pods Running</td><td>${D_PODS_RUNNING} / ${D_PODS_TOTAL}</td></tr>
    <tr><td>Ingress Host</td><td class="mono">magento.test</td></tr>
    <tr><td>TLS</td><td>Self-signed (cert-manager)</td></tr>
  </table>
  <code class="cmd">minikube dashboard</code>
</div>

</div>
</body>
</html>
HTMLEOF

  echo >&2 "Services page written to: $output"
}

# =========================================================================== #
# Serve mode — collection loop for the in-cluster pod
# =========================================================================== #

serve() {
  umask 022
  local data_dir="${1:-/data}"
  local static_interval="${STATIC_INTERVAL:-1800}"
  local dynamic_interval="${DYNAMIC_INTERVAL:-120}"

  collect_static;  render_json_static  "$data_dir/static.json"
  collect_dynamic;  render_json_dynamic "$data_dir/dynamic.json"

  local static_last dynamic_last now
  static_last=$(date +%s)
  dynamic_last=$(date +%s)

  echo >&2 "Serve loop started. Static interval: ${static_interval}s, Dynamic interval: ${dynamic_interval}s"

  while true; do
    sleep 5
    now=$(date +%s)

    # Check for refresh trigger (e.g. after a delete via API)
    if [ -f "$data_dir/.refresh" ]; then
      rm -f "$data_dir/.refresh"
      collect_dynamic;  render_json_dynamic "$data_dir/dynamic.json"
      dynamic_last=$now
      continue
    fi

    if [ $((now - dynamic_last)) -ge "$dynamic_interval" ]; then
      collect_dynamic;  render_json_dynamic "$data_dir/dynamic.json"
      dynamic_last=$now
    fi

    if [ $((now - static_last)) -ge "$static_interval" ]; then
      collect_static;  render_json_static "$data_dir/static.json"
      static_last=$now
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

  # Write the request handler script (busybox nc -e needs a file)
  cat > /tmp/api-handler.sh <<'HANDLER'
#!/bin/sh
read -r method path _

# Read headers
while read -r header; do
  header=$(echo "$header" | tr -d '\r')
  [ -z "$header" ] && break
done

response_body='{"ok":false,"error":"not found"}'
status="404 Not Found"

# Strip \r from path
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

  # Export BACKUP_DIR so the handler can use it
  export BACKUP_DIR DATA_DIR

  # Loop: busybox nc -ll -p PORT -e handler
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

#!/usr/bin/env bash
#
# Generates a static HTML page showing all cluster services, URLs,
# credentials, and versions. For development use only.
#
set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"
HELM="${HELM:-helm}"
MINIKUBE="${MINIKUBE:-minikube}"
OUTPUT="${1:-services.html}"

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #

secret_value() {
  local secret="$1" key="$2"
  $KUBECTL get secret "$secret" -o jsonpath="{.data.$key}" 2>/dev/null | base64 -d 2>/dev/null || echo "n/a"
}

pod_image() {
  local label="$1" container="${2:-}"
  if [ -n "$container" ]; then
    $KUBECTL get pods -l "$label" -o jsonpath="{.items[0].spec.containers[?(@.name==\"$container\")].image}" 2>/dev/null || echo "n/a"
  else
    $KUBECTL get pods -l "$label" -o jsonpath="{.items[0].spec.containers[0].image}" 2>/dev/null || echo "n/a"
  fi
}

helm_version() {
  local release="$1"
  $HELM list --filter "^${release}$" --short 2>/dev/null && return
  $HELM list --filter "^${release}$" -o json 2>/dev/null | grep -o '"app_version":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "n/a"
}

helm_app_version() {
  local release="$1"
  $HELM list -o json 2>/dev/null | python3 -c "
import sys, json
for r in json.load(sys.stdin):
    if r['name'] == '$release':
        print(r.get('app_version', 'n/a'))
        sys.exit()
print('n/a')
" 2>/dev/null || echo "n/a"
}

minikube_ip() {
  $MINIKUBE ip 2>/dev/null || echo "n/a"
}

# --------------------------------------------------------------------------- #
# Gather data
# --------------------------------------------------------------------------- #

echo "Gathering cluster information..."

MINIKUBE_IP=$(minikube_ip)

# Magento admin credentials
ADMIN_USER=$(secret_value magento-admin ADMIN_USER)
ADMIN_PASSWORD=$(secret_value magento-admin ADMIN_PASSWORD)
ADMIN_EMAIL=$(secret_value magento-admin ADMIN_EMAIL)
ADMIN_URI=$(secret_value magento-admin ADMIN_URI)

# Database credentials
DB_USER=$(secret_value database-credentials MYSQL_USER)
DB_PASSWORD=$(secret_value database-credentials MYSQL_PASSWORD)
DB_ROOT_PASSWORD=$(secret_value database-credentials MYSQL_ROOT_PASSWORD)
DB_NAME=$(secret_value database-credentials MYSQL_DATABASE)

# Elasticsearch (logging) credentials
ES_LOG_PASSWORD=$(secret_value elasticsearch-master-credentials password 2>/dev/null || echo "n/a")

# Image versions
IMG_MAGENTO=$(pod_image "app=magento,component=web" "magento-web")
IMG_NGINX=$(pod_image "app=magento,component=web" "nginx-exporter")
IMG_PHPFPM=$(pod_image "app=magento,component=web" "php-metrics-exporter")
IMG_DB=$(pod_image "app=db")
IMG_ES=$(pod_image "app=elasticsearch")
IMG_REDIS=$(pod_image "app=redis")
IMG_VARNISH=$(pod_image "app=varnish")
IMG_KIBANA=$(pod_image "app=kibana")

# Helm releases
VER_CERTMGR=$(helm_app_version cert-manager)
VER_INGRESS=$(helm_app_version ingress-nginx)
VER_SECRETGEN=$(helm_app_version secret-gsenerator)
VER_PROMETHEUS=$(helm_app_version kube-prometheus-stack)
VER_ES_LOG=$(helm_app_version elasticsearch)
VER_FLUENTBIT=$(helm_app_version fluent-bit)
VER_KIBANA=$(helm_app_version kibana)
VER_LOKI=$(helm_app_version loki)

# Service ClusterIPs
SVC_MAGENTO=$($KUBECTL get svc magento-web -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}' 2>/dev/null || echo "n/a")
SVC_DB=$($KUBECTL get svc db -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}' 2>/dev/null || echo "n/a")
SVC_ES=$($KUBECTL get svc elasticsearch -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}' 2>/dev/null || echo "n/a")
SVC_REDIS=$($KUBECTL get svc redis -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}' 2>/dev/null || echo "n/a")
SVC_VARNISH=$($KUBECTL get svc varnish -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}' 2>/dev/null || echo "n/a")
SVC_GRAFANA=$($KUBECTL get svc kube-prometheus-stack-grafana -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}' 2>/dev/null || echo "n/a")
SVC_PROMETHEUS=$($KUBECTL get svc kube-prometheus-stack-prometheus -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}' 2>/dev/null || echo "n/a")
SVC_KIBANA=$($KUBECTL get svc kibana-kibana -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}' 2>/dev/null || echo "n/a")

# Pod status counts
PODS_RUNNING=$($KUBECTL get pods --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
PODS_TOTAL=$($KUBECTL get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')

# --------------------------------------------------------------------------- #
# Render HTML
# --------------------------------------------------------------------------- #

cat > "$OUTPUT" <<HTMLEOF
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
<p class="subtitle">Generated: ${TIMESTAMP} &middot; Pods: ${PODS_RUNNING}/${PODS_TOTAL} running &middot; Minikube IP: ${MINIKUBE_IP}</p>

<div class="grid">

<!-- Magento Storefront -->
<div class="card">
  <h2>Magento Storefront</h2>
  <table>
    <tr><td>Frontend URL</td><td><a href="https://magento.test/" target="_blank">https://magento.test/</a></td></tr>
    <tr><td>Admin URL</td><td><a href="https://magento.test/${ADMIN_URI}" target="_blank">https://magento.test/${ADMIN_URI}</a></td></tr>
    <tr><td>Admin User</td><td class="mono">${ADMIN_USER}</td></tr>
    <tr><td>Admin Password</td><td class="mono">${ADMIN_PASSWORD}</td></tr>
    <tr><td>Admin Email</td><td class="mono">${ADMIN_EMAIL}</td></tr>
    <tr><td>Image</td><td class="mono">${IMG_MAGENTO}</td></tr>
    <tr><td>Service</td><td class="mono">magento-web (${SVC_MAGENTO})</td></tr>
  </table>
</div>

<!-- Database -->
<div class="card">
  <h2>Database (Percona)</h2>
  <table>
    <tr><td>Host</td><td class="mono">db:3306</td></tr>
    <tr><td>Service</td><td class="mono">${SVC_DB}</td></tr>
    <tr><td>Database</td><td class="mono">${DB_NAME}</td></tr>
    <tr><td>User</td><td class="mono">${DB_USER}</td></tr>
    <tr><td>Password</td><td class="mono">${DB_PASSWORD}</td></tr>
    <tr><td>Root Password</td><td class="mono">${DB_ROOT_PASSWORD}</td></tr>
    <tr><td>Image</td><td class="mono">${IMG_DB}</td></tr>
  </table>
  <code class="cmd">kubectl port-forward svc/db 3306:3306</code>
</div>

<!-- Elasticsearch (Magento) -->
<div class="card">
  <h2>Elasticsearch (Magento Search)</h2>
  <table>
    <tr><td>Host</td><td class="mono">elasticsearch:9200</td></tr>
    <tr><td>Service</td><td class="mono">${SVC_ES}</td></tr>
    <tr><td>Security</td><td><span class="badge badge-yellow">disabled</span></td></tr>
    <tr><td>Image</td><td class="mono">${IMG_ES}</td></tr>
  </table>
  <code class="cmd">kubectl port-forward svc/elasticsearch 9200:9200</code>
</div>

<!-- Redis -->
<div class="card">
  <h2>Redis</h2>
  <table>
    <tr><td>Host</td><td class="mono">redis:6379</td></tr>
    <tr><td>Service</td><td class="mono">${SVC_REDIS}</td></tr>
    <tr><td>DB 0</td><td>Cache</td></tr>
    <tr><td>DB 1</td><td>Full Page Cache</td></tr>
    <tr><td>DB 2</td><td>Sessions</td></tr>
    <tr><td>Image</td><td class="mono">${IMG_REDIS}</td></tr>
  </table>
  <code class="cmd">kubectl port-forward svc/redis 6379:6379</code>
</div>

<!-- Varnish -->
<div class="card">
  <h2>Varnish</h2>
  <table>
    <tr><td>Host</td><td class="mono">varnish:8080</td></tr>
    <tr><td>Service</td><td class="mono">${SVC_VARNISH}</td></tr>
    <tr><td>Cache Size</td><td>512 MB</td></tr>
    <tr><td>Admin Port</td><td class="mono">6081</td></tr>
    <tr><td>Image</td><td class="mono">${IMG_VARNISH}</td></tr>
  </table>
</div>

<!-- Grafana -->
<div class="card">
  <h2>Grafana</h2>
  <table>
    <tr><td>URL</td><td><a href="http://localhost:3000" target="_blank">http://localhost:3000</a></td></tr>
    <tr><td>Service</td><td class="mono">${SVC_GRAFANA}</td></tr>
    <tr><td>Username</td><td class="mono">admin</td></tr>
    <tr><td>Password</td><td class="mono">admin</td></tr>
    <tr><td>Chart Version</td><td class="mono">${VER_PROMETHEUS}</td></tr>
  </table>
  <code class="cmd">kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80</code>
</div>

<!-- Prometheus -->
<div class="card">
  <h2>Prometheus</h2>
  <table>
    <tr><td>URL</td><td><a href="http://localhost:9090" target="_blank">http://localhost:9090</a></td></tr>
    <tr><td>Service</td><td class="mono">${SVC_PROMETHEUS}</td></tr>
    <tr><td>Chart Version</td><td class="mono">${VER_PROMETHEUS}</td></tr>
  </table>
  <code class="cmd">kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090</code>
</div>

<!-- Kibana -->
<div class="card">
  <h2>Kibana</h2>
  <table>
    <tr><td>URL</td><td><a href="http://localhost:5601" target="_blank">http://localhost:5601</a></td></tr>
    <tr><td>Service</td><td class="mono">${SVC_KIBANA}</td></tr>
    <tr><td>Username</td><td class="mono">elastic</td></tr>
    <tr><td>Password</td><td class="mono">${ES_LOG_PASSWORD}</td></tr>
    <tr><td>ES Host</td><td class="mono">elasticsearch-master:9200</td></tr>
    <tr><td>Chart Version</td><td class="mono">${VER_KIBANA}</td></tr>
  </table>
  <code class="cmd">kubectl port-forward svc/kibana-kibana 5601:5601</code>
</div>

<!-- Helm Releases -->
<div class="card">
  <h2>Helm Releases</h2>
  <table>
    <tr><td>cert-manager</td><td class="mono">${VER_CERTMGR}</td></tr>
    <tr><td>nginx-ingress</td><td class="mono">${VER_INGRESS}</td></tr>
    <tr><td>secret-generator</td><td class="mono">${VER_SECRETGEN}</td></tr>
    <tr><td>kube-prometheus-stack</td><td class="mono">${VER_PROMETHEUS}</td></tr>
    <tr><td>elasticsearch (logging)</td><td class="mono">${VER_ES_LOG}</td></tr>
    <tr><td>fluent-bit</td><td class="mono">${VER_FLUENTBIT}</td></tr>
    <tr><td>kibana</td><td class="mono">${VER_KIBANA}</td></tr>
    <tr><td>loki</td><td class="mono">${VER_LOKI}</td></tr>
  </table>
</div>

<!-- Cluster Info -->
<div class="card">
  <h2>Cluster</h2>
  <table>
    <tr><td>Minikube IP</td><td class="mono">${MINIKUBE_IP}</td></tr>
    <tr><td>Pods Running</td><td>${PODS_RUNNING} / ${PODS_TOTAL}</td></tr>
    <tr><td>Ingress Host</td><td class="mono">magento.test</td></tr>
    <tr><td>TLS</td><td>Self-signed (cert-manager)</td></tr>
  </table>
  <code class="cmd">minikube dashboard</code>
</div>

</div>
</body>
</html>
HTMLEOF

echo "Services page written to: $OUTPUT"
echo "Open with: xdg-open $OUTPUT"

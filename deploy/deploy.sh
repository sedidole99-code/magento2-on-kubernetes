#!/usr/bin/env bash
#
# Magento 2 Kubernetes Build & Deploy Script
#
# Builds a new Docker image (tagged with git SHA), deploys it, and
# automatically detects whether a zero-downtime or maintenance-mode
# deployment is needed based on setup:db:status and app:config:status,
# similar to how capistrano-magento2 handles deployments.
#
# Usage:
#   ./deploy/deploy.sh                    # build + auto-detect deploy strategy
#   ./deploy/deploy.sh --zero-downtime    # build + force rolling update
#   ./deploy/deploy.sh --maintenance      # build + force maintenance mode deploy
#   ./deploy/deploy.sh --skip-build       # deploy only (image already built)
#
# Required environment variables:
#   COMPOSER_AUTH   Composer auth JSON (for builds)
#                   e.g. '{"http-basic":{"repo.magento.com":{"username":"...","password":"..."}}}'
#
# Optional environment variables:
#   IMAGE_REPO      Docker image repository (default: mymagento/magento2)
#   IMAGE_TAG       Override the auto-generated tag (default: git short SHA)
#   KUSTOMIZE       Path to kustomize binary
#   KUBECTL         Path to kubectl binary
#
set -euo pipefail

KUSTOMIZE="${KUSTOMIZE:-kustomize}"
KUBECTL="${KUBECTL:-kubectl}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOY_KUSTOMIZE_PATH="${SCRIPT_DIR}/deploy"

IMAGE_REPO="${IMAGE_REPO:-mymagento/magento2}"
NAMESPACE="${NAMESPACE:-default}"
NS_FLAG="${NS_FLAG:-}"
ENV="${ENV:-}"

# Override deploy kustomize path for environment overlays
if [ -n "$ENV" ] && [ "$ENV" != "default" ]; then
  DEPLOY_KUSTOMIZE_PATH="${PROJECT_DIR}/deploy/deploy-envs/${ENV}"
fi

# Bake namespace flag into KUBECTL so all commands are namespace-aware
if [ -n "$NS_FLAG" ]; then
  KUBECTL="$KUBECTL $NS_FLAG"
fi

SKIP_BUILD=false
FORCE_MODE="auto"

for arg in "$@"; do
  case "$arg" in
    --skip-build)      SKIP_BUILD=true ;;
    --zero-downtime)   FORCE_MODE="--zero-downtime" ;;
    --maintenance)     FORCE_MODE="--maintenance" ;;
    *)                 echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# --------------------------------------------------------------------------- #
# Helper functions
# --------------------------------------------------------------------------- #

log()  { echo "==> $*"; }
info() { echo "    $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

wait_for_ready_pod() {
  local attempts=0
  local max_attempts=60
  while [ $attempts -lt $max_attempts ]; do
    POD=$($KUBECTL get pods -l app=magento,component=web \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -n "$POD" ]; then
      echo "$POD"
      return 0
    fi
    sleep 5
    attempts=$((attempts + 1))
  done
  return 1
}

# --------------------------------------------------------------------------- #
# Determine image tag
# --------------------------------------------------------------------------- #

if [ -n "${IMAGE_TAG:-}" ]; then
  TAG="$IMAGE_TAG"
else
  TAG=$(git -C "$PROJECT_DIR" rev-parse --short HEAD)
  # Append -dirty if there are uncommitted changes
  if ! git -C "$PROJECT_DIR" diff --quiet HEAD 2>/dev/null; then
    TAG="${TAG}-dirty"
  fi
fi

NEW_IMAGE="${IMAGE_REPO}:${TAG}"
log "Image: $NEW_IMAGE"

# --------------------------------------------------------------------------- #
# Build Docker image
# --------------------------------------------------------------------------- #

if [ "$SKIP_BUILD" = false ]; then
  if [ -z "${COMPOSER_AUTH:-}" ]; then
    fail "COMPOSER_AUTH is not set. Export it before running deploy:\n  export COMPOSER_AUTH='{\"http-basic\":{\"repo.magento.com\":{\"username\":\"...\",\"password\":\"...\"}}}'"
  fi

  # Point Docker CLI at minikube's daemon so the image is available to kubelet
  eval $(minikube docker-env 2>/dev/null || true)

  log "Building Docker image..."
  docker build \
    --build-arg COMPOSER_AUTH="$COMPOSER_AUTH" \
    --target app \
    -f "${PROJECT_DIR}/src/Dockerfile" \
    -t "$NEW_IMAGE" \
    "${PROJECT_DIR}/src"

  info "Build complete: $NEW_IMAGE"
fi

# --------------------------------------------------------------------------- #
# Update kustomize image and build manifests
# --------------------------------------------------------------------------- #

log "Building deploy manifests..."

# Use kustomize images transformer to override the tag in all resources.
# Set the image, build manifests, then restore the file so the hardcoded
# tag never stays in version control. Trap ensures restore on failure/Ctrl+C.
KUST_BAK="$DEPLOY_KUSTOMIZE_PATH/kustomization.yaml.bak"
cp "$DEPLOY_KUSTOMIZE_PATH/kustomization.yaml" "$KUST_BAK"
trap 'mv -f "$KUST_BAK" "$DEPLOY_KUSTOMIZE_PATH/kustomization.yaml" 2>/dev/null || true' EXIT INT TERM
(cd "$DEPLOY_KUSTOMIZE_PATH" && $KUSTOMIZE edit set image "${IMAGE_REPO}=${NEW_IMAGE}")

MANIFESTS=$($KUSTOMIZE build "$DEPLOY_KUSTOMIZE_PATH")

# Restore kustomization.yaml
mv -f "$KUST_BAK" "$DEPLOY_KUSTOMIZE_PATH/kustomization.yaml"
trap - EXIT INT TERM

# Verify the image appears in the built manifests
if ! echo "$MANIFESTS" | grep -q "$NEW_IMAGE"; then
  fail "Image $NEW_IMAGE not found in built manifests"
fi

# --------------------------------------------------------------------------- #
# First deploy (no existing deployment)
# --------------------------------------------------------------------------- #

if ! $KUBECTL get deployment magento-web &>/dev/null; then
  log "No existing deployment found. Applying manifests for first deploy..."
  echo "$MANIFESTS" | $KUBECTL apply -f -
  log "Waiting for rollout..."
  $KUBECTL rollout status deployment/magento-web --timeout=600s
  log "Deploy complete!"
  exit 0
fi

# --------------------------------------------------------------------------- #
# Pre-deploy check: determine zero-downtime vs maintenance-mode
# --------------------------------------------------------------------------- #

DEPLOY_MODE="$FORCE_MODE"

if [ "$DEPLOY_MODE" = "auto" ]; then
  log "Running pre-deploy check with new image..."

  # Extract configmap names from the current deployment (includes kustomize hash suffixes)
  CONFIG_CM=$($KUBECTL get deployment magento-web \
    -o jsonpath='{.spec.template.spec.containers[0].envFrom[0].configMapRef.name}')
  ADDITIONAL_CM=$($KUBECTL get deployment magento-web \
    -o jsonpath='{.spec.template.spec.containers[0].envFrom[1].configMapRef.name}')

  # Clean up any previous check pod
  $KUBECTL delete pod magento-deploy-check --ignore-not-found --wait=true 2>/dev/null || true

  # Run a pod with the NEW image to check db:status and config:status against the current DB.
  # Exit 0 = all up-to-date (zero-downtime), non-zero = upgrades needed (maintenance).
  CHECK_EXIT=0
  $KUBECTL run magento-deploy-check \
    --image="$NEW_IMAGE" \
    --restart=Never \
    --rm \
    --attach \
    --quiet \
    --pod-running-timeout=2m \
    --override-type=strategic \
    --overrides="{
      \"spec\": {
        \"containers\": [{
          \"name\": \"magento-deploy-check\",
          \"image\": \"$NEW_IMAGE\",
          \"command\": [\"/bin/bash\", \"-c\"],
          \"args\": [\"php bin/magento setup:db:status --no-ansi 2>&1 && php bin/magento app:config:status --no-ansi 2>&1\"],
          \"env\": [
            {\"name\": \"DB_HOST\", \"value\": \"db\"},
            {\"name\": \"DB_NAME\", \"valueFrom\": {\"secretKeyRef\": {\"name\": \"database-credentials\", \"key\": \"MYSQL_DATABASE\"}}},
            {\"name\": \"DB_USER\", \"valueFrom\": {\"secretKeyRef\": {\"name\": \"database-credentials\", \"key\": \"MYSQL_USER\"}}},
            {\"name\": \"DB_PASS\", \"valueFrom\": {\"secretKeyRef\": {\"name\": \"database-credentials\", \"key\": \"MYSQL_PASSWORD\"}}}
          ],
          \"envFrom\": [
            {\"configMapRef\": {\"name\": \"$CONFIG_CM\"}},
            {\"configMapRef\": {\"name\": \"$ADDITIONAL_CM\"}}
          ],
          \"imagePullPolicy\": \"IfNotPresent\"
        }],
        \"restartPolicy\": \"Never\"
      }
    }" 2>&1 || CHECK_EXIT=$?

  if [ "$CHECK_EXIT" -eq 0 ]; then
    DEPLOY_MODE="--zero-downtime"
  else
    DEPLOY_MODE="--maintenance"
  fi
fi

# --------------------------------------------------------------------------- #
# Deploy: zero-downtime (rolling update)
# --------------------------------------------------------------------------- #

if [ "$DEPLOY_MODE" = "--zero-downtime" ]; then
  log "Zero-downtime deployment (no DB/config changes needed)"
  info "Applying manifests with rolling update..."
  echo "$MANIFESTS" | $KUBECTL apply -f -
  $KUBECTL rollout status deployment/magento-web --timeout=600s

  log "Post-deploy: flushing cache..."
  POD=$(wait_for_ready_pod) && {
    $KUBECTL exec "$POD" -- php bin/magento cache:flush 2>/dev/null || true
  }
fi

# --------------------------------------------------------------------------- #
# Deploy: maintenance mode (DB/config changes required)
# --------------------------------------------------------------------------- #

if [ "$DEPLOY_MODE" = "--maintenance" ]; then
  log "Maintenance-mode deployment (DB/config changes required)"

  # 1. Enable maintenance mode on current running pods
  POD=$($KUBECTL get pods -l app=magento,component=web \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [ -n "$POD" ]; then
    info "Enabling maintenance mode on current pods..."
    $KUBECTL exec "$POD" -- php bin/magento maintenance:enable 2>/dev/null || true
    info "Flushing cache..."
    $KUBECTL exec "$POD" -- php bin/magento cache:flush 2>/dev/null || true
  fi

  # 2. Scale down to prevent old code running against upgraded DB schema
  info "Scaling down magento-web to 0..."
  $KUBECTL scale deployment/magento-web --replicas=0
  $KUBECTL rollout status deployment/magento-web --timeout=120s

  # 3. Suspend cron to prevent cron jobs from running during upgrade
  info "Suspending magento-cron..."
  $KUBECTL patch cronjob magento-cron -p '{"spec":{"suspend":true}}' 2>/dev/null || true

  # 4. Apply new manifests — the init container on new pods will run:
  #    setup:db:status || setup:upgrade --keep-generated
  #    app:config:status || app:config:import
  info "Applying new manifests..."
  echo "$MANIFESTS" | $KUBECTL apply -f -

  # 5. Wait for rollout (new pods start, init containers handle DB/config upgrades)
  info "Waiting for rollout..."
  $KUBECTL rollout status deployment/magento-web --timeout=600s

  # 6. Resume cron
  info "Resuming magento-cron..."
  $KUBECTL patch cronjob magento-cron -p '{"spec":{"suspend":false}}' 2>/dev/null || true

  # 7. Post-deploy tasks on new pods
  log "Post-deploy tasks..."
  NEW_POD=$(wait_for_ready_pod) || fail "No running pod found after rollout"

  info "Flushing cache..."
  $KUBECTL exec "$NEW_POD" -- php bin/magento cache:flush 2>/dev/null || true
  info "Disabling maintenance mode..."
  $KUBECTL exec "$NEW_POD" -- php bin/magento maintenance:disable 2>/dev/null || true
fi

# --------------------------------------------------------------------------- #
# Cleanup old images
# --------------------------------------------------------------------------- #

log "Cleaning up old Docker images..."
OLD_IMAGES=$(docker image ls "$IMAGE_REPO" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
  | grep -v "$TAG" \
  | grep -v '<none>' \
  || true)

if [ -n "$OLD_IMAGES" ]; then
  echo "$OLD_IMAGES" | while read -r img; do
    info "Removing: $img"
    docker rmi "$img" 2>/dev/null || true
  done
else
  info "No old images to clean up"
fi

log "Deploy complete! Image: $NEW_IMAGE"

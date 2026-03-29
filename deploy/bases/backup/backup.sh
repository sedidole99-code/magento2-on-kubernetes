#!/usr/bin/env bash
#
# Backup helper for list and restore operations.
#
# Usage:
#   ./backup.sh list
#   ./backup.sh restore-db [backup-filename]
#   ./backup.sh restore-media [backup-filename]
#
set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"
if [ -n "${NS_FLAG:-}" ]; then
  KUBECTL="$KUBECTL $NS_FLAG"
fi
BUSYBOX="busybox@sha256:f9a104fddb33220ec80fc45a4e606c74aadf1ef7a3832eb0b05be9e90cd61f5f"
PERCONA="percona:8.0@sha256:5a09f82af8005b1df25cffa7a24472b2eaa57c4dbb355c050e24b2dd062e1005"

run_pod() {
  local name="$1" image="$2" cmd="$3"
  shift 3
  local vol_json="$*"

  $KUBECTL run "$name" --rm -i --restart=Never \
    --image="$image" \
    --override-type=strategic \
    --overrides="{
      \"spec\": {
        \"containers\": [{
          \"name\": \"$name\",
          \"image\": \"$image\",
          \"command\": [\"sh\", \"-c\", $(printf '%s' "$cmd" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')],
          \"volumeMounts\": $vol_json
        }],
        \"volumes\": [
          {\"name\": \"backup\", \"persistentVolumeClaim\": {\"claimName\": \"backup\"}},
          {\"name\": \"media\", \"persistentVolumeClaim\": {\"claimName\": \"media\"}}
        ]
      }
    }" 2>/dev/null
}

backup_vol='[{"name":"backup","mountPath":"/backup"}]'
both_vols='[{"name":"backup","mountPath":"/backup"},{"name":"media","mountPath":"/var/www/html/pub/media"}]'

case "${1:-}" in
  list)
    echo "=== Database Backups ==="
    run_pod backup-list-db "$BUSYBOX" "ls -lht /backup/db/ 2>/dev/null || echo '  (none)'" "$backup_vol"
    echo ""
    echo "=== Media Backups ==="
    run_pod backup-list-media "$BUSYBOX" "ls -lht /backup/media/ 2>/dev/null || echo '  (none)'" "$backup_vol"
    ;;

  restore-db)
    BACKUP_FILE="${2:-}"
    if [ -z "$BACKUP_FILE" ]; then
      echo "Finding latest database backup..."
      BACKUP_FILE=$(run_pod backup-find-db "$BUSYBOX" "ls -1t /backup/db/db-*.sql.gz 2>/dev/null | head -1" "$backup_vol" | tr -d '[:space:]')
    else
      BACKUP_FILE="/backup/db/$BACKUP_FILE"
    fi

    if [ -z "$BACKUP_FILE" ]; then
      echo "ERROR: No database backups found" >&2; exit 1
    fi

    echo "Restoring database from: $BACKUP_FILE"

    DB_USER=$($KUBECTL get secret database-credentials -o jsonpath='{.data.MYSQL_USER}' | base64 -d)
    DB_PASS=$($KUBECTL get secret database-credentials -o jsonpath='{.data.MYSQL_PASSWORD}' | base64 -d)
    DB_NAME=$($KUBECTL get secret database-credentials -o jsonpath='{.data.MYSQL_DATABASE}' | base64 -d)

    run_pod db-restore "$PERCONA" "gunzip -c $BACKUP_FILE | mysql -h db -u '$DB_USER' -p'$DB_PASS' '$DB_NAME' && echo 'Database restore complete'" "$backup_vol"
    ;;

  restore-media)
    BACKUP_FILE="${2:-}"
    if [ -z "$BACKUP_FILE" ]; then
      echo "Finding latest media backup..."
      BACKUP_FILE=$(run_pod backup-find-media "$BUSYBOX" "ls -1t /backup/media/media-*.tar.gz 2>/dev/null | head -1" "$backup_vol" | tr -d '[:space:]')
    else
      BACKUP_FILE="/backup/media/$BACKUP_FILE"
    fi

    if [ -z "$BACKUP_FILE" ]; then
      echo "ERROR: No media backups found" >&2; exit 1
    fi

    echo "Restoring media from: $BACKUP_FILE"
    run_pod media-restore "$BUSYBOX" "tar -xzf $BACKUP_FILE -C /var/www/html/pub/ && echo 'Media restore complete'" "$both_vols"
    ;;

  *)
    echo "Usage: $0 {list | restore-db [filename] | restore-media [filename]}" >&2
    exit 1
    ;;
esac

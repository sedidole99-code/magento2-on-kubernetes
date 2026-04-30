#!/bin/bash
# bootstrap-replica.sh — first-boot CLONE + replication setup for db-replica.
#
# Runs as an init container BEFORE the main mysqld starts. Idempotent: on
# subsequent boots it detects an already-initialized data directory and exits
# 0 immediately so the main container takes over normally.
#
# Flow on first boot:
#   1. Detect empty data directory.
#   2. Generate server.cnf with server_id = 100 + pod ordinal so each replica
#      has a unique id (db-replica-0 -> 100, db-replica-1 -> 101).
#   3. Start mysqld in initialize-then-temp mode, connect as root, issue
#      CLONE INSTANCE from db-primary. CLONE writes new data into the data
#      directory and auto-shuts mysqld down.
#   4. Restart mysqld briefly to issue CHANGE REPLICATION SOURCE TO ... +
#      START REPLICA, then shut down. The main container takes over.
#
# All subsequent boots: skip all of the above.

set -euo pipefail

DATA_DIR="/var/lib/mysql"
# Datadir = mount point. The PVC's `mysql` subPath is already mounted at
# /var/lib/mysql, so nesting another `/mysql` here would put data one level
# below the main container's default datadir and break startup.
DATA_SUBDIR="${DATA_DIR}"
BOOTSTRAP_MARKER="${DATA_SUBDIR}/.bootstrap-complete"
SERVER_CNF_DIR="/etc/my.cnf.d"
SERVER_CNF="${SERVER_CNF_DIR}/server-id.cnf"

# Pod ordinal -> server_id offset.
ORDINAL="${POD_NAME##*-}"
SERVER_ID=$((100 + ORDINAL))

# Always (re)write the server-id snippet — cheap, deterministic, lets the
# main container's mysqld pick up the right id even on plain restarts.
mkdir -p "$SERVER_CNF_DIR"
cat >"$SERVER_CNF" <<EOF
[mysqld]
server_id = ${SERVER_ID}
report_host = ${POD_NAME}.db-replica-headless
EOF

# Marker is written at the very end of a successful bootstrap. Using auto.cnf
# (created by --initialize-insecure before CLONE) as the marker is unsafe:
# any failure between init and CLONE leaves auto.cnf behind, and the next
# restart skips bootstrap on a half-baked data dir.
if [[ -f "$BOOTSTRAP_MARKER" ]]; then
  echo "[bootstrap-replica] $BOOTSTRAP_MARKER present — skipping CLONE"
  exit 0
fi

if [[ -d "$DATA_SUBDIR" ]] && [[ -n "$(ls -A "$DATA_SUBDIR" 2>/dev/null || true)" ]]; then
  echo "[bootstrap-replica] data dir non-empty without marker — wiping for fresh CLONE"
  rm -rf "${DATA_SUBDIR:?}"/* "${DATA_SUBDIR}"/.[!.]* 2>/dev/null || true
fi

echo "[bootstrap-replica] empty data directory; cloning from db-primary"

# Initialize an empty data dir so we can start mysqld. Using --initialize-insecure
# so we can connect as root without a password locally; CLONE INSTANCE will
# overwrite this temp dir with the donor's data.
mkdir -p "$DATA_SUBDIR"
chown -R mysql:mysql "$DATA_SUBDIR"

mysqld --initialize-insecure --user=mysql --datadir="$DATA_SUBDIR" \
       --log-error=/tmp/mysqld-init.log
echo "[bootstrap-replica] --initialize-insecure complete"

# Start mysqld in the background, on a temporary socket (no network).
mysqld --user=mysql --datadir="$DATA_SUBDIR" --skip-networking \
       --socket=/tmp/bootstrap.sock --pid-file=/tmp/bootstrap.pid \
       --log-error=/tmp/mysqld-bootstrap.log --daemonize

# Wait for it to come up.
for i in $(seq 1 30); do
  if mysqladmin -S /tmp/bootstrap.sock ping >/dev/null 2>&1; then break; fi
  sleep 1
done
if ! mysqladmin -S /tmp/bootstrap.sock ping >/dev/null 2>&1; then
  echo "[bootstrap-replica] mysqld never came up; dumping log:"
  tail -100 /tmp/mysqld-bootstrap.log || true
  exit 1
fi

# Pre-CLONE: connect as root (empty password from --initialize-insecure).
# Without -u, the client falls back to the OS user (mysql), which doesn't
# exist as a MySQL account at this point and yields ERROR 1045.
#
# After data copy, CLONE INSTANCE attempts to auto-restart mysqld. We run
# mysqld directly (no supervisor), so the restart fails with ERROR 3707:
# "Restart server failed (mysqld is not managed by supervisor process)".
# Per MySQL docs, the clone itself still completed successfully — the data
# is on disk. We treat 3707 as success and proceed; any other error is fatal.
set +e
clone_out=$(mysql -S /tmp/bootstrap.sock -u root 2>&1 <<SQL
SET GLOBAL clone_valid_donor_list = 'db-primary:3306';
CLONE INSTANCE FROM 'clone_user'@'db-primary':3306
  IDENTIFIED BY '$CLONE_PASSWORD';
SQL
)
clone_rc=$?
set -e
echo "[bootstrap-replica] CLONE client exit=${clone_rc}; output:"
echo "$clone_out"
if [[ $clone_rc -ne 0 ]] && ! grep -q "ERROR 3707" <<<"$clone_out"; then
  echo "[bootstrap-replica] CLONE INSTANCE failed (not the expected 3707); dumping mysqld log:"
  tail -200 /tmp/mysqld-bootstrap.log || true
  mysqladmin -S /tmp/bootstrap.sock -u root shutdown 2>/dev/null || true
  exit 1
fi

# CLONE INSTANCE auto-shuts the recipient mysqld. Wait for it to actually exit.
for i in $(seq 1 60); do
  if ! [[ -S /tmp/bootstrap.sock ]] && ! pgrep -f "datadir=$DATA_SUBDIR" >/dev/null; then
    break
  fi
  sleep 1
done

echo "[bootstrap-replica] CLONE complete; configuring replication source"

# Restart mysqld with default settings (still skip-networking so nothing else
# can reach us mid-bootstrap), issue CHANGE REPLICATION SOURCE TO + START
# REPLICA, then shut down. The main container will start mysqld for real.
mysqld --user=mysql --datadir="$DATA_SUBDIR" --skip-networking \
       --socket=/tmp/bootstrap.sock --pid-file=/tmp/bootstrap.pid \
       --log-error=/tmp/mysqld-replconf.log --daemonize

for i in $(seq 1 30); do
  if mysqladmin -S /tmp/bootstrap.sock ping >/dev/null 2>&1; then break; fi
  sleep 1
done
if ! mysqladmin -S /tmp/bootstrap.sock ping >/dev/null 2>&1; then
  echo "[bootstrap-replica] post-clone mysqld never came up; dumping log:"
  tail -100 /tmp/mysqld-replconf.log || true
  exit 1
fi

# CLONE INSTANCE copies user accounts from the donor, so root may now require
# a password — use --skip-password is unsafe, but socket auth still works as
# the unix mysql user via the auth_socket plugin if installed; otherwise rely
# on the donor's root credentials inherited via CLONE.
if ! mysql -S /tmp/bootstrap.sock -u root -p"${MYSQL_ROOT_PASSWORD:-}" <<SQL
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='db-primary',
  SOURCE_PORT=3306,
  SOURCE_USER='replica_user',
  SOURCE_PASSWORD='$REPLICA_PASSWORD',
  SOURCE_AUTO_POSITION=1,
  SOURCE_SSL=0,
  GET_SOURCE_PUBLIC_KEY=1;
START REPLICA;
SQL
then
  echo "[bootstrap-replica] CHANGE REPLICATION SOURCE failed; dumping log:"
  tail -100 /tmp/mysqld-replconf.log || true
  mysqladmin -S /tmp/bootstrap.sock -u root -p"${MYSQL_ROOT_PASSWORD:-}" shutdown 2>/dev/null || true
  exit 1
fi

mysqladmin -S /tmp/bootstrap.sock -u root -p"${MYSQL_ROOT_PASSWORD:-}" shutdown

# Marker last — anything between init and now failing means the next restart
# wipes and retries from scratch instead of skipping CLONE on a broken dir.
touch "$BOOTSTRAP_MARKER"
echo "[bootstrap-replica] bootstrap complete; main container will take over"

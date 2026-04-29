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
DATA_SUBDIR="${DATA_DIR}/mysql"
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

if [[ -f "${DATA_SUBDIR}/auto.cnf" ]]; then
  echo "[bootstrap-replica] data directory already initialized — skipping CLONE"
  exit 0
fi

echo "[bootstrap-replica] empty data directory detected; cloning from db-primary"

# Initialize an empty data dir so we can start mysqld. Using --initialize-insecure
# so we can connect as root without a password locally; CLONE INSTANCE will
# overwrite this temp dir with the donor's data.
mkdir -p "$DATA_SUBDIR"
chown -R mysql:mysql "$DATA_SUBDIR"

mysqld --initialize-insecure --user=mysql --datadir="$DATA_SUBDIR"

# Start mysqld in the background, on a temporary socket (no network).
mysqld --user=mysql --datadir="$DATA_SUBDIR" --skip-networking \
       --socket=/tmp/bootstrap.sock --pid-file=/tmp/bootstrap.pid \
       --daemonize

# Wait for it to come up.
for i in $(seq 1 30); do
  if mysqladmin -S /tmp/bootstrap.sock ping >/dev/null 2>&1; then break; fi
  sleep 1
done

mysql -S /tmp/bootstrap.sock <<SQL
-- Set the donor allow-list, then clone. CLONE will shut mysqld down on success.
SET GLOBAL clone_valid_donor_list = 'db-primary:3306';
CLONE INSTANCE FROM 'clone_user'@'db-primary':3306
  IDENTIFIED BY '$CLONE_PASSWORD';
SQL

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
       --daemonize

for i in $(seq 1 30); do
  if mysqladmin -S /tmp/bootstrap.sock ping >/dev/null 2>&1; then break; fi
  sleep 1
done

mysql -S /tmp/bootstrap.sock -u root <<SQL
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

mysqladmin -S /tmp/bootstrap.sock shutdown

echo "[bootstrap-replica] bootstrap complete; main container will take over"

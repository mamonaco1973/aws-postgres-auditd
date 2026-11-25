#!/bin/bash
# ==============================================================================
# FILE: setup_server.sh   (stage two of cloud-init, run from the clone)
# ==============================================================================
# Builds the whole lab on one host:
#   1) packages: auditd, PostgreSQL 18 (+ file_fdw), sysstat
#   2) the auditread group, auditd rules and config, rotation tooling
#   3) the audit-fdw wrappers in /usr/local/lib/audit-fdw (root, 0755)
#   4) PostgreSQL config, database, roles and both schemas
#   5) the native ingest timer
#   6) pgweb on port 80
#   7) seed demo events across a rotated, compressed chain
#   8) /root/bootstrap.done
#
# Expects POSTGRES_PASSWORD and AUDIT_READER_PASSWORD in the environment.
# Idempotent where possible: package installs, config edits and SQL are all
# safe to repeat. The seeding in step 7 adds new events and rotations on
# every run by design.
# ==============================================================================

set -euo pipefail

REPO=/opt/aws-postgres-auditd
SRV="$REPO/01-server"
PG_VER=18
PG_CONF_DIR="/etc/postgresql/$PG_VER/main/conf.d"

: "${POSTGRES_PASSWORD:?}" "${AUDIT_READER_PASSWORD:?}"

# ==============================================================================
# 1) Packages
# ==============================================================================
# The server is UTC so that DATE/TIME from ausearch, the raw epoch and
# PostgreSQL's timezone all agree without conversion.
# ==============================================================================
timedatectl set-timezone UTC

export DEBIAN_FRONTEND=noninteractive
for _ in $(seq 1 10); do
  apt-get update -y && break
  sleep 10
done
apt-get install -y auditd postgresql postgresql-contrib sysstat unzip jq

# ==============================================================================
# 2) auditd
# ==============================================================================

# ------------------------------------------------------------------------------
# Group and directory
# ------------------------------------------------------------------------------
# postgres joins auditread: read access to /var/log/audit, never write.
# ------------------------------------------------------------------------------
groupadd -f auditread
usermod -aG auditread postgres
install -d -m 0755 /data

install -m 0640 "$SRV/audit/data.rules" /etc/audit/rules.d/data.rules
bash "$SRV/audit/auditd_conf.sh"
install -o root -g root -m 0755 "$SRV/audit/audit-rotate" \
  /usr/local/sbin/audit-rotate
install -m 0644 "$SRV/audit/audit-fdw.tmpfiles" /etc/tmpfiles.d/audit-fdw.conf
systemd-tmpfiles --create /etc/tmpfiles.d/audit-fdw.conf

augenrules --load
systemctl restart auditd
# auditd re-groups the directory and the active file on start; files from
# before the log_group change keep "adm" and must be fixed by hand.
chgrp auditread /var/log/audit/audit.log.* 2>/dev/null || true

# ==============================================================================
# 3) audit-fdw wrappers
# ==============================================================================
install -d -o root -g root -m 0755 /usr/local/lib/audit-fdw
for f in common.sh raw-records events audit-ingest utf8-clean; do
  install -o root -g root -m 0755 "$SRV/fdw/$f" /usr/local/lib/audit-fdw/
done
install -o root -g root -m 0644 "$SRV/fdw/csv-repair.awk" \
  /usr/local/lib/audit-fdw/

# ==============================================================================
# 4) PostgreSQL
# ==============================================================================

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
# localhost only: pgweb runs on this host and there is no 5432 ingress.
# Memory sized for an 8 GB m7i.large, so the native-table benchmarks aren't
# starved by the 128 MB default.
# ------------------------------------------------------------------------------
cat > "$PG_CONF_DIR/auditd-lab.conf" <<'CONF'
listen_addresses = 'localhost'
timezone = 'UTC'
log_timezone = 'UTC'
shared_buffers = '2GB'
effective_cache_size = '6GB'
work_mem = '64MB'
maintenance_work_mem = '512MB'
CONF

install -d "/etc/systemd/system/postgresql@$PG_VER-main.service.d"
install -m 0644 "$SRV/systemd/postgresql-accounting.conf" \
  "/etc/systemd/system/postgresql@$PG_VER-main.service.d/accounting.conf"
systemctl daemon-reload

# Restart (not reload): postgres must pick up its new auditread membership.
systemctl restart postgresql
for _ in $(seq 1 30); do
  runuser -u postgres -- pg_isready -q && break
  sleep 1
done

# ------------------------------------------------------------------------------
# Schema
# ------------------------------------------------------------------------------
{
  echo "NOTE: $(date -u) building auditdb"
  for f in 01-database-roles 02-fdw-raw 03-fdw-events 04-search-function \
           05-native; do
    echo "NOTE: $f.sql"
    # Run from /tmp: postgres can't read root's working directory.
    (cd /tmp && runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 \
       -v postgres_password="$POSTGRES_PASSWORD" \
       -v audit_reader_password="$AUDIT_READER_PASSWORD" \
       -f "$SRV/sql/$f.sql")
  done
} >> /root/db_setup.log 2>&1

# ==============================================================================
# 5) Native ingest and scheduled rotation
# ==============================================================================
for u in audit-ingest.service audit-ingest.timer audit-rotate.service \
         audit-rotate.timer; do
  install -m 0644 "$SRV/systemd/$u" /etc/systemd/system/
done
systemctl daemon-reload
systemctl enable --now audit-ingest.timer audit-rotate.timer

# ==============================================================================
# 6) pgweb (same install as aws-postgres)
# ==============================================================================
# No connection is preconfigured: port 80 is open to the internet, and a
# saved connection would hand the audit trail to anyone who finds the URL.
# ==============================================================================
cd /tmp
wget -q https://github.com/sosedoff/pgweb/releases/download/v0.17.0/pgweb_linux_amd64.zip
unzip -o pgweb_linux_amd64.zip >> /root/pgweb.log 2>&1
install -m 0755 pgweb_linux_amd64 /usr/local/bin/pgweb

cat > /etc/systemd/system/pgweb.service <<'UNIT'
[Unit]
Description=Pgweb - Web UI for PostgreSQL
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/pgweb --listen=80 --bind 0.0.0.0
Restart=on-failure
User=root
WorkingDirectory=/root

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now pgweb
systemctl status pgweb --no-pager >> /root/pgweb.log 2>&1 || true

# ==============================================================================
# 7) Seed the demo
# ==============================================================================
# Events spread over a real chain: three rounds, rotate, repeat. Ends with
# the active file, an uncompressed .1 and several .gz files, so the
# walkthrough has history to read from day one.
# ==============================================================================
GEN="$SRV/bench/generate_events.sh"
for i in 1 2 3 4; do
  bash "$GEN" --rounds 3
  audit-rotate
done
bash "$GEN" --rounds 2

# ==============================================================================
# 8) Done
# ==============================================================================
touch /root/bootstrap.done
echo "NOTE: $(date -u) bootstrap complete"

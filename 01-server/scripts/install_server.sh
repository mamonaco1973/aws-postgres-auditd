#!/bin/bash
# ==============================================================================
# FILE: install_server.sh  (cloud-init user data, rendered by templatefile)
# ==============================================================================
# Clones this repository and hands off to setup_server.sh, which does the real
# work. The split exists because templatefile() rewrites every dollar-brace
# expression: keeping this stage tiny means only the three Terraform values
# below are templated, and the long setup script stays plain bash.
#
# Logs:
#   /root/userdata.log   everything from this stage and setup_server.sh
#   /root/db_setup.log   PostgreSQL schema and role creation
#   /root/pgweb.log      pgweb download and service status
# Marker:
#   /root/bootstrap.done written last; validate.sh waits for it over SSM.
# ==============================================================================

set -euo pipefail
exec >> /root/userdata.log 2>&1

# ------------------------------------------------------------------------------
# Values injected by Terraform
# ------------------------------------------------------------------------------
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD}"
export AUDIT_READER_PASSWORD="${AUDIT_READER_PASSWORD}"
REPO_URL="${REPO_URL}"

# ------------------------------------------------------------------------------
# Wait for the network
# ------------------------------------------------------------------------------
# cloud-init can start before outbound routing works; git would fail at once.
# ------------------------------------------------------------------------------
for _ in $(seq 1 30); do
  curl -s -o /dev/null https://github.com && break
  sleep 5
done

# ------------------------------------------------------------------------------
# Clone and run stage two
# ------------------------------------------------------------------------------
# Removing an old clone keeps a re-run of user data idempotent.
# ------------------------------------------------------------------------------
rm -rf /opt/aws-postgres-auditd
git clone --depth 1 "$REPO_URL" /opt/aws-postgres-auditd
bash /opt/aws-postgres-auditd/01-server/scripts/setup_server.sh

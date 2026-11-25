#!/bin/bash
# ==============================================================================
# FILE: auditd_conf.sh
# ==============================================================================
# Patches /etc/audit/auditd.conf for the lab. Idempotent: each setting is
# replaced in place (or appended once), so re-running changes nothing.
# ==============================================================================

set -euo pipefail

CONF=/etc/audit/auditd.conf

# ------------------------------------------------------------------------------
# set_conf KEY VALUE
# ------------------------------------------------------------------------------
set_conf() {
  local key="$1" value="$2"
  if grep -qE "^${key}[[:space:]]*=" "$CONF"; then
    sed -i -E "s|^${key}[[:space:]]*=.*|${key} = ${value}|" "$CONF"
  else
    echo "${key} = ${value}" >> "$CONF"
  fi
}

# ------------------------------------------------------------------------------
# Log group
# ------------------------------------------------------------------------------
# auditd re-applies this group to /var/log/audit and the active file on every
# start. The postgres OS user is a member, which gives it read access and
# nothing else (directory 0750, files 0640/0440, all owned by root).
# ------------------------------------------------------------------------------
set_conf log_group auditread

# ------------------------------------------------------------------------------
# Rotation is handed to /usr/local/sbin/audit-rotate
# ------------------------------------------------------------------------------
# auditd never compresses. Verified on 26.04 (auditd 4.1.2): SIGUSR1 always
# runs auditd's own rename-and-shift, even with "ignore", so logrotate plus a
# postrotate signal scrambles the chain. "ignore" stops auditd rotating on
# size; audit-rotate compresses the history itself, then sends SIGUSR1.
# ------------------------------------------------------------------------------
set_conf max_log_file_action ignore

# num_logs only bounds auditd's shift of UNCOMPRESSED .N files. audit-rotate
# never leaves one past .1, so this is just a safety margin.
set_conf num_logs 5

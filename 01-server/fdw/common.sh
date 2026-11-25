#!/bin/bash
# ==============================================================================
# FILE: common.sh   (sourced by the audit-fdw wrappers, not run directly)
# ==============================================================================
# Shared helpers for the programs PostgreSQL runs through file_fdw and
# COPY ... FROM PROGRAM. Installed root-owned 0755 in /usr/local/lib/audit-fdw,
# so the postgres OS user can run but never change them.
# ==============================================================================

# Callers already run strict; repeated here so the file is safe on its own.
set -euo pipefail

AUDIT_FDW_LIB=/usr/local/lib/audit-fdw
AUDIT_FDW_LOCK=/run/audit-fdw/rotate.lock
LIVE_DIR=/var/log/audit

# The exact header ausearch 4.1.2 prints for
#   --format csv --extra-keys --extra-obj2 --extra-time
# csv-repair.awk fails the query if a future release changes it, rather than
# silently shifting columns.
AUSEARCH_OPTS=(--format csv --extra-keys --extra-obj2 --extra-time)

# ------------------------------------------------------------------------------
# die MESSAGE: print to stderr (it lands in the PostgreSQL server log and in
# the error the client sees) and fail the query.
# ------------------------------------------------------------------------------
die() {
  echo "audit-fdw: $*" >&2
  exit 1
}

# ------------------------------------------------------------------------------
# check_dir DIR: allow only the live log directory and the benchmark corpora.
# The directory arrives on a command line built by SQL; this is the second
# check after the SQL-side one.
# ------------------------------------------------------------------------------
check_dir() {
  local dir="$1"
  if [ "$dir" = "$LIVE_DIR" ] || [[ "$dir" =~ ^/bench/corpus/[A-Za-z0-9_]+$ ]]; then
    printf '%s\n' "$dir"
  else
    die "directory not allowed: $dir"
  fi
}

# ------------------------------------------------------------------------------
# lock_shared DIR: hold the rotation lock (shared) on fd 9 until exit.
# Only the live directory rotates; the benchmark corpora are static.
# ------------------------------------------------------------------------------
lock_shared() {
  [ "$1" = "$LIVE_DIR" ] || return 0
  exec 9<"$AUDIT_FDW_LOCK" || die "cannot open $AUDIT_FDW_LOCK"
  flock -s 9
}

# ------------------------------------------------------------------------------
# list_files DIR: print the chain's file names, OLDEST FIRST.
# audit.log.N[.gz] sorts by N descending, the active audit.log comes last.
# audit_fdw.list_log_files() in SQL applies the same order.
# ------------------------------------------------------------------------------
list_files() {
  find "$1" -maxdepth 1 -type f -regextype posix-extended \
       -regex '.*/audit\.log(\.[0-9]+(\.gz)?)?' -printf '%f\n' |
    awk '{ n = 0
           if (match($0, /^audit\.log\.[0-9]+/)) n = substr($0, 11, RLENGTH - 10) + 0
           print n "\t" $0 }' |
    sort -k1,1nr | cut -f2
}

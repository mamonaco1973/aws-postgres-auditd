#!/bin/bash
# ==============================================================================
# FILE: generate_events.sh [--rounds N] [--verify]
# ==============================================================================
# Produces real, countable audit events under /data as two lab users.
#
# Each round does 13 operations, each exactly ONE data_watch event
# (verified on 26.04 with --verify):
#   alice: create, append, overwrite, chmod, rename within /data/alice,
#          rename across to /data/shared, create a private (0600) file
#   root:  chown the report to bob
#   bob:   mkdir, rmdir, create, delete, and a write to alice's private
#          file that fails with EACCES (success=no)
#
# Users are switched with sudo -u, but sudo doesn't set the audit login UID,
# and over SSM it is unset, so every event would say "system". Each operation
# therefore first writes the acting user's UID to /proc/self/loginuid (root
# may, since loginuid_immutable is 0), which is what a real login via
# pam_loginuid would have done. ausearch then names alice/bob as subject.
#
# Idempotent where possible: users and directories are created only if
# missing; file names carry a per-run tag so reruns never collide.
# ==============================================================================

set -euo pipefail

ROUNDS=1
VERIFY=0
OPS_PER_ROUND=13

while [ $# -gt 0 ]; do
  case "$1" in
    --rounds) ROUNDS="$2"; shift 2 ;;
    --verify) VERIFY=1; shift ;;
    *) echo "usage: $0 [--rounds N] [--verify]" >&2; exit 2 ;;
  esac
done
[[ "$ROUNDS" =~ ^[0-9]+$ ]] || { echo "bad --rounds" >&2; exit 2; }

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

# ==============================================================================
# Setup (not counted)
# ==============================================================================
for u in alice bob; do
  id "$u" >/dev/null 2>&1 || useradd -m -s /bin/bash "$u"
done
install -d -o alice -g alice -m 0755 /data/alice
install -d -o bob   -g bob   -m 0755 /data/bob
install -d -o root  -g root  -m 1777 /data/shared

# ------------------------------------------------------------------------------
# as USER CMD...: run CMD as USER with the audit login UID set to USER
# ------------------------------------------------------------------------------
as() {
  local user="$1"; shift
  local uid
  uid=$(id -u "$user")
  ( echo "$uid" > /proc/self/loginuid
    exec sudo -u "$user" -- "$@" )
}

# Separate setup events from counted ones by a whole second, because
# ausearch -ts has one-second resolution.
sleep 1.1
start_ts=$(date -u '+%m/%d/%y %H:%M:%S')
sleep 1.1

RUN=$(date -u +%Y%m%dT%H%M%S)-$$
echo "generate_events: run $RUN, $ROUNDS round(s)," \
     "expecting $((ROUNDS * OPS_PER_ROUND)) data_watch events"

for ((r = 1; r <= ROUNDS; r++)); do
  t="$RUN-$r"
  a=/data/alice/report-$t.txt

  as alice sh -c "echo draft > $a"                        # create
  as alice sh -c "echo more >> $a"                        # append
  as alice sh -c "echo final > $a"                        # overwrite
  as alice chmod 0640 "$a"                                # chmod
  as root  chown bob "$a"                                 # chown
  as alice mv "$a" "/data/alice/final-$t.txt"             # rename, same dir
  # Full target path: with a bare directory target, mv renames relative to
  # a directory fd and ausearch resolves that name against the CWD instead.
  as alice mv "/data/alice/final-$t.txt" "/data/shared/final-$t.txt"
  as bob   mkdir "/data/bob/dir-$t"                       # mkdir
  as bob   rmdir "/data/bob/dir-$t"                       # rmdir
  as bob   sh -c "echo tmp > /data/bob/tmp-$t.txt"        # create
  as bob   rm -f "/data/bob/tmp-$t.txt"                   # delete
  as alice sh -c "umask 077; echo secret > /data/alice/private-$t.txt"
  # Expected to fail with EACCES: the success=no event.
  as bob   sh -c "echo x >> /data/alice/private-$t.txt" 2>/dev/null || true
done

# ==============================================================================
# Optional verification against the log
# ==============================================================================
if [ "$VERIFY" -eq 1 ]; then
  sleep 3   # let auditd flush the last records
  got=$(LC_ALL=C TZ=UTC ausearch --input-logs -k data_watch -ts $start_ts \
          --format csv 2>/dev/null | tail -n +2 | grep -c -- "$RUN" || true)
  echo "generate_events: verify: expected $((ROUNDS * OPS_PER_ROUND))," \
       "found $got events naming run $RUN"
  [ "$got" -eq $((ROUNDS * OPS_PER_ROUND)) ] || exit 1
fi

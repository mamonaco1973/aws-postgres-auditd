#!/bin/bash
# ==============================================================================
# FILE: rotation_test.sh [--events N] [--every S] [--run-id ID]
# ==============================================================================
# Does reading the live chain stay consistent while it rotates underneath?
#
#   - alice writes exactly N files (N >= 10,000) under a fresh directory,
#     one data_watch event each (a shell ": > file" is a single openat)
#   - meanwhile audit-rotate runs every S seconds (it also triggers the
#     native ingest first, as it does in normal operation)
#   - meanwhile a loop COUNTs that directory's events through events_v,
#     recording every observation
#
# A count above N is a duplicate; a count lower than an earlier one is a gap.
# After the writer stops and the chain settles, the FDW count and the native
# count must both equal N, and the native table must hold no duplicates.
# Writes one summary row to results/rotation.csv and every observation to
# results/rotation-obs-<id>.csv.
#
# Not idempotent: each run creates a new directory and rotates the live
# logs several times.
# ==============================================================================

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
RES="$HERE/results"
N=10000
EVERY=3
ID=$(date -u +%Y%m%dT%H%M%S)

while [ $# -gt 0 ]; do
  case "$1" in
    --events) N="$2"; shift 2 ;;
    --every) EVERY="$2"; shift 2 ;;
    --run-id) ID="$2"; shift 2 ;;
    *) echo "usage: $0 [--events N] [--every S] [--run-id ID]" >&2; exit 2 ;;
  esac
done
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
mkdir -p "$RES"

pg() {
  (cd /tmp && runuser -u postgres -- psql -X -q -At -d auditdb \
     -v ON_ERROR_STOP=1 "$@")
}

DIR="/data/rot/$ID"
install -d -o root -g root -m 0755 /data/rot
install -d -o alice -g alice -m 0755 "$DIR"
OBS="$RES/rotation-obs-$ID.csv"
echo "ts_ms,phase,fdw_count" > "$OBS"
COUNT_SQL="SELECT count(*) FROM audit_fdw.events_v
           WHERE key = 'data_watch' AND obj_prime LIKE '$DIR/%'"

lost0=$(auditctl -s | awk '$1 == "lost" {print $2}')
ingest0=$(pg -c "SELECT coalesce(max(run_id), 0) FROM audit_native.ingest_log")

# ------------------------------------------------------------------------------
# Writer: N single-event file creations as alice, auid set to alice.
# Paced at 100 files per 0.5 s (about 50 s for 10,000) so that many rotations
# land in the middle of the stream; unpaced, bash writes 10,000 in a second.
# ------------------------------------------------------------------------------
(
  echo "$(id -u alice)" > /proc/self/loginuid
  exec sudo -u alice bash -c "for i in \$(seq 1 $N); do : > \"$DIR/f\$i\"
    (( i % 100 )) || sleep 0.5; done"
) &
writer=$!

# ------------------------------------------------------------------------------
# Rotator
# ------------------------------------------------------------------------------
(
  while kill -0 "$writer" 2>/dev/null; do
    audit-rotate >/dev/null 2>&1 || echo "rotation_test: audit-rotate failed" >&2
    sleep "$EVERY"
  done
) &
rotator=$!

# ------------------------------------------------------------------------------
# Reader: count while the writer runs
# ------------------------------------------------------------------------------
while kill -0 "$writer" 2>/dev/null; do
  c=$(pg -c "$COUNT_SQL" 2>/dev/null || echo ERR)
  echo "$(date +%s%3N),during,$c" >> "$OBS"
done
wait "$writer"
wait "$rotator" || true

# One more rotation after the writer stops, then let auditd flush.
audit-rotate >/dev/null
sleep 3
for _ in 1 2 3; do
  echo "$(date +%s%3N),settled,$(pg -c "$COUNT_SQL")" >> "$OBS"
done
systemctl start audit-ingest.service

# ------------------------------------------------------------------------------
# Verdict
# ------------------------------------------------------------------------------
final=$(tail -1 "$OBS" | cut -d, -f3)
native=$(pg -c "SELECT count(*) FROM audit_native.events
                WHERE key = 'data_watch' AND obj_prime LIKE '$DIR/%'")
native_distinct=$(pg -c "SELECT count(DISTINCT obj_prime) FROM audit_native.events
                WHERE key = 'data_watch' AND obj_prime LIKE '$DIR/%'")
read -r ingest_runs dup_skipped ckpt_errors < <(pg -F ' ' -c "
  SELECT count(*), coalesce(sum(rows_skipped_dup), 0),
         count(*) FILTER (WHERE exit_code IN (10, 11, 12))
  FROM audit_native.ingest_log WHERE run_id > $ingest0")
lost1=$(auditctl -s | awk '$1 == "lost" {print $2}')

python3 -B - "$OBS" "$N" <<'PY' > /tmp/rotation_verdict
import csv, sys
obs, n = sys.argv[1], int(sys.argv[2])
rows = [r for r in csv.DictReader(open(obs))]
during = [r["fdw_count"] for r in rows if r["phase"] == "during"]
errors = sum(1 for c in during if not c.isdigit())
vals = [int(c) for c in during if c.isdigit()]
dups = sum(1 for v in vals if v > n)
gaps = sum(1 for a, b in zip(vals, vals[1:]) if b < a)
print(len(vals), errors, dups, gaps)
PY
read -r observations query_errors dup_obs gap_obs < /tmp/rotation_verdict

pass=yes
[ "$final" -eq "$N" ] || pass=no
[ "$native" -eq "$N" ] || pass=no
[ "$native_distinct" -eq "$N" ] || pass=no
[ "$dup_obs" -eq 0 ] && [ "$gap_obs" -eq 0 ] && [ "$query_errors" -eq 0 ] || pass=no

[ -f "$RES/rotation.csv" ] || echo "run_id,events,rotate_every_s,observations,query_errors,dup_observations,gap_observations,fdw_final,native_final,native_distinct,ingest_runs,dup_rows_skipped,checkpoint_errors,lost_before,lost_after,pass" > "$RES/rotation.csv"
echo "$ID,$N,$EVERY,$observations,$query_errors,$dup_obs,$gap_obs,$final,$native,$native_distinct,$ingest_runs,$dup_skipped,$ckpt_errors,$lost0,$lost1,$pass" >> "$RES/rotation.csv"

echo "rotation_test $ID: N=$N observations=$observations errors=$query_errors" \
     "dups=$dup_obs gaps=$gap_obs fdw=$final native=$native" \
     "ingest_runs=$ingest_runs dup_skipped=$dup_skipped ckpt_err=$ckpt_errors" \
     "lost=$lost0->$lost1 pass=$pass"
[ "$pass" = yes ]

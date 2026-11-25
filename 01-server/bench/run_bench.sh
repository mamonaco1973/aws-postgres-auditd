#!/bin/bash
# ==============================================================================
# FILE: run_bench.sh   (run as root on the lab server)
# ==============================================================================
# Objective comparison of reading audit logs through file_fdw against
# conventional ingestion into indexed native tables, on identical data.
#
# Phases (pick with --phases, default all, in this order):
#   corpus       build /bench/corpus/<size> with synth_corpus.py
#   load         bench foreign tables + native table per size; load time and
#                on-disk sizes; index build times
#   queries      Q1-Q6, every contender, cold and warm (--runs each)
#   concurrency  pgbench -c 1/4/8 -T 60 for Q2 and Q3
#   freshness    20 single events: time until visible, FDW vs native
#   rotation     rotation_test.sh, 3 runs
#   summary      summarize.py -> results/SUMMARY.md
#
# Contenders, all on the same corpus:
#   fdw_raw       audit_bench.records_<size>   (regex-parsed raw records)
#   fdw_events    audit_bench.events_v_<size>  (ausearch, filtered in SQL)
#   fdw_search    search_events_in()           (ausearch filters; Q2, Q6)
#   native_noidx  audit_bench.native_<size>, no indexes at all
#   native_btree  + btree on event_time, key, serial
#   native_brin   BRIN on event_time instead of btree, + btree key, serial
#
# Cold run: sync, drop the page cache, restart PostgreSQL, then run.
# Warm run: one untimed run first, then the timed runs.
# Resources per run come from the PostgreSQL service cgroup (CPU time, bytes
# read, peak memory) - file_fdw's children (sh, zcat, ausearch, python, awk)
# live in that cgroup - and from pidstat -u -r -d 1, logged per run.
#
# audit-ingest.timer is paused while queries/concurrency run, and resumed on
# exit even on failure. auditctl -s lost/backlog are logged per phase.
#
# Not idempotent: every run appends new rows to the results CSVs (with a
# run_id), and the corpus phase rebuilds the corpus.
# ==============================================================================

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
RES="$HERE/results"
Q="$HERE/queries"
CORPUS_ROOT=/bench/corpus
TEMPLATES=/bench/templates.log
PGSVC=postgresql@18-main.service
RUN_ID=$(date -u +%Y%m%dT%H%M%S)

SIZES="100k 1m 10m"
RUNS=5
RAW_RUNS=""
PGBENCH_SECS=60
PHASES="corpus load queries concurrency freshness rotation summary"

while [ $# -gt 0 ]; do
  case "$1" in
    --sizes) SIZES="$2"; shift 2 ;;
    --runs) RUNS="$2"; shift 2 ;;
    --raw-runs) RAW_RUNS="$2"; shift 2 ;;
    --pgbench-secs) PGBENCH_SECS="$2"; shift 2 ;;
    --phases) PHASES="$2"; shift 2 ;;
    *) echo "usage: $0 [--sizes S] [--runs N] [--raw-runs N]" \
            "[--pgbench-secs N] [--phases P]" >&2; exit 2 ;;
  esac
done
RAW_RUNS="${RAW_RUNS:-$RUNS}"

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
mkdir -p "$RES" "$CORPUS_ROOT"
export PYTHONDONTWRITEBYTECODE=1

# ==============================================================================
# Helpers
# ==============================================================================

log() { echo "[$(date -u +%T)] $*"; }

has_phase() { [[ " $PHASES " == *" $1 "* ]]; }

records_for() {
  case "$1" in
    100k) echo 100000 ;; 1m) echo 1000000 ;; 10m) echo 10000000 ;;
    *) echo "unknown size $1" >&2; exit 2 ;;
  esac
}

# psql as postgres, from a directory postgres can read.
pg() {
  (cd /tmp && PGOPTIONS='-c client_min_messages=warning' \
     runuser -u postgres -- psql -X -q -d auditdb -v ON_ERROR_STOP=1 "$@")
}

pg_ready() {
  for _ in $(seq 1 60); do
    runuser -u postgres -- pg_isready -q && return 0
    sleep 0.5
  done
  echo "PostgreSQL did not come back" >&2
  exit 1
}

cgroup_dir() {
  echo "/sys/fs/cgroup$(systemctl show -p ControlGroup --value "$PGSVC")"
}

cg_cpu_us() { awk '/^usage_usec/ {print $2}' "$(cgroup_dir)/cpu.stat"; }

cg_read_bytes() {
  awk '{ for (i = 2; i <= NF; i++) if ($i ~ /^rbytes=/) {
           sub("rbytes=", "", $i); s += $i } } END { print s + 0 }' \
    "$(cgroup_dir)/io.stat"
}

cg_mem_peak() { cat "$(cgroup_dir)/memory.peak" 2>/dev/null || echo 0; }

# Writing to memory.peak resets it (kernel 6.12+); ignored if unsupported.
cg_mem_reset() { echo 0 > "$(cgroup_dir)/memory.peak" 2>/dev/null || true; }

auditctl_snapshot() {
  local phase="$1" when="$2"
  local lost backlog
  lost=$(auditctl -s | awk '$1 == "lost" {print $2}')
  backlog=$(auditctl -s | awk '$1 == "backlog" {print $2}')
  [ -f "$RES/auditctl.csv" ] || \
    echo "run_id,phase,when,ts,lost,backlog" > "$RES/auditctl.csv"
  echo "$RUN_ID,$phase,$when,$(date -u +%FT%TZ),$lost,$backlog" \
    >> "$RES/auditctl.csv"
}

cold_reset() {
  sync
  echo 3 > /proc/sys/vm/drop_caches
  systemctl restart "$PGSVC"
  pg_ready
}

# Pause the native ingest while timing, and always resume it.
TIMER_WAS_ACTIVE=0
pause_ingest() {
  if systemctl is-active -q audit-ingest.timer; then
    TIMER_WAS_ACTIVE=1
    systemctl stop audit-ingest.timer
  fi
}
resume_ingest() {
  if [ "$TIMER_WAS_ACTIVE" -eq 1 ]; then
    systemctl start audit-ingest.timer
    TIMER_WAS_ACTIVE=0
  fi
}
trap resume_ingest EXIT

manifest() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' \
    "$CORPUS_ROOT/$1/manifest.json" "$2"
}

# ==============================================================================
# Metadata, recorded every run so the numbers can be reproduced
# ==============================================================================
{
  echo "run_id,key,value"
  tok=$(curl -s -m 2 -X PUT http://169.254.169.254/latest/api/token \
          -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' || true)
  itype=$(curl -s -m 2 -H "X-aws-ec2-metadata-token: $tok" \
            http://169.254.169.254/latest/meta-data/instance-type || true)
  echo "$RUN_ID,instance_type,${itype:-unknown}"
  echo "$RUN_ID,vcpus,$(nproc)"
  echo "$RUN_ID,memory_gb,$(awk '/MemTotal/ {printf "%.1f", $2/1048576}' /proc/meminfo)"
  echo "$RUN_ID,kernel,$(uname -r)"
  echo "$RUN_ID,os,$(. /etc/os-release; echo "$PRETTY_NAME")"
  echo "$RUN_ID,postgresql,$(pg -At -c 'SHOW server_version')"
  echo "$RUN_ID,audit_userspace,$(dpkg-query -W -f '${Version}' auditd)"
  echo "$RUN_ID,shared_buffers,$(pg -At -c 'SHOW shared_buffers')"
  echo "$RUN_ID,runs,$RUNS"
  echo "$RUN_ID,raw_runs,$RAW_RUNS"
  echo "$RUN_ID,pgbench_secs,$PGBENCH_SECS"
  echo "$RUN_ID,sizes,$SIZES"
} > "$RES/metadata-$RUN_ID.csv"
log "run $RUN_ID: phases [$PHASES] sizes [$SIZES] runs $RUNS raw-runs $RAW_RUNS"

# ==============================================================================
# Phase: corpus
# ==============================================================================
if has_phase corpus; then
  # Templates: a fresh batch of real events, read back from the live chain.
  log "capturing template events"
  since=$(date +%s)
  sleep 1
  bash "$HERE/generate_events.sh" --rounds 40 >/dev/null
  sleep 3
  /usr/local/lib/audit-fdw/raw-records /var/log/audit |
    awk -v s="$since" 'match($0, /msg=audit\([0-9]+/) {
        t = substr($0, RSTART + 10, RLENGTH - 10) + 0
        if (t >= s) print }' > "$TEMPLATES"
  log "templates: $(wc -l < "$TEMPLATES") records"

  for size in $SIZES; do
    log "corpus $size"
    python3 -B "$HERE/synth_corpus.py" --templates "$TEMPLATES" \
      --records "$(records_for "$size")" --out "$CORPUS_ROOT/$size"
    chgrp -R auditread "$CORPUS_ROOT"
    chmod 0750 "$CORPUS_ROOT" "$CORPUS_ROOT/$size"
    chmod 0440 "$CORPUS_ROOT/$size"/*
  done
fi

# ==============================================================================
# Phase: load
# ==============================================================================
# Per size: foreign tables and views pointing at the corpus, then the native
# table loaded with the same ausearch CSV through COPY FROM PROGRAM, then the
# index variants, each build timed and sized.
# ==============================================================================
[ -f "$RES/load.csv" ] || echo "run_id,size,step,ms,rows,bytes" > "$RES/load.csv"

load_row() { echo "$RUN_ID,$1,$2,$3,$4,$5" >> "$RES/load.csv"; }

timed_sql() {
  # timed_sql SQL -> prints elapsed ms (wall clock, server side via psql)
  local t0 t1
  t0=$(date +%s%3N)
  pg -c "$1" >/dev/null
  t1=$(date +%s%3N)
  echo $((t1 - t0))
}

native_indexes() {
  # native_indexes SIZE none|btree|brin
  local s="$1" v="$2" t="audit_bench.native_$1"
  pg <<SQL
DROP INDEX IF EXISTS audit_bench.native_${s}_time_btree,
  audit_bench.native_${s}_time_brin, audit_bench.native_${s}_key,
  audit_bench.native_${s}_serial;
SQL
  case "$v" in
    none) ;;
    btree)
      pg -c "CREATE INDEX native_${s}_time_btree ON $t (event_time)"
      pg -c "CREATE INDEX native_${s}_key ON $t (key)"
      pg -c "CREATE INDEX native_${s}_serial ON $t (serial)" ;;
    brin)
      pg -c "CREATE INDEX native_${s}_time_brin ON $t USING brin (event_time)"
      pg -c "CREATE INDEX native_${s}_key ON $t (key)"
      pg -c "CREATE INDEX native_${s}_serial ON $t (serial)" ;;
  esac
  pg -c "ANALYZE $t"
}

if has_phase load; then
  for size in $SIZES; do
    dir="$CORPUS_ROOT/$size"
    log "load $size"
    pg -v s="$size" -v dir="$dir" <<'SQL'
SELECT format('DROP FOREIGN TABLE IF EXISTS audit_bench.raw_%s, audit_bench.events_%s CASCADE', :'s', :'s') \gexec
SELECT format('DROP TABLE IF EXISTS audit_bench.native_%s, audit_bench.stage_%s', :'s', :'s') \gexec
SELECT format($f$CREATE FOREIGN TABLE audit_bench.raw_%s (line text) SERVER audit_files
  OPTIONS (program %L, format 'csv', delimiter E'\x1f', quote E'\x01')$f$,
  :'s', '/usr/local/lib/audit-fdw/raw-records ' || :'dir') \gexec
SELECT format($f$CREATE VIEW audit_bench.records_%s AS SELECT p.* FROM audit_bench.raw_%s r,
  LATERAL audit_fdw.parse_record(r.line) p$f$, :'s', :'s') \gexec
SELECT format($f$CREATE FOREIGN TABLE audit_bench.events_%s (LIKE audit_fdw.events) SERVER audit_files
  OPTIONS (program %L, format 'csv', quote E'\x01')$f$,
  :'s', '/usr/local/lib/audit-fdw/events ' || :'dir') \gexec
SELECT format($f$CREATE VIEW audit_bench.events_v_%s AS SELECT t.* FROM audit_bench.events_%s e,
  LATERAL audit_fdw.to_event(ROW(e.*)::audit_fdw.events) t$f$, :'s', :'s') \gexec
SELECT format('CREATE UNLOGGED TABLE audit_bench.stage_%s (LIKE audit_fdw.events)', :'s') \gexec
SELECT format('CREATE TABLE audit_bench.native_%s (LIKE audit_fdw.event_t)', :'s') \gexec
SQL
    # Load = ausearch over the chain -> COPY -> typed INSERT, timed as one.
    ms_copy=$(timed_sql "COPY audit_bench.stage_$size FROM PROGRAM
      '/usr/local/lib/audit-fdw/events $dir' WITH (format csv, quote E'\x01')")
    ms_ins=$(timed_sql "INSERT INTO audit_bench.native_$size SELECT t.*
      FROM audit_bench.stage_$size s,
      LATERAL audit_fdw.to_event(ROW(s.*)::audit_fdw.events) t")
    pg -c "DROP TABLE audit_bench.stage_$size"
    ms_vac=$(timed_sql "VACUUM (ANALYZE) audit_bench.native_$size")
    rows=$(pg -At -c "SELECT count(*) FROM audit_bench.native_$size")
    tbytes=$(pg -At -c "SELECT pg_table_size('audit_bench.native_$size')")
    load_row "$size" copy_from_program "$ms_copy" "$rows" ""
    load_row "$size" typed_insert "$ms_ins" "$rows" ""
    load_row "$size" vacuum_analyze "$ms_vac" "$rows" ""
    load_row "$size" table "" "$rows" "$tbytes"
    load_row "$size" corpus_bytes_on_disk "" "$(manifest "$size" records)" \
      "$(manifest "$size" bytes_on_disk)"
    raw_bytes=$(for f in "$dir"/audit.log*; do zcat -f "$f"; done | wc -c)
    load_row "$size" corpus_bytes_uncompressed "" "" "$raw_bytes"

    for v in btree brin; do
      t0=$(date +%s%3N)
      native_indexes "$size" "$v"
      t1=$(date +%s%3N)
      ibytes=$(pg -At -c "SELECT pg_indexes_size('audit_bench.native_$size')")
      load_row "$size" "indexes_$v" $((t1 - t0)) "" "$ibytes"
    done
    native_indexes "$size" none
    log "load $size: $rows events, copy ${ms_copy} ms, insert ${ms_ins} ms"
  done
fi

# ==============================================================================
# Phase: queries
# ==============================================================================
QCSV="$RES/queries.csv"
[ -f "$QCSV" ] || echo "run_id,size,contender,query,mode,run,ms,rows,result_md5,cpu_s,read_bytes,mem_peak_bytes,pidstat_cpu_s,pidstat_peak_rss_kb,pidstat_read_kb,wall_ms" > "$QCSV"

# query_file CONTENDER Q -> path of the SQL file, or empty if not applicable
query_file() {
  local c="$1" q="$2"
  case "$c" in
    fdw_raw) echo "$Q/${q}_raw.sql" ;;
    fdw_search)
      case "$q" in q2|q6) echo "$Q/${q}_search.sql" ;; *) echo "" ;; esac ;;
    *) echo "$Q/$q.sql" ;;
  esac
}

relation_for() {
  case "$1" in
    fdw_raw) echo "audit_bench.records_$2" ;;
    fdw_events|fdw_search) echo "audit_bench.events_v_$2" ;;
    native_*) echo "audit_bench.native_$2" ;;
  esac
}

# run_one SIZE CONTENDER QUERY MODE RUN
run_one() {
  local size="$1" c="$2" q="$3" mode="$4" run="$5"
  local f rel out ps cpu0 cpu1 rb0 rb1 t0 t1 rows md5 timing ms
  f=$(query_file "$c" "$q")
  rel=$(relation_for "$c" "$size")
  out=$(mktemp)
  chown postgres "$out"     # psql -o writes it as postgres
  ps="$RES/pidstat/$RUN_ID-$size-$c-$q-$mode-$run.txt"
  mkdir -p "$RES/pidstat"

  cg_mem_reset
  cpu0=$(cg_cpu_us); rb0=$(cg_read_bytes)
  pidstat -u -r -d -h 1 \
    -C '^(postgres|ausearch|zcat|mawk|awk|utf8-clean|sh|flock|events|raw-records)$' \
    > "$ps" 2>&1 &
  local pspid=$!
  # ms = psql's \timing for the statement (client round trip, no connection
  # setup); wall_ms adds process start and connect, for reference.
  t0=$(date +%s%N)
  timing=$(pg -v rel="$rel" -v dir="$CORPUS_ROOT/$size" \
     -v a="$(manifest "$size" q2_from)" -v b="$(manifest "$size" q2_to)" \
     -v c="$(manifest "$size" q6_from)" -v d="$(manifest "$size" q6_to)" \
     -v serial="$(manifest "$size" q4_serial)" \
     -A -t -o "$out" -c '\timing on' -f "$f")
  t1=$(date +%s%N)
  ms=$(echo "$timing" | awk '/^Time: / { s += $2 } END { printf "%.1f", s }')
  kill "$pspid" 2>/dev/null; wait "$pspid" 2>/dev/null || true
  cpu1=$(cg_cpu_us); rb1=$(cg_read_bytes)

  rows=$(wc -l < "$out")
  md5=$(md5sum < "$out" | cut -c1-12)
  rm -f "$out"
  read -r ps_cpu ps_rss ps_rd < <(python3 -B "$HERE/summarize.py" \
    --pidstat "$ps")
  echo "$RUN_ID,$size,$c,$q,$mode,$run,$ms,$rows,$md5,$(awk "BEGIN{printf \"%.2f\", ($cpu1-$cpu0)/1e6}"),$((rb1 - rb0)),$(cg_mem_peak),$ps_cpu,$ps_rss,$ps_rd,$(( (t1 - t0) / 1000000 ))" >> "$QCSV"
}

CONTENDERS="fdw_raw fdw_events fdw_search native_noidx native_btree native_brin"
QUERIES="q1 q2 q3 q4 q5 q6"

if has_phase queries; then
  pause_ingest
  auditctl_snapshot queries before
  for size in $SIZES; do
    for c in $CONTENDERS; do
      case "$c" in
        native_noidx) native_indexes "$size" none ;;
        native_btree) native_indexes "$size" btree ;;
        native_brin)  native_indexes "$size" brin ;;
      esac
      n=$RUNS
      [ "$c" = fdw_raw ] && n=$RAW_RUNS
      for q in $QUERIES; do
        [ -n "$(query_file "$c" "$q")" ] || continue
        log "queries $size $c $q: $n cold + $n warm"
        for r in $(seq 1 "$n"); do
          cold_reset
          run_one "$size" "$c" "$q" cold "$r"
        done
        run_one "$size" "$c" "$q" warmup 0
        for r in $(seq 1 "$n"); do
          run_one "$size" "$c" "$q" warm "$r"
        done
      done
      # The no-pushdown evidence: Q2's plan, once per contender and size.
      f=$(query_file "$c" q2)
      if [ "$c" != fdw_search ]; then
        sed 's/^SELECT /EXPLAIN (ANALYZE, BUFFERS) SELECT /' "$f" > /tmp/explain.sql
        pg -v rel="$(relation_for "$c" "$size")" \
           -v a="$(manifest "$size" q2_from)" -v b="$(manifest "$size" q2_to)" \
           -f /tmp/explain.sql > "$RES/explain-$size-$c-q2.txt" 2>&1 || true
      fi
    done
    native_indexes "$size" none
  done
  auditctl_snapshot queries after
  resume_ingest
fi

# ==============================================================================
# Phase: concurrency
# ==============================================================================
CCSV="$RES/concurrency.csv"
[ -f "$CCSV" ] || echo "run_id,size,contender,query,clients,secs,transactions,tps,latency_ms,cpu_s" > "$CCSV"

if has_phase concurrency; then
  pause_ingest
  auditctl_snapshot concurrency before
  for size in $SIZES; do
    for c in fdw_events fdw_search native_noidx native_btree native_brin; do
      case "$c" in
        native_noidx) native_indexes "$size" none ;;
        native_btree) native_indexes "$size" btree ;;
        native_brin)  native_indexes "$size" brin ;;
      esac
      for q in q2 q3; do
        f=$(query_file "$c" "$q")
        [ -n "$f" ] || continue
        # pgbench takes no psql variables: substitute them into a copy.
        script="/tmp/pgbench-$c-$q.sql"
        sed -e "s/:rel/$(relation_for "$c" "$size")/g" \
            -e "s|:'dir'|'$CORPUS_ROOT/$size'|g" \
            -e "s/:a\b/$(manifest "$size" q2_from)/g" \
            -e "s/:b\b/$(manifest "$size" q2_to)/g" \
            -e '/^--/d' "$f" | tr '\n' ' ' > "$script"
        echo >> "$script"
        chmod 0644 "$script"
        for cl in 1 4 8; do
          log "concurrency $size $c $q -c $cl"
          cpu0=$(cg_cpu_us)
          outp=$(cd /tmp && runuser -u postgres -- pgbench -n -f "$script" \
                   -c "$cl" -j "$cl" -T "$PGBENCH_SECS" auditdb 2>&1) || true
          cpu1=$(cg_cpu_us)
          tx=$(echo "$outp" | sed -n 's/.*actually processed: \([0-9]*\).*/\1/p')
          tps=$(echo "$outp" | sed -n 's/^tps = \([0-9.]*\).*/\1/p')
          lat=$(echo "$outp" | sed -n 's/^latency average = \([0-9.]*\) ms/\1/p')
          echo "$RUN_ID,$size,$c,$q,$cl,$PGBENCH_SECS,${tx:-0},${tps:-0},${lat:-},$(awk "BEGIN{printf \"%.2f\", ($cpu1-$cpu0)/1e6}")" >> "$CCSV"
        done
      done
    done
    native_indexes "$size" none
  done
  auditctl_snapshot concurrency after
  resume_ingest
fi

# ==============================================================================
# Phase: freshness
# ==============================================================================
# One event at a time: how long until audit_fdw.events_v sees it, and how
# long until audit_native.events does. The ingest timer must be running.
# ==============================================================================
FCSV="$RES/freshness.csv"
[ -f "$FCSV" ] || echo "run_id,n,fdw_ms,native_ms" > "$FCSV"

if has_phase freshness; then
  systemctl start audit-ingest.timer
  auditctl_snapshot freshness before
  install -d -o alice -g alice -m 0755 /data/fresh
  for n in $(seq 1 20); do
    p="/data/fresh/f-$RUN_ID-$n"
    # Random 0-60 s pause first. Without it each event is written right
    # after the previous one was ingested, i.e. at the same point in the
    # timer's cycle, and native would always wait a full 60 s.
    sleep "$(awk -v s="$RANDOM" 'BEGIN { srand(s); printf "%.1f", rand() * 60 }')"
    t0=$(date +%s%3N)
    runuser -u alice -- sh -c "echo x > $p"
    fdw_ms="" native_ms=""
    while [ -z "$fdw_ms" ] || [ -z "$native_ms" ]; do
      now=$(date +%s%3N)
      if [ -z "$fdw_ms" ] && [ "$(pg -At -c "SELECT count(*) FROM audit_fdw.events_v WHERE obj_prime = '$p'")" -gt 0 ]; then
        fdw_ms=$(( $(date +%s%3N) - t0 ))
      fi
      if [ -z "$native_ms" ] && [ "$(pg -At -c "SELECT count(*) FROM audit_native.events WHERE obj_prime = '$p'")" -gt 0 ]; then
        native_ms=$(( $(date +%s%3N) - t0 ))
      fi
      [ $(( now - t0 )) -lt 300000 ] || break
      sleep 0.2
    done
    log "freshness $n: fdw ${fdw_ms:-timeout} ms, native ${native_ms:-timeout} ms"
    echo "$RUN_ID,$n,${fdw_ms:-},${native_ms:-}" >> "$FCSV"
  done
  auditctl_snapshot freshness after
fi

# ==============================================================================
# Phase: rotation
# ==============================================================================
if has_phase rotation; then
  for i in 1 2 3; do
    log "rotation test $i/3"
    auditctl_snapshot "rotation$i" before
    bash "$HERE/rotation_test.sh" --run-id "$RUN_ID-$i" || \
      log "rotation test $i FAILED (see results/rotation.csv)"
    auditctl_snapshot "rotation$i" after
  done
fi

# ==============================================================================
# Phase: summary
# ==============================================================================
if has_phase summary; then
  python3 -B "$HERE/summarize.py" --results "$RES" --corpus "$CORPUS_ROOT" \
    > "$RES/SUMMARY.md"
  log "wrote $RES/SUMMARY.md"
fi
log "done"

#!/usr/bin/env python3
# ==============================================================================
# FILE: summarize.py
# ==============================================================================
# Two jobs, stdlib only:
#
#   --pidstat FILE   reduce one pidstat -u -r -d -h log to three numbers
#                    (CPU seconds, peak summed RSS in kB, kB read) for
#                    run_bench.sh's per-run CSV row
#   --results DIR    turn the CSVs in DIR into SUMMARY.md on stdout
#
# For any (size, contender, query, mode) measured more than once across
# run_bench.sh invocations, only the most recent run_id is used.
# ==============================================================================

import argparse
import csv
import glob
import json
import os
import statistics
import sys

CONTENDERS = ["fdw_raw", "fdw_events", "fdw_search",
              "native_noidx", "native_btree", "native_brin"]
LABELS = {
    "fdw_raw": "FDW raw (records)",
    "fdw_events": "FDW ausearch (events_v)",
    "fdw_search": "FDW + ausearch filter (search_events)",
    "native_noidx": "native, no index",
    "native_btree": "native, btree",
    "native_brin": "native, BRIN time",
}
QUERIES = {
    "q1": "Q1 full count",
    "q2": "Q2 key + 1 h window",
    "q3": "Q3 group by user, action",
    "q4": "Q4 one event by serial",
    "q5": "Q5 top-10 files",
    "q6": "Q6 failed ops, 24 h",
}
SIZES = ["100k", "1m", "10m"]


# ==============================================================================
# pidstat reduction
# ==============================================================================

def reduce_pidstat(path):
    """Summarize one pidstat -h log.

    Args:
        path: output of `pidstat -u -r -d -h 1 -C ...`.

    Returns:
        (cpu_seconds, peak_rss_kb, read_kb). Each pidstat row is one process
        over one second, so %CPU/100 summed over rows is CPU-seconds; RSS is
        summed per timestamp and the maximum taken. Queries shorter than the
        first one-second sample report zeros.
    """
    cols, cpu, rd = None, 0.0, 0.0
    rss_by_ts = {}
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return 0.0, 0, 0
    with fh:
        for line in fh:
            parts = line.split()
            if not parts:
                continue
            if parts[0] == "#":
                # Header has a leading "#" token that data rows don't.
                cols = {name: i - 1 for i, name in enumerate(parts) if i}
                continue
            if cols is None or len(parts) < len(cols):
                continue
            try:
                ts = parts[cols["Time"]]
                cpu += float(parts[cols["%CPU"]]) / 100.0
                rd += float(parts[cols["kB_rd/s"]])
                rss_by_ts[ts] = rss_by_ts.get(ts, 0) + int(parts[cols["RSS"]])
            except (KeyError, ValueError, IndexError):
                continue
    peak = max(rss_by_ts.values()) if rss_by_ts else 0
    return round(cpu, 2), peak, int(rd)


# ==============================================================================
# CSV loading
# ==============================================================================

def read_csv(path):
    """Return the rows of a CSV file as dicts, or [] if it is missing."""
    if not os.path.exists(path):
        return []
    with open(path, newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def latest(rows, key_fields):
    """Keep only rows from the newest run_id for each key.

    Args:
        rows: CSV rows with a run_id column.
        key_fields: columns that identify one measurement series.

    Returns:
        The filtered rows.
    """
    newest = {}
    for r in rows:
        k = tuple(r[f] for f in key_fields)
        if r["run_id"] > newest.get(k, ""):
            newest[k] = r["run_id"]
    return [r for r in rows
            if r["run_id"] == newest[tuple(r[f] for f in key_fields)]]


def med(values):
    """Median of the non-empty numeric strings in values, or None."""
    nums = [float(v) for v in values if v not in ("", None)]
    return statistics.median(nums) if nums else None


def p95(values):
    """95th percentile (nearest rank) of numeric strings, or None."""
    nums = sorted(float(v) for v in values if v not in ("", None))
    if not nums:
        return None
    k = max(0, int(round(0.95 * len(nums) + 0.5)) - 1)
    return nums[min(k, len(nums) - 1)]


def fmt_ms(v):
    """Format milliseconds for a table: ms below 10 s, seconds above."""
    if v is None:
        return "–"
    if v >= 10000:
        return f"{v / 1000:.1f} s"
    if v >= 100:
        return f"{v:.0f} ms"
    return f"{v:.1f} ms"


def fmt_bytes(v):
    """Human-readable bytes."""
    if v in (None, ""):
        return "–"
    v = float(v)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if v < 1024 or unit == "TB":
            return f"{v:.0f} {unit}" if unit == "B" else f"{v:.1f} {unit}"
        v /= 1024
    return str(v)


# ==============================================================================
# Report sections
# ==============================================================================

def section_metadata(res):
    """Instance and software versions from the newest metadata file."""
    files = sorted(glob.glob(os.path.join(res, "metadata-*.csv")))
    if not files:
        return ["_No metadata recorded._", ""]
    rows = read_csv(files[-1])
    out = ["| Key | Value |", "|---|---|"]
    out += [f"| {r['key']} | {r['value']} |" for r in rows]
    return out + [""]


def section_corpus(res, corpus):
    """Corpus, load time and storage per size."""
    load = latest(read_csv(os.path.join(res, "load.csv")), ["size", "step"])
    by = {(r["size"], r["step"]): r for r in load}
    out = ["| Size | Records | Events | Raw log bytes | Log chain on disk "
           "(6 of 8 files .gz) | Native table | + btree indexes "
           "| + BRIN-variant indexes | Load (COPY + insert + vacuum) "
           "| btree build | BRIN-variant build |",
           "|---|---|---|---|---|---|---|---|---|---|---|"]
    for s in SIZES:
        mpath = os.path.join(corpus, s, "manifest.json")
        if not os.path.exists(mpath) and (s, "table") not in by:
            continue
        m = json.load(open(mpath)) if os.path.exists(mpath) else {}

        def g(step, field):
            return by.get((s, step), {}).get(field, "")

        load_ms = sum(float(g(st, "ms") or 0) for st in
                      ("copy_from_program", "typed_insert", "vacuum_analyze"))
        out.append(
            f"| {s} | {m.get('records', '–'):,} | {m.get('events', '–'):,} "
            f"| {fmt_bytes(g('corpus_bytes_uncompressed', 'bytes'))} "
            f"| {fmt_bytes(m.get('bytes_on_disk'))} "
            f"| {fmt_bytes(g('table', 'bytes'))} "
            f"| {fmt_bytes(g('indexes_btree', 'bytes'))} "
            f"| {fmt_bytes(g('indexes_brin', 'bytes'))} "
            f"| {fmt_ms(load_ms)} "
            f"| {fmt_ms(float(g('indexes_btree', 'ms') or 0))} "
            f"| {fmt_ms(float(g('indexes_brin', 'ms') or 0))} |")
    return out + [""]


def query_stats(res):
    """Median ms (and resources) per (size, contender, query, mode)."""
    rows = latest(read_csv(os.path.join(res, "queries.csv")),
                  ["size", "contender", "query", "mode"])
    stats = {}
    for r in rows:
        if r["mode"] not in ("cold", "warm"):
            continue
        k = (r["size"], r["contender"], r["query"], r["mode"])
        stats.setdefault(k, []).append(r)
    out = {}
    for k, rs in stats.items():
        out[k] = {
            "ms": med(r["ms"] for r in rs),
            "p95": p95(r["ms"] for r in rs),
            "n": len(rs),
            "cpu_s": med(r["cpu_s"] for r in rs),
            "read": med(r["read_bytes"] for r in rs),
            "mem": med(r["mem_peak_bytes"] for r in rs),
            "rows": rs[0]["rows"],
            "md5": {r["result_md5"] for r in rs},
        }
    return out


def section_queries(st):
    """Per size: median cold / warm latency for every query and contender."""
    out = []
    for s in SIZES:
        if not any(k[0] == s for k in st):
            continue
        out += [f"#### {s} records", "",
                "Median of the runs, cold / warm. – = not applicable.", "",
                "| Query | " + " | ".join(LABELS[c] for c in CONTENDERS) + " |",
                "|---|" + "---|" * len(CONTENDERS)]
        for q, qname in QUERIES.items():
            cells = []
            for c in CONTENDERS:
                cold = st.get((s, c, q, "cold"), {}).get("ms")
                warm = st.get((s, c, q, "warm"), {}).get("ms")
                cells.append("–" if cold is None and warm is None
                             else f"{fmt_ms(cold)} / {fmt_ms(warm)}")
            out.append(f"| {qname} | " + " | ".join(cells) + " |")
        out.append("")
    return out


def section_resources(st):
    """CPU, bytes read and memory for Q2 and Q3 at the largest size."""
    sizes = [s for s in SIZES if any(k[0] == s for k in st)]
    if not sizes:
        return []
    s = sizes[-1]
    out = [f"Resources per query at {s} (cold medians, from the PostgreSQL "
           "cgroup, so ausearch/zcat children are included):", "",
           "| Query | Contender | Wall | CPU s | Bytes read from disk "
           "| Peak memory (cgroup) |", "|---|---|---|---|---|---|"]
    for q in ("q2", "q3"):
        for c in CONTENDERS:
            v = st.get((s, c, q, "cold"))
            if not v:
                continue
            out.append(f"| {QUERIES[q]} | {LABELS[c]} | {fmt_ms(v['ms'])} "
                       f"| {v['cpu_s']:.2f} | {fmt_bytes(v['read'])} "
                       f"| {fmt_bytes(v['mem'])} |")
    return out + [""]


def section_consistency(st):
    """Do all event-level contenders return identical results?"""
    out = ["| Size | Query | Event-level contenders agree? | Rows |",
           "|---|---|---|---|"]
    for s in SIZES:
        for q in QUERIES:
            hashes, rows = set(), set()
            for c in CONTENDERS[1:]:
                for mode in ("cold", "warm"):
                    v = st.get((s, c, q, mode))
                    if v:
                        hashes |= v["md5"]
                        rows.add(v["rows"])
            if hashes:
                ok = "yes" if len(hashes) == 1 else f"NO ({len(hashes)} variants)"
                out.append(f"| {s} | {QUERIES[q]} | {ok} | {', '.join(sorted(rows))} |")
    return out + [""]


def section_concurrency(res):
    """pgbench throughput at 1, 4 and 8 clients."""
    rows = latest(read_csv(os.path.join(res, "concurrency.csv")),
                  ["size", "contender", "query", "clients"])
    if not rows:
        return ["_Not run._", ""]
    by = {(r["size"], r["contender"], r["query"], r["clients"]): r for r in rows}
    out = ["Queries per second (pgbench -T, so slow contenders finish few or "
           "no queries; latency is the average per query).", "",
           "| Size | Query | Contender | 1 client | 4 clients | 8 clients "
           "| Latency at 8 |", "|---|---|---|---|---|---|---|"]
    for s in SIZES:
        for q in ("q2", "q3"):
            for c in CONTENDERS:
                if not any((s, c, q, cl) in by for cl in ("1", "4", "8")):
                    continue
                tps = [by.get((s, c, q, cl), {}).get("tps", "") for cl in ("1", "4", "8")]
                lat = by.get((s, c, q, "8"), {}).get("latency_ms", "")
                out.append(f"| {s} | {QUERIES[q]} | {LABELS[c]} | "
                           + " | ".join(f"{float(t):.2f}" if t else "–" for t in tps)
                           + f" | {fmt_ms(float(lat)) if lat else '–'} |")
    return out + [""]


def section_freshness(res):
    """Median and p95 time-to-visible for one new event."""
    rows = read_csv(os.path.join(res, "freshness.csv"))
    if not rows:
        return ["_Not run._", ""], None
    rid = max(r["run_id"] for r in rows)
    rows = [r for r in rows if r["run_id"] == rid]
    f = [r["fdw_ms"] for r in rows]
    n = [r["native_ms"] for r in rows]
    out = [f"{len(rows)} single events, polled every 0.2 s.", "",
           "| Path | Median | p95 | Max | Timeouts |", "|---|---|---|---|---|",
           f"| FDW (`events_v`) | {fmt_ms(med(f))} | {fmt_ms(p95(f))} "
           f"| {fmt_ms(max(float(x) for x in f if x) if any(f) else None)} "
           f"| {sum(1 for x in f if not x)} |",
           f"| Native (60 s timer) | {fmt_ms(med(n))} | {fmt_ms(p95(n))} "
           f"| {fmt_ms(max(float(x) for x in n if x) if any(n) else None)} "
           f"| {sum(1 for x in n if not x)} |"]
    return out + [""], (med(f), med(n))


def section_rotation(res):
    """One line per rotation_test.sh run."""
    rows = read_csv(os.path.join(res, "rotation.csv"))
    if not rows:
        return ["_Not run._", ""]
    out = ["| Run | Events | Rotate every | FDW counts observed | Query errors "
           "| Duplicate obs. | Gap obs. | FDW final | Native final "
           "| Ingest runs | Dup rows skipped | Checkpoint errors | Lost "
           "| Pass |", "|---|" + "---|" * 13]
    for r in rows:
        lost = int(r["lost_after"]) - int(r["lost_before"])
        out.append(f"| {r['run_id']} | {r['events']} | {r['rotate_every_s']} s "
                   f"| {r['observations']} | {r['query_errors']} "
                   f"| {r['dup_observations']} | {r['gap_observations']} "
                   f"| {r['fdw_final']} | {r['native_final']} "
                   f"| {r['ingest_runs']} | {r['dup_rows_skipped']} "
                   f"| {r['checkpoint_errors']} | {lost} | {r['pass']} |")
    return out + [""]


def section_lost(res):
    """Kernel lost-event counter across every phase."""
    rows = read_csv(os.path.join(res, "auditctl.csv"))
    if not rows:
        return ["_No auditctl snapshots._", ""]
    lost = [int(r["lost"]) for r in rows if r["lost"].isdigit()]
    back = [int(r["backlog"]) for r in rows if r["backlog"].isdigit()]
    return [f"`auditctl -s` was read before and after every phase "
            f"({len(rows)} snapshots): lost ranged {min(lost)}–{max(lost)}, "
            f"backlog peaked at {max(back)} of 65536. "
            + ("No events were lost at any point."
               if max(lost) == min(lost) else
               "**The lost counter moved**; see results/auditctl.csv."), ""]


def findings(st, fresh):
    """Plain-English findings computed from the numbers."""
    out = []
    sizes = [s for s in SIZES if any(k[0] == s for k in st)]
    if not sizes:
        return out
    s = sizes[-1]

    def g(c, q, mode="warm"):
        return st.get((s, c, q, mode), {}).get("ms")

    fe, nb, nn, fs = (g("fdw_events", "q2"), g("native_btree", "q2"),
                      g("native_noidx", "q2"), g("fdw_search", "q2"))
    if fe and nb:
        out.append(f"- **Selective query (Q2) at {s}:** native with btree "
                   f"answered in {fmt_ms(nb)} (warm) against "
                   f"{fmt_ms(fe)} through `events_v`, about "
                   f"{fe / nb:,.0f}× faster.")
    if fe and fs:
        out.append(f"- **Pushing the filter into ausearch** "
                   f"(`search_events`) took Q2 from {fmt_ms(fe)} to "
                   f"{fmt_ms(fs)} ({'faster' if fs < fe else 'not faster'}). "
                   "ausearch still decompresses and reads every record; what "
                   "it saves is formatting non-matching events and "
                   "PostgreSQL parsing them.")
    if nn and nb:
        out.append(f"- **Indexes matter on native:** Q2 without indexes "
                   f"{fmt_ms(nn)} vs btree {fmt_ms(nb)}.")
    fr, fq = g("fdw_raw", "q1"), g("fdw_events", "q1")
    if fr and fq:
        out.append(f"- **Raw layer vs ausearch layer:** a full count costs "
                   f"{fmt_ms(fr)} through the regex parser and "
                   f"{fmt_ms(fq)} through ausearch at {s}.")
    if fresh and fresh[0] is not None and fresh[1] is not None:
        out.append(f"- **Freshness:** a new event was visible through the FDW "
                   f"after a median {fmt_ms(fresh[0])}; the native table "
                   f"needed a median {fmt_ms(fresh[1])} (60 s timer).")
    return out + [""]


def report(res, corpus):
    """Assemble SUMMARY.md."""
    st = query_stats(res)
    fresh_lines, fresh = section_freshness(res)
    out = ["# Benchmark summary: audit logs through file_fdw vs native tables",
           "",
           "Generated by `bench/summarize.py` from the CSVs in this directory.",
           "Every number below is measured; nothing is estimated.", "",
           "## Environment", ""]
    out += section_metadata(res)
    out += ["## Findings (computed)", ""] + findings(st, fresh)
    out += ["## Corpus, load and storage", ""] + section_corpus(res, corpus)
    out += ["## Query latency", ""] + section_queries(st)
    out += ["## Resources", ""] + section_resources(st)
    out += ["## Result consistency", "",
            "Each run's output is hashed. The raw layer answers in records, "
            "not events, so it is excluded.", ""] + section_consistency(st)
    out += ["## Concurrency", ""] + section_concurrency(res)
    out += ["## Freshness", ""] + fresh_lines
    out += ["## Rotation consistency", ""] + section_rotation(res)
    out += ["## Lost events", ""] + section_lost(res)
    return "\n".join(out)


def main():
    """Dispatch to the pidstat reducer or the report."""
    ap = argparse.ArgumentParser()
    ap.add_argument("--pidstat")
    ap.add_argument("--results")
    ap.add_argument("--corpus", default="/bench/corpus")
    args = ap.parse_args()
    if args.pidstat:
        cpu, rss, rd = reduce_pidstat(args.pidstat)
        print(cpu, rss, rd)
    elif args.results:
        print(report(args.results, args.corpus))
    else:
        ap.error("need --pidstat or --results")
        sys.exit(2)


if __name__ == "__main__":
    main()

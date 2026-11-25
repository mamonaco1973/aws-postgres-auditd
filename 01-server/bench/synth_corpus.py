#!/usr/bin/env python3
# ==============================================================================
# FILE: synth_corpus.py
# ==============================================================================
# Builds a synthetic audit log chain from REAL events, for the benchmarks.
#
#   1) Templates: real events captured from the live logs (generate_events.sh
#      output plus the sudo/PAM records around it). Each event's records stay
#      together and in order; auditd daemon events (DAEMON_*) are left out
#      because they use their own serial counter.
#   2) Replication: templates are replayed in random order with a monotonic
#      serial and timestamps advancing by random (exponential) gaps over a
#      fixed 7-day span, so a 1-hour window is the same fraction of every
#      corpus. The per-run tag in file names is replaced by a skewed file
#      number, so "top 10 files" has a real answer.
#   3) Layout: split by RECORD count into a chain shaped like /var/log/audit
#      (audit.log.8.gz ... audit.log.2.gz, audit.log.1, audit.log). Splits
#      fall mid-event on purpose: reading must correlate across files.
#   4) Validation: ausearch must parse the chain cleanly and find exactly the
#      number of events written.
#
# Usage:
#   python3 -B synth_corpus.py --templates FILE --records N --out DIR
#
# Not idempotent: DIR is replaced. Seeded, so the same inputs give the same
# corpus.
# ==============================================================================

import argparse
import gzip
import json
import os
import random
import re
import shutil
import subprocess
import sys
import time

# ------------------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------------------
HEADER_RE = re.compile(rb"^type=(\S+) msg=audit\((\d+)\.(\d+):(\d+)\): ")
TAG_RE = re.compile(rb"\d{8}T\d{6}-\d+-\d+")
SPAN_SECONDS = 7 * 24 * 3600
T0 = 1793491200                      # 2026-11-01 00:00:00 UTC
N_FILES = 8
SEED = 42
AUSEARCH_OPTS = ["--format", "csv", "--extra-keys", "--extra-obj2",
                 "--extra-time"]


def load_templates(path):
    """Group raw audit lines into events.

    Args:
        path: file of raw audit records, as found in /var/log/audit.

    Returns:
        A list of events; each event is a list of (type, rest) tuples where
        rest is the line after the "msg=audit(...): " header, as bytes.
    """
    events, current, key = [], [], None
    with open(path, "rb") as fh:
        for line in fh:
            m = HEADER_RE.match(line)
            if not m:
                continue
            rtype = m.group(1)
            if rtype.startswith(b"DAEMON_"):
                continue
            k = (m.group(2), m.group(3), m.group(4))
            if k != key and current:
                events.append(current)
                current = []
            key = k
            current.append((rtype, line[m.end():]))
    if current:
        events.append(current)
    return events


def generate(templates, target_records, out_dir):
    """Write the chain and return its manifest.

    Args:
        templates: events from load_templates().
        target_records: stop once this many records are written.
        out_dir: directory to create (replaced if it exists).

    Returns:
        A dict describing the corpus: counts, time range, files and the
        benchmark query parameters derived from it.
    """
    rng = random.Random(SEED)
    mean_len = sum(len(e) for e in templates) / len(templates)
    est_events = max(1, int(target_records / mean_len))
    mean_gap_ms = SPAN_SECONDS * 1000.0 / est_events

    if os.path.isdir(out_dir):
        shutil.rmtree(out_dir)
    os.makedirs(out_dir)

    per_file = -(-target_records // N_FILES)        # ceiling division
    names = ([f"audit.log.{n}.gz" for n in range(N_FILES, 1, -1)]
             + ["audit.log.1", "audit.log"])         # oldest first

    file_idx, in_file, fh = 0, 0, None
    records = events = dw_events = 0
    t_ms = T0 * 1000
    serial = 1000
    first_ms = None
    mid_dw_serial = None

    def open_next(i):
        """Open file i of the chain for writing (gzip for .gz names)."""
        p = os.path.join(out_dir, names[i])
        if p.endswith(".gz"):
            return gzip.open(p, "wb", compresslevel=6)
        return open(p, "wb", buffering=1 << 20)

    fh = open_next(0)
    while records < target_records:
        tmpl = templates[rng.randrange(len(templates))]
        t_ms += max(1, int(rng.expovariate(1.0 / mean_gap_ms)))
        serial += 1
        if first_ms is None:
            first_ms = t_ms
        # Skewed file number: a few files are very busy, most are rare.
        fileno = int(rng.paretovariate(1.16)) % 5000
        tag = b"%05d" % fileno
        hdr = b"msg=audit(%d.%03d:%d): " % (t_ms // 1000, t_ms % 1000, serial)
        is_dw = False
        for rtype, rest in tmpl:
            if b'key="data_watch"' in rest:
                is_dw = True
            line = b"type=" + rtype + b" " + hdr + TAG_RE.sub(tag, rest)
            fh.write(line)
            records += 1
            in_file += 1
            if in_file >= per_file and file_idx < N_FILES - 1:
                fh.close()
                file_idx += 1
                in_file = 0
                fh = open_next(file_idx)
        events += 1
        if is_dw:
            dw_events += 1
            if mid_dw_serial is None and records >= target_records // 2:
                mid_dw_serial = serial
    fh.close()
    # Any chain files never reached stay present but empty, like a quiet log.
    for n in names:
        p = os.path.join(out_dir, n)
        if not os.path.exists(p):
            if p.endswith(".gz"):
                gzip.open(p, "wb").close()
            else:
                open(p, "wb").close()

    last_ms = t_ms
    mid = (first_ms + (last_ms - first_ms) // 2) // 1000
    q2_from = mid - mid % 3600
    q6_from = q2_from - q2_from % 86400
    sizes = {n: os.path.getsize(os.path.join(out_dir, n)) for n in names}
    return {
        "dir": out_dir,
        "records": records,
        "events": events,
        "data_watch_events": dw_events,
        "templates": len(templates),
        "first_epoch": first_ms / 1000.0,
        "last_epoch": last_ms / 1000.0,
        "files": names,
        "file_bytes": sizes,
        "bytes_on_disk": sum(sizes.values()),
        "q2_from": q2_from, "q2_to": q2_from + 3600,
        "q4_serial": mid_dw_serial,
        "q6_from": q6_from, "q6_to": q6_from + 86400,
    }


def validate(manifest):
    """Run ausearch over the chain and compare the event count.

    Args:
        manifest: dict from generate(); updated in place with the result.

    Returns:
        True if ausearch found exactly manifest["events"] events.
    """
    paths = [os.path.join(manifest["dir"], n) for n in manifest["files"]]
    zc = subprocess.Popen(["zcat", "-f", "--"] + paths, stdout=subprocess.PIPE)
    au = subprocess.Popen(["ausearch"] + AUSEARCH_OPTS, stdin=zc.stdout,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          env=dict(os.environ, LC_ALL="C", TZ="UTC"))
    zc.stdout.close()
    lines = 0
    for _ in au.stdout:
        lines += 1
    err = au.stderr.read().decode(errors="replace").strip()
    au.wait()
    zc.wait()
    raw = sum(1 for _ in zcat_lines(paths))
    manifest["validated_events"] = max(0, lines - 1)     # minus the header
    manifest["validated_records"] = raw
    manifest["ausearch_exit"] = au.returncode
    manifest["ausearch_stderr"] = err[:500]
    return (au.returncode == 0
            and manifest["validated_events"] == manifest["events"]
            and raw == manifest["records"])


def zcat_lines(paths):
    """Yield every line of the chain, decompressing .gz files."""
    for p in paths:
        opener = gzip.open if p.endswith(".gz") else open
        with opener(p, "rb") as fh:
            yield from fh


def main():
    """Parse arguments, build, validate and describe one corpus."""
    ap = argparse.ArgumentParser(
        description="Build a synthetic audit log chain from real events.")
    ap.add_argument("--templates", required=True)
    ap.add_argument("--records", required=True, type=int)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    t = time.time()
    templates = load_templates(args.templates)
    if not templates:
        sys.exit("synth_corpus: no template events in " + args.templates)
    manifest = generate(templates, args.records, args.out)
    manifest["generate_seconds"] = round(time.time() - t, 1)
    ok = validate(manifest)
    with open(os.path.join(args.out, "manifest.json"), "w") as fh:
        json.dump(manifest, fh, indent=2)
    print(json.dumps({k: manifest[k] for k in
                      ("records", "events", "validated_events",
                       "validated_records", "bytes_on_disk",
                       "generate_seconds")}))
    if not ok:
        sys.exit("synth_corpus: VALIDATION FAILED: " + manifest["ausearch_stderr"])


if __name__ == "__main__":
    main()

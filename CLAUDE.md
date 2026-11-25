# CLAUDE.md — aws-postgres-auditd

## What This Project Does

One Ubuntu 26.04 EC2 host where **PostgreSQL 18 reads the Linux audit logs
as tables**, with no load step: `file_fdw` foreign tables run wrapper
scripts that pipe `/var/log/audit` (active, rotated and `.gz` files) through
`zcat -f` and, for the event layer, `ausearch`. A conventional pipeline (a
60-second `ausearch --checkpoint` ingest into an indexed table) runs beside
it, and `01-server/bench/` measures the two against each other.

Single Terraform phase in `01-server/`. No modules, no workspaces, no Packer.

## Commands

```bash
./check_env.sh          # aws, terraform, jq in PATH + STS check
./apply.sh              # check env, terraform init + apply, then validate
./validate.sh           # wait for /root/bootstrap.done over SSM, print URL
./destroy.sh            # tear everything down

# on the server (aws ssm start-session --region us-east-2 --target <id>)
sudo bash /opt/aws-postgres-auditd/01-server/bench/generate_events.sh --rounds 2 --verify
sudo audit-rotate                         # force a rotation (+ ingest first)
sudo systemctl start audit-ingest         # force a native ingest now
# benchmarks: run detached. SSM Run Command kills the whole process tree
# (nohup included) at its execution timeout, so use systemd-run:
sudo systemd-run --unit=bench --collect \
  -p StandardOutput=file:/root/bench.log -p StandardError=inherit \
  -p WorkingDirectory=/opt/aws-postgres-auditd/01-server/bench \
  bash run_bench.sh                      # all phases; see --help options
```

`apply.sh` and `destroy.sh` export both `AWS_DEFAULT_REGION` and `AWS_REGION`:
the CLI prefers `AWS_REGION`, and an inherited `us-east-1` would otherwise win.
cloud-init clones the public repo, so changes must be pushed before a deploy
picks them up.

## Architecture

```
VPC auditd-vpc 10.0.0.0/24 (us-east-2)
  └── auditd-subnet-1 10.0.0.0/26 (us-east-2a, public, IGW)
        └── auditd-server  m7i.large, Ubuntu 26.04, 60 GB gp3, SSM only
              ├── auditd 4.1.2      -w /data -p wa -k data_watch, -b 65536
              ├── PostgreSQL 18.x   localhost:5432, db auditdb, TZ UTC
              │     ├── audit_fdw     file_fdw over /var/log/audit
              │     ├── audit_native  ingested copy, every 60 s
              │     └── audit_bench   benchmark objects (postgres only)
              ├── pgweb 0.17.0      0.0.0.0:80, no saved connection
              └── /usr/local/lib/audit-fdw/  wrappers (root 0755)
```

- **m7i.large** on purpose: burstable t3 credits would distort benchmarks.
- **No 5432 ingress**, no SSH: `auditd-http-sg` allows TCP/80 only.
- Every name is prefixed `auditd-` so the stack coexists with aws-postgres.

## Key Files

| File | Purpose |
|------|---------|
| `01-server/server.tf` | 26.04 AMI lookup (Canonical, `ubuntu-resolute-26.04-amd64-server-*`), instance, outputs |
| `01-server/networking.tf` / `security.tf` / `role.tf` / `secret.tf` | VPC + 1 subnet; `auditd-http-sg`; `auditd-ec2-ssm-role` (SSM core only); `auditd-postgres-credentials` |
| `01-server/scripts/install_server.sh` | cloud-init (templatefile): clone repo, run stage two |
| `01-server/scripts/setup_server.sh` | stage two: packages, auditd, wrappers, PostgreSQL, pgweb, seed demo |
| `01-server/audit/` | `data.rules`, `auditd_conf.sh`, `audit-rotate`, tmpfiles for the lock |
| `01-server/fdw/` | `common.sh`, `raw-records`, `events`, `utf8-clean`, `csv-repair.awk`, `audit-ingest` |
| `01-server/sql/01..05-*.sql` | roles/schemas, raw layer, ausearch layer, `search_events`, native |
| `01-server/sql/queries.sql` | the README "Try it" walkthrough |
| `01-server/systemd/` | ingest + rotate services/timers, PostgreSQL cgroup accounting drop-in |
| `01-server/bench/` | generator, corpus synthesizer, query files, `run_bench.sh`, `rotation_test.sh`, `summarize.py`, `results/SUMMARY.md` |
| `make_diagram.py` | regenerates `architecture-{light,dark}.svg` |

## Auth Pattern

- AWS: local CLI credentials (SSO), nothing in code. Region `us-east-2`.
- Passwords: two `random_password`s in one Secrets Manager secret,
  `auditd-postgres-credentials` (`postgres_password`, `audit_reader_password`,
  plus host/port/database), `recovery_window_in_days = 0`. They also reach
  the instance through user data (same as aws-postgres; lab only).
- PostgreSQL roles: `postgres` (superuser; owns foreign tables and
  `SECURITY DEFINER` functions, because `program` needs
  `pg_execute_server_program`); `audit_reader` (LOGIN, SELECT on `audit_fdw`
  and `audit_native`, EXECUTE on `search_events`, `statement_timeout 5min`).
- OS: group `auditread` = auditd `log_group`; `postgres` is a member: read
  `/var/log/audit`, never write.

## pgweb Connection

pgweb starts with no connection; enter it in the browser:

| Field    | Value |
|----------|-------|
| Host     | `localhost` |
| Port     | `5432` |
| Database | `auditdb` |
| Username | `audit_reader` |
| Password | `aws secretsmanager get-secret-value --region us-east-2 --secret-id auditd-postgres-credentials --query SecretString --output text \| jq -r .audit_reader_password` |
| SSL mode | `disable` |

## Logs

| Where | What |
|---|---|
| `/root/userdata.log` | cloud-init stage one and two |
| `/root/db_setup.log` | SQL 01–05 output |
| `/root/pgweb.log` | pgweb download and service status |
| `/root/bootstrap.done` | marker validate.sh waits for |
| `journalctl -u audit-ingest` | native ingest runs (also `audit_native.ingest_log`) |
| `/var/log/postgresql/` | wrapper stderr (e.g. `csv-repair: repaired N rows`) |

## Verified on 26.04

Measured on Ubuntu 26.04.1, kernel 7.0.0-aws, auditd/audit-userspace
1:4.1.2-1ubuntu0.1, PostgreSQL 18.6, m7i.large.

1. **stdin.** ausearch reads stdin only when it is a **pipe**. With stdin on
   `/dev/null` (what PostgreSQL gives a `program`) or a regular-file redirect
   (`ausearch < file`) it silently reads the **system logs** instead. So the
   trap on this release is "silently the wrong data", not "silently empty".
   Wrappers always pipe `zcat -f <chain>` in. Events whose records span two
   files: tested by splitting a log mid-event (4 records / 3 records) — the
   piped stream gives output identical to the unsplit file; reading the
   files separately turns it into two partial events.
2. **Exit codes.** Exit 1 means "`<no matches>`" **and** also bad option,
   missing file and empty input. The wrappers accept exit 1 only when stderr
   contains exactly `<no matches>`. Checkpoint errors: 10 (invalid data —
   seen when the checkpointed file had been compressed away), 11, 12.
   `--checkpoint` **does not work on stdin** ("checkpointing stdin is not
   supported", no file written), so the native ingest uses `--input-logs`.
3. **No pushdown.** `file_fdw` runs the program and reads all of it on every
   scan; `EXPLAIN ANALYZE` shows "Rows Removed by Filter". `search_events`
   puts `-ts/-te/-k` on the ausearch command line instead.
4. **CSV.** Header with `--extra-keys --extra-obj2 --extra-time` (25 columns):
   `NODE,EVENT,DATE,TIME,YEAR,MONTH,DAY,WEEKDAY,HOUR,MILLI,GMT_OFFSET,SERIAL_NUM,EVENT_KIND,SESSION,SUBJ_PRIME,SUBJ_SEC,SUBJ_KIND,ACTION,RESULT,OBJ_PRIME,OBJ_SEC,OBJ2,OBJ_KIND,HOW,KEY`.
   Not RFC 4180: **nothing is quoted**. A comma in a name adds a column (also
   `chmod 1777` puts `sticky,0777` in OBJ2); `"` appears bare and breaks
   PostgreSQL's default CSV quote (`unterminated CSV quoted field`).
   Newlines print as `\012`. Non-UTF-8 is escaped (`\xff`) for absolute
   paths but **emitted raw when ausearch joins CWD + a relative name**, which
   makes PostgreSQL reject the whole query. Fixes: `quote E'\x01'`,
   `utf8-clean` (escapes invalid bytes as `\xNN`), `csv-repair.awk`
   (re-splits rows with >25 fields using OBJ_SEC as the anchor; a name
   containing `,<digits>,` still splits wrong — e.g. `a,1,b.txt`). The header
   is checked; a different one fails the query. `-i` conflicts with
   `--format csv`.
5. **Time.** DATE/TIME follow `TZ` (America/Chicago printed `-06:00`), but
   GMT_OFFSET is printed, so `to_event()` builds an exact timestamptz. All
   1,909 events in a test matched `audit_fdw.records` epochs to the
   millisecond on (serial, time). Serial alone is not unique: auditd's own
   DAEMON_* events have a separate counter. `-ts` format under `LC_ALL=C` is
   `MM/DD/YY HH:MM:SS` (a 4-digit year is rejected).
6. **Rotation.** auditd never compresses, and **SIGUSR1 always runs
   auditd's own rename-and-shift, even with `max_log_file_action = ignore`**
   (it renames `audit.log`→`.1` and shifts uncompressed `.N`→`.N+1`). So the
   usual logrotate + postrotate-signal recipe scrambles the chain; SIGHUP
   does not reopen the file at all. Chosen design: `max_log_file_action =
   ignore` and `/usr/local/sbin/audit-rotate`, which (1) runs the native
   ingest, (2) takes an exclusive `flock` on `/run/audit-fdw/rotate.lock`,
   (3) shifts `.N.gz`, gzips `.1`→`.2.gz`, (4) sends SIGUSR1 so auditd
   renames `audit.log`→`.1` itself. Readers hold the lock shared. Daily via
   `audit-rotate.timer`, or on demand. Never run `service auditd rotate` by
   hand: audit-rotate refuses a chain with an uncompressed `.2`+.
7. **Lost events.** Default `-b 8192`; lab sets `-b 65536` and
   `--backlog_wait_time 60000`. Every bench phase logs `auditctl -s`
   lost/backlog (`bench/results/auditctl.csv`).
8. **Permissions.** After `systemctl restart auditd`: directory and active
   file regrouped to `log_group`. After SIGUSR1: new `.1` keeps `auditread`,
   files `0440`. Files from before the `log_group` change keep `adm` (fixed
   by `chgrp` in setup and audit-rotate). `audit-rotate` sets `0440
   root:auditread` on `.gz` before renaming into place (root's umask would
   make them 0644). postgres: list/read OK, `touch` denied.

Other things learned:
- Over SSM `auid` is unset, so every event's subject is "system".
  `generate_events.sh` writes the user's UID to `/proc/self/loginuid` before
  `sudo -u` (allowed: `loginuid_immutable 0`), as a real login would.
- `mv f /dir/` (directory target) renames via a directory fd and ausearch
  resolves the target against the CWD (`obj2 = /var/snap/amazon-ssm-agent/...`)
  and logs an extra failed rename; the generator passes full target paths.
- 26.04 coreutils is the Rust implementation (`/usr/lib/cargo/bin/coreutils/*`,
  `gnumv`, `gnurm`), and sudo is sudo-rs; both work as expected.
- PostgreSQL `file_fdw` program stderr goes to the server log, not the client
  (except on failure, when the wrapper's message is in the error).
- Multicorn2 (README of current mirrors): v3.1 supports PostgreSQL through 18,
  latest v3.2; the original `pgsql-io/multicorn2` repository returned 404 in
  Nov 2026. Not in the Ubuntu archive.

## Benchmarks

`run_bench.sh` (all phases, several hours at 10M), launched with
`systemd-run` as above.
Results: `01-server/bench/results/*.csv` (gitignored) and `SUMMARY.md`
(committed). Ingest timer paused during query phases. See README "Findings".

## Code Commenting Standards

- Comment lines ≤ 80 characters; comment the why, not the what.
- 80-wide `# ====` section and `# ----` subsection headers in `.tf`, `.sh`,
  `.py`.
- Shell: `set -euo pipefail`; idempotent where possible, and say so when not.
- Python: stdlib only, Google-style docstrings, run with `-B` (no
  `__pycache__`).

# Audit logs in PostgreSQL: a virtual table vs a real one

Two ways to query the Linux audit trail from **PostgreSQL 18**, side by side
on one Ubuntu 26.04 host, with the same columns:

| | Table | How it gets its rows |
|---|---|---|
| **Virtual** | `audit_fdw.events` | rebuilt from `/var/log/audit` (active, rotated and `.gz` files) on **every query**, through `file_fdw` |
| **Real** | `audit_native.events` | written by a **60-second ingest** and indexed |

A benchmark suite measures the two on identical data: query latency, how
fast a new event shows up, disk space and log rotation (it also has a
concurrent-users phase, not yet in the findings). A **pgweb** host gives
you a browser client.

![pgweb](pgweb.png)

| Piece | Where | Role |
|---|---|---|
| **auditd-server** | `auditd-subnet-1` | Ubuntu 26.04, `m7i.large`, 60 GB gp3; everything below runs here |
| **auditd 4.1.2** | auditd-server | watches `/data` (`-w /data -p wa -k data_watch`) and writes `/var/log/audit` |
| **PostgreSQL 18** | auditd-server | `localhost:5432`, database `auditdb`: `audit_fdw` (virtual table) and `audit_native` (real table) |
| **audit-fdw wrappers** | `/usr/local/lib/audit-fdw/` | what the foreign table runs: `zcat -f` over the chain, then `ausearch` |
| **audit-ingest.timer** | auditd-server | every 60 s, `ausearch --checkpoint` → `COPY` into `audit_native.events` |
| **audit-rotate** | `/usr/local/sbin/` | rotates and compresses the chain (daily, or on demand) |
| **pgweb** | auditd-server | port 80, no saved connection; you sign in as `audit_reader` |
| **Secrets Manager** | regional | `auditd-postgres-credentials`: the `postgres` and `audit_reader` passwords |

## Architecture

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="architecture-dark.svg">
  <img alt="A browser reaches pgweb on port 80 and signs in as audit_reader. pgweb queries PostgreSQL on localhost. The audit_fdw schema's foreign tables run wrapper scripts on every query, which pipe the whole /var/log/audit chain, oldest file first, through zcat and ausearch. auditd appends kernel events for the watched /data directory to the chain. Separately, audit-ingest runs every 60 seconds, reads new events with an ausearch checkpoint and copies them into the indexed audit_native.events table. audit-rotate runs the ingest, compresses the previous file and signals auditd to start a new one. The database passwords are in Secrets Manager." src="architecture-light.svg">
</picture>

Regenerate with `python3 make_diagram.py`.

- **`01-server/`** is the whole stack: the VPC (`auditd-vpc`, 10.0.0.0/24)
  with one public subnet, the security group, the IAM role for SSM, the
  secret and the server.
- **`01-server/audit/`, `fdw/`, `sql/`, `systemd/`** are what cloud-init
  installs on the server.
- **`01-server/bench/`** holds the event generator, the corpus synthesizer,
  the benchmark queries and driver; a run writes its results to
  `bench/results/`.

## How it works

### The virtual table

```
SELECT ... FROM audit_fdw.events
  └─ view: to_event() casts each text row to typed columns
       └─ audit_fdw.events_csv   file_fdw, program option
            └─ wrapper: zcat -f audit.log.N.gz ... audit.log.1 audit.log
                 └─ ausearch --format csv   one row per correlated event
```

Every query runs the wrapper. It takes the rotation lock shared, pipes the
whole chain, oldest file first, through `zcat -f` (which passes plain files
through and decompresses `.gz`) into `ausearch`, and returns ausearch's CSV.
ausearch does the correlation: a single syscall is several records sharing
a serial number, and it turns them into one row with a user, an action, a
file and a result. `audit_fdw.events_csv` holds that CSV as text;
`audit_fdw.events` is the typed view you query. `file_fdw` has no filter
pushdown, so every query reads every file, whatever its `WHERE` clause.

### The real table

```
audit-ingest.timer (every 60 s)
  └─ ausearch --input-logs --checkpoint   only events not emitted before
       └─ COPY into audit_native.events_stage
            └─ INSERT ... ON CONFLICT DO NOTHING into audit_native.events
                 UNIQUE (serial, event_time), btree on event_time and key
```

The checkpoint is committed only after the database transaction commits, and
the unique constraint makes a repeated load harmless; skipped duplicates are
counted. Every run writes a row to `audit_native.ingest_log`.
`audit_native.ingest_lag` shows the age of the newest stored event; it also
grows when nothing new happens, so check `ingest_log` to see whether the
ingest itself is keeping up.

The two tables share one row type, `audit_fdw.event_t`:

| Column | Meaning |
|---|---|
| `event_time`, `serial` | when, and auditd's event number (unique only together) |
| `who` | the login user behind the action (`system` if none) |
| `run_as` | the user the process ran as |
| `action`, `result` | e.g. `renamed`, `opened-file`; `success` / `failed` |
| `file` | the file acted on |
| `new_value` | a rename target, or the new mode/owner for chmod/chown |
| `key` | the audit rule's key (`data_watch` for `/data`) |

### Rotation

auditd never compresses its logs, and on 4.1.2 `SIGUSR1` always performs
auditd's own rename-and-shift, so the usual logrotate recipe (rename, then
signal) scrambles the file order. Instead auditd's size-based rotation is off
(`max_log_file_action = ignore`) and `audit-rotate`:

1. runs the native ingest first, so `audit.log.1` is normally loaded before
   it is compressed (if that ingest fails, rotation goes ahead and the next
   ingest recovers the events by reading the compressed chain);
2. takes an **exclusive** lock that the FDW wrappers and the ingest hold
   **shared** while they read, so no query ever sees a half-shifted chain;
3. shifts `.N.gz` → `.N+1.gz` and compresses `.1` → `.2.gz`;
4. sends `SIGUSR1`, and auditd renames `audit.log` → `.1` and opens a new
   file.

The result is always `audit.log`, an uncompressed `audit.log.1`, and
compressed history, which is what `audit_fdw.log_files` shows. Rotation
matters to the comparison: the virtual table must read across the files
without gaps or duplicates while they move, and the real table must not
miss what was compressed out of `--input-logs`' reach.

## How it boots

1. Terraform builds the network, the role, the secret (two 24-character
   passwords) and the server.
2. cloud-init clones this repository and runs
   `01-server/scripts/setup_server.sh`: installs auditd, PostgreSQL 18 and
   sysstat; creates the `auditread` group (auditd's `log_group`, with
   `postgres` as a member, so PostgreSQL can read the logs but never write
   them); installs the rules, the wrappers and `audit-rotate`. Progress is
   in `/root/userdata.log`.
3. It builds `auditdb`: roles, both schemas, the virtual and the real
   table (`/root/db_setup.log`), and starts `audit-ingest.timer`.
4. It installs pgweb 0.17.0 on port 80 (`/root/pgweb.log`).
5. It seeds the demo: as `alice` and `bob`, it creates, appends to,
   overwrites, chmods, chowns, renames and deletes files under `/data`, with
   one denied write per round, rotating in between. You start with an active
   log, a `.1` and several `.gz` files.
6. It writes `/root/bootstrap.done`, which `validate.sh` waits for.

## Security groups

```
internet ─80─▶ auditd-server (pgweb)
```

`auditd-http-sg` allows TCP/80 only. There is no 5432 rule: PostgreSQL
listens on localhost and is reached through pgweb on the same host. There is
no SSH either; use SSM Session Manager.

## Prerequisites

* [An AWS Account](https://aws.amazon.com/console/)
* [Install AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
* [Install Terraform](https://developer.hashicorp.com/terraform/install)
* [Install jq](https://jqlang.github.io/jq/download/)

If this is your first time watching our content, we recommend starting with
this video: [AWS + Terraform: Easy Setup](https://youtu.be/BCMQo0CB9wk).

## Deploy

```bash
git clone https://github.com/mamonaco1973/aws-postgres-auditd.git
cd aws-postgres-auditd
./apply.sh       # one phase: VPC, secret, auditd-server
```

Everything deploys to `us-east-2`. `apply.sh` ends by running `validate.sh`,
which waits for the server to finish bootstrapping (about 5 minutes) and
prints:

```
==========================================================================
 aws-postgres-auditd - Quick Start
==========================================================================

NOTE: pgweb URL:         http://ec2-203-0-113-10.us-east-2.compute.amazonaws.com
NOTE: Instance ID:       i-0123456789abcdef0

NOTE: Host:              localhost
NOTE: Port:              5432
NOTE: Database:          auditdb
NOTE: Username:          audit_reader
NOTE: Password:          <the audit_reader password from Secrets Manager>
NOTE: SSL mode:          disable

NOTE: Server shell:      aws ssm start-session --region us-east-2 --target i-0123456789abcdef0
```

## Try it

Open the pgweb URL and connect with host `localhost`, port `5432`, user
`audit_reader`, the password `validate.sh` printed, database `auditdb` and
SSL mode `disable`. The queries are in
[`01-server/sql/queries.sql`](01-server/sql/queries.sql).

Each query below is written twice, identical except for the table. Run
both and compare the results and the query time pgweb shows. The real table
can be up to 60 seconds behind, so right after new activity its numbers may
briefly trail the virtual table's.

1. **How many changes were made under `/data`.**

   Virtual table:

   ```sql
   SELECT count(*) FROM audit_fdw.events WHERE key = 'data_watch';
   ```

   Real table:

   ```sql
   SELECT count(*) FROM audit_native.events WHERE key = 'data_watch';
   ```

2. **Who did what**, an aggregation.

   Virtual table:

   ```sql
   SELECT who, action, result, count(*)
   FROM audit_fdw.events
   WHERE key = 'data_watch'
   GROUP BY who, action, result
   ORDER BY who, count(*) DESC;
   ```

   Real table:

   ```sql
   SELECT who, action, result, count(*)
   FROM audit_native.events
   WHERE key = 'data_watch'
   GROUP BY who, action, result
   ORDER BY who, count(*) DESC;
   ```

3. **The ten most recent changes.** `new_value` is a rename target, or the
   new mode/owner for chmod/chown.

   Virtual table:

   ```sql
   SELECT event_time, who, action, result, file, new_value
   FROM audit_fdw.events
   WHERE key = 'data_watch'
   ORDER BY event_time DESC LIMIT 10;
   ```

   Real table:

   ```sql
   SELECT event_time, who, action, result, file, new_value
   FROM audit_native.events
   WHERE key = 'data_watch'
   ORDER BY event_time DESC LIMIT 10;
   ```

## Findings

Measured on this lab (`m7i.large`, PostgreSQL 18.6, auditd 4.1.2) with a
synthetic 100,000-record log chain (50,300 events, 25 MB raw, 4.6 MB on disk
as active + `.1` + six `.gz` files). Median of 5 warm runs. Both tables
returned identical results.

| Query | Virtual table | Real table |
|---|---|---|
| Full count | 557 ms | 2.3 ms |
| Key + 1-hour window | 554 ms | 1.1 ms |
| Group by user, action | 562 ms | 10.5 ms |
| One event by serial | 557 ms | 0.7 ms |
| Top-10 files | 562 ms | 7.2 ms |
| Failed ops, 24 h | 558 ms | 2.0 ms |

Cold runs (page cache dropped, PostgreSQL restarted) add about 100 ms to the
virtual table and 60–100 ms to the real one.

- **Every virtual-table query costs the same**, whatever it asks: about
  0.55 s, because each one re-reads and re-parses the whole chain (no
  pushdown). That cost grows with the logs: a full ausearch pass took 0.5 s
  at 100K records and 4.8 s at 1M.
- **The real table** answers in milliseconds, but it is a copy: 8.5 MB of
  table and 2.5 MB of btree indexes for 4.6 MB of compressed logs, loaded
  in 0.9 s.
- **Freshness:** a new event was visible in the virtual table within
  0.2–1.2 s; the real table waits for the next 60-second ingest.
- **Rotation:** writing 10,000 events while rotating every 3 seconds and
  counting continuously gave no duplicates, no gaps and no lost events;
  both tables ended at exactly 10,000.

## When to use which

| Need | Better choice | Why (measured above) |
|---|---|---|
| See an event the moment it happens | Virtual | visible in 0.2–1.2 s vs up to 60 s |
| No extra storage, no pipeline to run | Virtual | the logs are the table |
| Occasional ad-hoc questions on recent logs | Virtual | about half a second per query at 100K is fine |
| Repeated or selective queries | Real | milliseconds vs half a second, and the virtual table's cost grows with log size |
| Many users querying at once | Real (expected) | every virtual query re-parses the whole chain on its own; concurrency is not in the findings yet |
| History beyond log rotation and retention | Real | the virtual table sees only the files that still exist |

## Limits

- **Managed PostgreSQL can't do the virtual table.** RDS, Aurora, Cloud
  SQL, Azure Database for PostgreSQL Flexible Server and OCI Database with
  PostgreSQL give you no access to the host's files and no
  `COPY ... PROGRAM` / `file_fdw program`. RDS's `log_fdw` reads only
  PostgreSQL's own logs.
- **Containers** need a read-only bind mount of `/var/log/audit`, ausearch
  inside the image, and the audit log group's GID mapped to the container's
  postgres user. On Kubernetes that means a `hostPath` volume, which ties
  the pod to one node.
- **Security.** The postgres OS user can read the whole audit trail, so
  SELECT on these tables is audit-log access, and SQL injection in any
  application on this database becomes audit-log disclosure. The wrappers
  are root-owned and accept only the live log directory or a benchmark
  corpus, and `audit_reader` has no `pg_read_server_files` or
  `pg_execute_server_program`. pgweb on port 80 is plain HTTP; this is a
  lab.
- **ausearch's CSV needs workarounds** (verified on 4.1.2; details in
  [CLAUDE.md](CLAUDE.md)). ausearch reads stdin only when it is a pipe;
  under PostgreSQL stdin is `/dev/null` and it would silently search the
  system logs, so the wrapper always pipes the chain in. It exits 1 for
  both "no matches" and real errors, so exit 1 is accepted only with
  exactly `<no matches>` on stderr. Its CSV quotes nothing: the foreign
  table uses a quote byte that never occurs, `csv-repair.awk` re-splits
  rows with extra commas (a name containing `,<digits>,` still splits in
  the wrong place), and `utf8-clean` escapes the raw non-UTF-8 bytes it
  emits for relative paths. The header is checked and a change fails the
  query loudly, but a change in the action names (`renamed`,
  `opened-file`) between audit-userspace releases would pass silently.
  Both tables depend on all of this, since the ingest uses the same
  ausearch CSV.

## Troubleshooting

| Symptom | Fix |
|---|---|
| pgweb doesn't load | The server is still bootstrapping. `aws ssm start-session --region us-east-2 --target <id>`, then `sudo tail /root/userdata.log`. |
| `auditdb` or the schemas are missing | Check `/root/db_setup.log`. |
| A query on `audit_fdw` fails with `audit-fdw: ...` | That's the wrapper's message (ausearch error, header change). More detail is in `/var/log/postgresql/`. |
| `audit_native` is behind | `systemctl status audit-ingest.timer`; `SELECT * FROM audit_native.ingest_log ORDER BY run_id DESC`. |
| `audit-rotate` refuses to run | Someone ran `service auditd rotate` by hand and left an uncompressed `.2`; compress or remove it. |

## Teardown

```bash
./destroy.sh     # destroys the whole stack; the secret is deleted immediately
```

## Notes

- **Lab only.** pgweb runs over plain HTTP with no sign-in of its own, and
  the database passwords are in the host's user data. The `audit_reader`
  password is the only thing between the internet and your audit trail.

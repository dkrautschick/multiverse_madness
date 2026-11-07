# multiverse_madness

Live demo for the talk **"Getting into the Multiverse – MVCC in Oracle and PostgreSQL"**.

It shows, on a real heap page, what PostgreSQL does instead of UNDO: every
`UPDATE` and `DELETE` leaves the old row version in the same data file, marked
with the transaction ID that removed it, until `VACUUM` collects the garbage.

The data is the usual beer table from my other talks – `beer (name varchar(255)
primary key)` with Chimay, Delirium Tremens, Leffe, Straffe Hendrik,
St. Bernardus Abt 12 and friends – plus one column, `rating int`, so the table
has both a non-indexed column (updates are HOT) and an indexed one (updates are
not). We use three contrib extensions as X-ray glasses:

| extension         | what we look at                                              |
|-------------------|--------------------------------------------------------------|
| `pageinspect`     | tuples, line pointers, `xmin`/`xmax`, hint bits, HOT chains |
| `pg_freespacemap` | the Free Space Map (what VACUUM reports as reusable)         |
| `pg_visibility`   | the Visibility Map (`all_visible`, `all_frozen`)             |

## Requirements

- PostgreSQL **15 or newer** (uses `pg_stat_force_next_flush()`,
  `pg_current_xact_id()`, `heap_tuple_infomask_flags()`); every script was run
  end to end on **16.15, 18.6 and 19 RC1**. On 19 the scripts switch on the
  extra steps described under *PostgreSQL 19* below.
- the contrib package (`postgresql-contrib` / `postgresqlNN-contrib`)
- superuser or `pg_read_server_files`-level access for `pageinspect`
- a terminal with `watch` for the second window (`brew install watch` on macOS)

Everything is created in a schema `mvcc`; nothing else in the database is touched.

## Files

| file              | purpose                                                             |
|-------------------|---------------------------------------------------------------------|
| `00_setup.sql`    | extensions, the table `mvcc.beer` (autovacuum **off**), helpers         |
| `01_demo.sql`     | the main demo, 15 steps, `ENTER` advances                           |
| `02_extras.sql`   | optional chapters for Q&A or a longer slot                          |
| `watch.sh`        | second terminal: live view of page / pages / status / file / vacuum |
| `99_cleanup.sql`  | drop the schema                                                     |

### Helpers created by `00_setup.sql`

```sql
SELECT * FROM mvcc.page(0);   -- one heap page: lp, ctid, state, xmin, xmax, t_ctid, name, rating, flags
SELECT * FROM mvcc.pages;     -- all pages: normal/redirect/dead/unused counts, FSM bytes, VM bits
SELECT * FROM mvcc.status;    -- file, size, n_live/dead_tup, HOT updates, xid age, last vacuum
```

`page()` is the slide version of `heap_page_items()`: line pointer state in
words, name and rating decoded from the raw bytes, and only the interesting hint bits
(`XMIN_COMMITTED`, `XMAX_INVALID`, `HOT_UPDATED`, `ONLY_TUPLE`, `XMIN_FROZEN` …).

## Running it

Two terminals, same database, libpq variables set (`PGHOST`, `PGDATABASE`, …).

```bash
# once
psql -f 00_setup.sql

# right window – pick one, switch as the demo goes along
./watch.sh page        # heap page 0, the main view for steps 2–9
./watch.sh pages       # bloat and VACUUM across all pages (steps 10–13)
./watch.sh status      # counters, size, xid age
./watch.sh file        # ls -alh of the data file (needs local access to $PGDATA)

# left window
psql -f 01_demo.sql
```

Every step prints what it is about to show, runs the statements, and waits for
`ENTER`. Restart from any point by running the file again – step 1 truncates.

## What the main demo shows

| step | topic                                                                          |
|------|--------------------------------------------------------------------------------|
| 1    | empty table, empty file                                                        |
| 2–3  | two deliveries: 5 beers in one transaction, 5 more one per statement – `xmin` per row, the XID counter |
| 4    | the same rows through `pageinspect`; hint bits are set lazily                  |
| 5    | `DELETE` Leffe: SQL says gone, the page says `xmax` set – the "before image"   |
| 6    | `UPDATE` Duvel's rating = delete + insert; `t_ctid` chain; HOT (no index on rating) |
| 7    | `ROLLBACK` a delete of Chimay: nothing to undo, the tuple just gets `XMAX_INVALID` |
| 8    | `n_dead_tup`; no FSM, no VM bits before the first VACUUM                       |
| 9    | plain `VACUUM`: `UNUSED` / `REDIRECT`, index cleaned, FSM filled, `all_visible`; file unchanged |
| 10   | bloat: rate Duvel 1000 times in one transaction → 6 pages                      |
| 11   | `VACUUM` again: pages cleaned, file still 48 kB (only trailing pages truncate) |
| 12   | 100 homebrews land in the freed space (FSM at work)                            |
| 13   | `VACUUM FULL`: new relfilenode, file shrinks, exclusive lock                   |
| 13b  | *PG 19 only:* `REPACK (CONCURRENTLY)` on the same table – the bar stays open   |
| 14   | `VACUUM FREEZE`: `XMIN_FROZEN`, `all_frozen`, `age(relfrozenxid)` → 0          |
| 15   | autovacuum back on; the GUCs that drive it; *PG 19:* `pg_stat_autovacuum_scores` |

### Extras (`02_extras.sql`)

- **A) HOT or not** – update Leffe's rating (HOT) vs. rename Leffe → Leffe
  bruin (primary key, not HOT); `n_tup_hot_upd`, and both entries in the
  primary-key leaf via `bt_page_items()`
- **B) Poor man's flashback** – delete all beers, read them back with `page()`
  until VACUUM runs ("Oracle Flashback in PostgreSQL" from the outlook slide)
- **C) Autovacuum in action** – per-table thresholds, watch `n_dead_tup` drop
  when the launcher wakes up (`autovacuum_naptime`, default 60 s)
- **D) A VACUUM you can watch** – the beer cellar: 2 M bottles, drink half, follow
  `pg_stat_progress_vacuum` in the right window (`./watch.sh vacuum`), then
  `VACUUM FULL` to see the file actually shrink – or, on PG 19,
  `REPACK (CONCURRENTLY)` with `./watch.sh repack`

## PostgreSQL 19

PostgreSQL 19 is scheduled for general availability on **19 November 2026** –
the day of the DOAG talk. The scripts detect the server version and add:

- **`REPACK`** (step 13b, extras D): `VACUUM FULL` and `CLUSTER` are unified
  into one command. `REPACK (CONCURRENTLY)` rewrites the table while it stays
  readable *and writable*: concurrent changes are captured via logical decoding
  and replayed, the `ACCESS EXCLUSIVE` lock is held only for the final file
  swap. Needs a primary key (the beer table has one) and a free
  `max_repack_replication_slots` slot; `wal_level = replica` is enough.
  Progress in `pg_stat_progress_repack`. Note: not MVCC-safe for snapshots
  taken before the repack started.
- **Autovacuum scoring** (step 15, extras C): tables are no longer processed in
  catalog order; `pg_stat_autovacuum_scores` shows the per-table score and what
  autovacuum intends to do (`do_vacuum`, `do_analyze`, `for_wraparound`).
- **Parallel autovacuum** for index vacuuming (`autovacuum_max_parallel_workers`,
  per-table `autovacuum_parallel_workers`) – mentioned, not demoed.
- `pg_stat_progress_vacuum` gained `started_by` and `mode`; `VACUUM (VERBOSE)`
  reports dead-item memory usage.
- Plain table scans may now set visibility-map bits, previously only `VACUUM`
  and `COPY FREEZE` could. In this demo the page is still not all-visible
  before step 9 (dead tuples prevent it), so the narrative holds.

Worth a slide: the "VACUUM FULL takes an exclusive lock" argument stops being
true the day you give the talk.

## Notes for the presenter

- Autovacuum is disabled for the demo table on purpose; the whole point is
  that *we* are the garbage collector for ten minutes. Don't do this at home.
- Hint bits (`XMIN_COMMITTED` etc.) are set on the first read after commit.
  If a page looks "unflagged", `SELECT` from the table once and look again.
- In step 10 all 1000 updates run in **one** transaction, so HOT pruning
  cannot clean up while it runs – that's why the file grows. Run them as
  separate statements and the page stays much smaller: a good Q&A point.
- `name` is the primary key. Updating `rating` is HOT, updating `name`
  (Leffe → Leffe bruin, extras A) is not – the index has to follow. Keep the
  main demo on `rating` so the REDIRECT story in step 9 holds.
- Statistics (`n_dead_tup` …) are flushed by the backend when it goes idle,
  at most once a second. The scripts call `pg_stat_force_next_flush()` before
  every look at `mvcc.status` so the numbers match what you just did.
- `./watch.sh file` needs `ls` access to the data directory, i.e. you run it
  on the database host as the postgres OS user.

## Cleanup

```bash
psql -f 99_cleanup.sql
```

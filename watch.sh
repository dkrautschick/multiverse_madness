#!/usr/bin/env bash
#
# multiverse_madness - second terminal for the MVCC demo
#
#   ./watch.sh page [blk]   heap page X-ray (default block 0)      -> mvcc.page(blk)
#   ./watch.sh pages        all pages: line pointers, FSM, VM      -> mvcc.pages
#   ./watch.sh status       file, size, tuple counters, xid age    -> mvcc.status
#   ./watch.sh file         ls -alh of the table's data file (needs local $PGDATA)
#   ./watch.sh vacuum       pg_stat_progress_vacuum (for the big-table extra)
#   ./watch.sh repack       pg_stat_progress_repack (PostgreSQL 19, extras D)
#
# Connection: the usual libpq variables (PGHOST, PGPORT, PGDATABASE, PGUSER ...)
# Interval:   WATCH_INTERVAL (default 1 second)
#
set -euo pipefail

MODE="${1:-page}"
BLK="${2:-0}"
INTERVAL="${WATCH_INTERVAL:-1}"
PSQL="psql -X -q -P null=- -P footer=off"

case "$MODE" in
  page)
    exec watch -n "$INTERVAL" -t "$PSQL -c \"SELECT * FROM mvcc.page($BLK)\"" ;;
  pages)
    exec watch -n "$INTERVAL" -t "$PSQL -c \"SELECT * FROM mvcc.pages\"" ;;
  status)
    # separate -c so the stats flush lands between the two statements
    exec watch -n "$INTERVAL" -t \
      "$PSQL -c \"SELECT pg_stat_force_next_flush()\" -o /dev/null; $PSQL -x -c \"SELECT * FROM mvcc.status\"" ;;
  file)
    DATADIR="${PGDATA:-$($PSQL -Atc 'SHOW data_directory')}"
    exec watch -n "$INTERVAL" -t \
      "ls -alh \"$DATADIR\"/\$($PSQL -Atc \"SELECT pg_relation_filepath('mvcc.beer')\")*" ;;
  vacuum)
    exec watch -n "$INTERVAL" -t "$PSQL -x -c \"SELECT * FROM pg_stat_progress_vacuum\"" ;;
  repack)
    exec watch -n "$INTERVAL" -t "$PSQL -x -c \"SELECT * FROM pg_stat_progress_repack\"" ;;
  *)
    sed -n '2,14p' "$0"; exit 1 ;;
esac

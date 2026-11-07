/*
================================================================================
 multiverse_madness - MVCC demo for PostgreSQL
 02_extras.sql - optional chapters for Q&A or a longer slot

   A) HOT or not: updating a rating vs. renaming a beer (primary key)
   B) Poor man's flashback: deleted beers are still there (slide "...in the future...")
   C) Autovacuum in action: per-table thresholds, watch it wake up
   D) A VACUUM big enough to watch in pg_stat_progress_vacuum
      (and on PostgreSQL 19: REPACK (CONCURRENTLY) in pg_stat_progress_repack)

 Each chapter is self-contained; jump to the one you need.
 Requires 00_setup.sql. Right window: ./watch.sh page | status | vacuum | repack
================================================================================
*/

\set ON_ERROR_STOP off
\pset null '-'
\pset footer off
SET search_path = mvcc, public;
SELECT current_setting('server_version_num')::int >= 190000 AS pg19 \gset


--------------------------------------------------------------------------------
\echo
\echo '=== A) HOT or not: rating vs. name ==========================================='
\echo
\echo '    Fresh table, 5 beers. First the harmless update: a rating.'
\echo '    No index on rating -> Heap Only Tuple: the primary key index is'
\echo '    not touched at all, the new version lives on the same page.'
\echo
TRUNCATE beer;
SELECT pg_stat_reset_single_table_counters('mvcc.beer'::regclass) \gset
INSERT INTO beer VALUES
    ('Chimay', 8), ('Delirium Tremens', 7), ('Leffe', 5),
    ('Straffe Hendrik', 9), ('St. Bernardus Abt 12', 10);
UPDATE beer SET rating = 6 WHERE name = 'Leffe';

SELECT * FROM page(0) WHERE name = 'Leffe';
SELECT pg_stat_force_next_flush() \gset
SELECT n_tup_upd, n_tup_hot_upd FROM status;
\prompt '>>> ENTER ' _

\echo
\echo '    Now the usual one: Leffe becomes Leffe bruin.'
\echo '    name IS the primary key -> no HOT flags: the index needs a new'
\echo '    entry, and the old entry keeps pointing at the dead version.'
\echo '    Index bloat follows table bloat. VACUUM has to clean both.'
\echo
UPDATE beer SET name = 'Leffe bruin' WHERE name = 'Leffe';

SELECT * FROM page(0) WHERE name LIKE 'Leffe%';
SELECT pg_stat_force_next_flush() \gset
SELECT n_tup_upd, n_tup_hot_upd FROM status;

\echo
\echo '    Both entries in the primary key leaf page (pageinspect: bt_page_items):'
SELECT itemoffset, ctid, data FROM bt_page_items('beer_pkey', 1)
WHERE ctid IN (SELECT ctid FROM page(0) WHERE name LIKE 'Leffe%');
\prompt '>>> ENTER ' _


--------------------------------------------------------------------------------
\echo
\echo '=== B) Poor man''s flashback ================================================='
\echo
\echo '    "Oracle Flashback in PostgreSQL" - well, sort of. Until VACUUM runs'
\echo '    the deleted versions are physically still there. Not a feature,'
\echo '    a side effect. But it explains why pg_dirtyread & friends work.'
\echo
TRUNCATE beer;
INSERT INTO beer VALUES
    ('Chimay', 8), ('Delirium Tremens', 7), ('Leffe', 5),
    ('Straffe Hendrik', 9), ('St. Bernardus Abt 12', 10);
DELETE FROM beer;

SELECT count(*) AS "beers SQL can see" FROM beer;
SELECT xmin, xmax, name AS "beers pageinspect can see", rating FROM page(0);
\echo
\echo '    ...and after VACUUM they are gone for good. The table is empty, so'
\echo '    VACUUM even truncated the file to zero pages:'
VACUUM beer;
SELECT pg_stat_force_next_flush() \gset
SELECT file, size, pages FROM status;
\prompt '>>> ENTER ' _


--------------------------------------------------------------------------------
\echo
\echo '=== C) Autovacuum in action ================================================='
\echo
\echo '    Per-table settings: vacuum as soon as 20 dead tuples pile up,'
\echo '    no cost delay. Then produce garbage and wait for the launcher.'
\echo '    autovacuum_naptime decides how long that takes (default 60 s).'
\echo
TRUNCATE beer;
INSERT INTO beer SELECT 'Homebrew #' || i, i % 10 FROM generate_series(1, 100) i;
ALTER TABLE beer SET (
    autovacuum_enabled              = true,
    autovacuum_vacuum_threshold     = 20,
    autovacuum_vacuum_scale_factor  = 0,
    autovacuum_vacuum_cost_delay    = 0,
    autovacuum_analyze_threshold    = 20,
    autovacuum_analyze_scale_factor = 0
);
DELETE FROM beer WHERE rating < 5;   -- pour away the bad ones

SELECT pg_stat_force_next_flush() \gset
SELECT n_live_tup, n_dead_tup, last_vacuum FROM status;
SELECT name, setting, unit FROM pg_settings WHERE name = 'autovacuum_naptime';
\if :pg19
\echo
\echo '    PostgreSQL 19 tells us in advance what autovacuum will do with it:'
SELECT relname, round(score::numeric, 2) AS score, do_vacuum, do_analyze
FROM pg_stat_autovacuum_scores WHERE relname = 'beer';
\endif
\echo
\echo '    Right window: ./watch.sh status  - watch n_dead_tup drop to 0 and'
\echo '    last_autovacuum appear. Left window: just wait...'
\echo
\prompt '>>> ENTER when autovacuum has been here ' _

SELECT relname, n_dead_tup, last_autovacuum, last_autoanalyze, autovacuum_count
FROM pg_stat_user_tables WHERE relname = 'beer';

-- back to manual mode for the rest of the demo
ALTER TABLE beer RESET (
    autovacuum_vacuum_threshold, autovacuum_vacuum_scale_factor,
    autovacuum_vacuum_cost_delay,
    autovacuum_analyze_threshold, autovacuum_analyze_scale_factor
);
ALTER TABLE beer SET (autovacuum_enabled = false);
\prompt '>>> ENTER ' _


--------------------------------------------------------------------------------
\echo
\echo '=== D) A VACUUM you can watch ==============================================='
\echo
\echo '    The beer cellar: 2 million bottles (~115 MB table, ~43 MB index),'
\echo '    drink every second one, then VACUUM.'
\echo '    Right window: ./watch.sh vacuum  - pg_stat_progress_vacuum.'
\echo
DROP TABLE IF EXISTS beer_cellar;
CREATE TABLE beer_cellar (bottle_id int PRIMARY KEY, beer text)
    WITH (autovacuum_enabled = false);
INSERT INTO beer_cellar
    SELECT i, (ARRAY['Chimay','Delirium Tremens','Leffe','Straffe Hendrik',
                     'St. Bernardus Abt 12','Westmalle Tripel','Rochefort 10',
                     'Duvel','Orval','Tripel Karmeliet'])[1 + i % 10]
    FROM generate_series(1, 2000000) i;

SELECT pg_size_pretty(pg_relation_size('beer_cellar'))      AS table_size,
       pg_size_pretty(pg_relation_size('beer_cellar_pkey')) AS index_size;
\prompt '>>> ENTER to drink half of it ' _

DELETE FROM beer_cellar WHERE bottle_id % 2 = 0;
SELECT pg_size_pretty(pg_relation_size('beer_cellar')) AS "size after DELETE (unchanged)";
\prompt '>>> ENTER to VACUUM (watch the right window) ' _

VACUUM (VERBOSE) beer_cellar;
SELECT pg_size_pretty(pg_relation_size('beer_cellar'))      AS "table after VACUUM",
       pg_size_pretty(pg_relation_size('beer_cellar_pkey')) AS "index after VACUUM";
\echo
\echo '    Half the bottles are gone, the cellar is not smaller: the gaps are'
\echo '    spread over every shelf, nothing to truncate at the end.'

\if :pg19
\prompt '>>> ENTER for REPACK (CONCURRENTLY) - PostgreSQL 19 ' _

\echo '    The new way: rewrite the table while others keep reading AND writing.'
\echo '    Changes made meanwhile are caught via logical decoding and replayed;'
\echo '    the ACCESS EXCLUSIVE lock is only taken for the final file swap.'
\echo '    Right window: ./watch.sh repack  - pg_stat_progress_repack.'
\echo
REPACK (CONCURRENTLY, VERBOSE) beer_cellar;
SELECT pg_size_pretty(pg_relation_size('beer_cellar'))      AS "table after REPACK",
       pg_size_pretty(pg_relation_size('beer_cellar_pkey')) AS "index after REPACK";
\else
\prompt '>>> ENTER for VACUUM FULL ' _

VACUUM FULL beer_cellar;
SELECT pg_size_pretty(pg_relation_size('beer_cellar'))      AS "table after VACUUM FULL",
       pg_size_pretty(pg_relation_size('beer_cellar_pkey')) AS "index after VACUUM FULL";
\echo
\echo '    (PostgreSQL 19: REPACK (CONCURRENTLY) does this without the'
\echo '     exclusive lock. Worth upgrading for.)'
\endif

DROP TABLE beer_cellar;
\echo
\echo 'Extras done. Prost!'

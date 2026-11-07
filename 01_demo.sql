/*
================================================================================
 multiverse_madness - MVCC demo for PostgreSQL
 01_demo.sql - the live demo, step by step

 Left window :  psql -f 01_demo.sql        (this script, ENTER = next step)
 Right window:  ./watch.sh page            (or: pages | status | file)

 Run 00_setup.sql first.
================================================================================
*/

\set ON_ERROR_STOP off
\pset null '-'
\pset footer off
SET search_path = mvcc, public;

-- "SELECT pg_stat_force_next_flush() \gset" before a status read pushes the
-- pending tuple counters out immediately; \gset just swallows the output.

-- Which PostgreSQL are we on? Steps 13 and 15 have a PG 19 variant.
SELECT current_setting('server_version_num')::int >= 190000 AS pg19,
       current_setting('server_version') AS pg_version \gset

\echo
\echo '============================================================'
\echo ' Welcome to the multiverse. Every row can exist in several'
\echo ' versions at once - and they all live in the same data file.'
\echo '============================================================'
\echo ' PostgreSQL' :pg_version
\prompt '>>> ENTER to start ' _

--------------------------------------------------------------------------------
\echo
\echo '--- Step 1: an empty beer table has no file content yet'
\echo
TRUNCATE beer;
SELECT pg_stat_force_next_flush() \gset
SELECT * FROM status;
\prompt '>>> ENTER ' _

--------------------------------------------------------------------------------
\echo
\echo '--- Step 2: first delivery - 5 beers in ONE transaction'
\echo '    -> all share the same xmin, xmax = 0 (nobody drank them yet)'
\echo
INSERT INTO beer VALUES
    ('Chimay',              8),
    ('Delirium Tremens',    7),
    ('Leffe',               5),
    ('Straffe Hendrik',     9),
    ('St. Bernardus Abt 12', 10);

SELECT xmin, xmax, ctid, * FROM beer;
\prompt '>>> ENTER ' _

--------------------------------------------------------------------------------
\echo
\echo '--- Step 3: second delivery - 5 more, one transaction each'
\echo '    -> every row gets its own xmin. The XID counter just keeps ticking.'
\echo
INSERT INTO beer VALUES ('Westmalle Tripel',  9);
INSERT INTO beer VALUES ('Rochefort 10',     10);
INSERT INTO beer VALUES ('Duvel',             8);
INSERT INTO beer VALUES ('Orval',             9);
INSERT INTO beer VALUES ('Tripel Karmeliet',  8);

SELECT xmin, xmax, ctid, * FROM beer;
SELECT pg_current_xact_id() AS "and this SELECT is transaction no.";
\prompt '>>> ENTER ' _

--------------------------------------------------------------------------------
\echo
\echo '--- Step 4: the same page, seen through pageinspect'
\echo '    This is what is PHYSICALLY on disk in block 0.'
\echo '    Note the flags: XMIN_COMMITTED is a hint bit, set on first read.'
\echo
SELECT * FROM page(0);
\prompt '>>> ENTER ' _

--------------------------------------------------------------------------------
\echo
\echo '--- Step 5: DELETE a beer (sorry, Leffe)'
\echo '    SQL says it is gone. The page says: still there, xmax is set.'
\echo '    That is the "before image" - Oracle would have put it into UNDO.'
\echo
DELETE FROM beer WHERE name = 'Leffe';

SELECT xmin, xmax, ctid, * FROM beer WHERE name IN ('Delirium Tremens', 'Leffe', 'Straffe Hendrik');
SELECT * FROM page(0) WHERE name IN ('Delirium Tremens', 'Leffe', 'Straffe Hendrik');
\prompt '>>> ENTER ' _

--------------------------------------------------------------------------------
\echo
\echo '--- Step 6: UPDATE a rating (Duvel deserves more)'
\echo '    An UPDATE is a DELETE + INSERT: old version gets xmax,'
\echo '    new version is appended and the old t_ctid points to it.'
\echo '    rating has no index -> HOT_UPDATED / ONLY_TUPLE: Heap Only Tuple.'
\echo
UPDATE beer SET rating = 10 WHERE name = 'Duvel';

SELECT xmin, xmax, ctid, * FROM beer WHERE name = 'Duvel';
SELECT * FROM page(0) WHERE name = 'Duvel';
\prompt '>>> ENTER ' _

--------------------------------------------------------------------------------
\echo
\echo '--- Step 7: ROLLBACK - the "A" in ACID, for free'
\echo '    Delete Chimay inside a transaction, then think again and roll back.'
\echo '    The tuple keeps its xmax, but the flag says XMAX_INVALID:'
\echo '    the deleting transaction is known to have aborted. Nothing to undo.'
\echo
BEGIN;
DELETE FROM beer WHERE name = 'Chimay';
SELECT count(*) AS "beers visible inside the transaction" FROM beer;
ROLLBACK;

SELECT count(*) AS "beers visible after ROLLBACK" FROM beer;
SELECT * FROM page(0) WHERE name = 'Chimay';
\prompt '>>> ENTER ' _

--------------------------------------------------------------------------------
\echo
\echo '--- Step 8: what the statistics think'
\echo '    n_dead_tup counts the garbage. No FSM yet, VM not set:'
\echo '    nobody has vacuumed this table so far.'
\echo
SELECT pg_stat_force_next_flush() \gset
SELECT * FROM status;
SELECT * FROM pages;
\prompt '>>> ENTER ' _

--------------------------------------------------------------------------------
\echo
\echo '--- Step 9: VACUUM (the plain one)'
\echo '    Dead versions are removed, line pointers become UNUSED,'
\echo '    the HOT chain collapses into a REDIRECT. The index is cleaned too.'
\echo '    FSM now knows the free space, VM marks the page all_visible.'
\echo '    The FILE does not shrink.'
\echo
VACUUM (VERBOSE) beer;

SELECT * FROM page(0);
SELECT * FROM pages;
SELECT pg_stat_force_next_flush() \gset
SELECT * FROM status;
\prompt '>>> ENTER ' _

--------------------------------------------------------------------------------
\echo
\echo '--- Step 10: table bloat - rate Duvel 1000 times'
\echo '    Every UPDATE leaves a dead version behind. All 1000 happen in ONE'
\echo '    transaction, so nothing can be pruned while it runs: the pages fill'
\echo '    up, the file grows. Still one logical row. Watch n_tup_hot_upd.'
\echo
DO $$
BEGIN
    FOR i IN 1..1000 LOOP
        UPDATE beer SET rating = 10 WHERE name = 'Duvel';
    END LOOP;
END $$;

SELECT count(*) AS "beers according to SQL" FROM beer;
SELECT pg_stat_force_next_flush() \gset
SELECT * FROM status;
SELECT * FROM pages;
\prompt '>>> ENTER ' _

--------------------------------------------------------------------------------
\echo
\echo '--- Step 11: VACUUM again'
\echo '    All pages are cleaned and reported to the FSM...'
\echo '    ...but the file keeps its size. Only trailing empty pages are'
\echo '    truncated. The space is reusable, not returned to the OS.'
\echo
VACUUM beer;

SELECT pg_stat_force_next_flush() \gset
SELECT * FROM status;
SELECT * FROM pages;
\prompt '>>> ENTER ' _

--------------------------------------------------------------------------------
\echo
\echo '--- Step 12: new beers reuse the freed space (thanks to the FSM)'
\echo
INSERT INTO beer SELECT 'Homebrew #' || i, 3 FROM generate_series(1, 100) i;

SELECT * FROM pages;
SELECT pg_stat_force_next_flush() \gset
SELECT * FROM status;
\prompt '>>> ENTER ' _

--------------------------------------------------------------------------------
\echo
\echo '--- Step 13: VACUUM FULL - the sledgehammer'
\echo '    Rewrites the whole table into a NEW file (new relfilenode),'
\echo '    takes an ACCESS EXCLUSIVE lock while doing so: no reads, no writes.'
\echo '    Compare the "file" column before/after.'
\echo
SELECT pg_stat_force_next_flush() \gset
SELECT file, size, pages FROM status;
VACUUM FULL beer;
SELECT pg_stat_force_next_flush() \gset
SELECT file, size, pages FROM status;
SELECT * FROM pages;
\prompt '>>> ENTER ' _

\if :pg19
--------------------------------------------------------------------------------
\echo
\echo '--- Step 13b: PostgreSQL 19 - VACUUM FULL has a new name: REPACK'
\echo '    REPACK = VACUUM FULL + CLUSTER unified. Same rewrite, new file...'
\echo '    ...and REPACK (CONCURRENTLY) does it while the bar stays open:'
\echo '    reads and writes continue, changes are caught via logical decoding,'
\echo '    the exclusive lock is held only for the final file swap.'
\echo '    (Needs a primary key - our beer table has one.)'
\echo
REPACK (CONCURRENTLY, VERBOSE) beer;
SELECT pg_stat_force_next_flush() \gset
SELECT file, size, pages FROM status;
\prompt '>>> ENTER ' _
\else
\echo '    (PostgreSQL 19 replaces VACUUM FULL / CLUSTER with REPACK,'
\echo '     and REPACK (CONCURRENTLY) drops the exclusive lock.)'
\echo
\endif

--------------------------------------------------------------------------------
\echo
\echo '--- Step 14: FREEZE - protection against XID wraparound'
\echo '    xmin stays as it is, but the tuple is flagged XMIN_FROZEN:'
\echo '    "visible to everyone, forever". VM gets all_frozen.'
\echo
SELECT xid_age FROM status;
VACUUM (FREEZE) beer;
SELECT xid_age FROM status;

SELECT * FROM page(0) LIMIT 5;
SELECT blk, all_visible, all_frozen FROM pages;
\prompt '>>> ENTER ' _

--------------------------------------------------------------------------------
\echo
\echo '--- Step 15: and now back to normal life'
\echo '    Autovacuum would have done steps 9, 11 and 14 for us - at its own'
\echo '    pace, driven by the thresholds. We just switched it off to watch.'
\echo
ALTER TABLE beer SET (autovacuum_enabled = true);

SELECT name, setting
FROM pg_settings
WHERE name IN ('autovacuum',
               'autovacuum_vacuum_threshold',
               'autovacuum_vacuum_scale_factor',
               'autovacuum_vacuum_insert_threshold',
               'autovacuum_freeze_max_age');

\if :pg19
\echo
\echo '    PostgreSQL 19: autovacuum no longer works through tables in'
\echo '    pg_class order - every table gets a score, highest first.'
\echo '    Our table right now (clean, so the scores are tiny):'
\echo
SELECT relname, round(score::numeric, 3) AS score,
       round(vacuum_score::numeric, 3)  AS vacuum_score,
       round(xid_score::numeric, 3)     AS xid_score,
       do_vacuum, do_analyze, for_wraparound
FROM pg_stat_autovacuum_scores
WHERE relname = 'beer';
\endif

\echo
\echo '============================================================'
\echo ' The end. Neither elegant, but effective. Cheers!'
\echo '============================================================'
\echo

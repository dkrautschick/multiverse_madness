/*
================================================================================
 multiverse_madness - MVCC demo for PostgreSQL
 00_setup.sql - run once before the demo

 Requires PostgreSQL 15+ and the contrib extensions
   pageinspect     - look at raw heap pages (tuples, line pointers, infomask)
   pg_freespacemap - look at the Free Space Map (FSM)
   pg_visibility   - look at the Visibility Map (VM)

 Everything lives in the schema "mvcc" so cleanup is a single DROP SCHEMA.
================================================================================
*/

\set ON_ERROR_STOP on
\set QUIET on

CREATE EXTENSION IF NOT EXISTS pageinspect;
CREATE EXTENSION IF NOT EXISTS pg_freespacemap;
CREATE EXTENSION IF NOT EXISTS pg_visibility;

DROP SCHEMA IF EXISTS mvcc CASCADE;
CREATE SCHEMA mvcc;
SET search_path = mvcc, public;

-- The victim: the usual beer table. Autovacuum is switched off on purpose:
-- we want to see the garbage pile up and clean it up ourselves, step by step.
--   name   - primary key, so updates to it are NOT HOT (index must follow)
--   rating - no index, so updates to it ARE HOT (heap only)
CREATE TABLE beer (
    name    varchar(255) PRIMARY KEY,
    rating  int NOT NULL
) WITH (autovacuum_enabled = false, fillfactor = 100);


--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- heap_page_item_attrs() hands back the raw column bytes. Two tiny decoders:
-- int4 is little-endian; varchar carries a 1-byte (short) or 4-byte varlena
-- header in front of the characters.
CREATE FUNCTION int4_from_bytea(b bytea) RETURNS int
LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT (get_byte(b, 3) << 24)
         | (get_byte(b, 2) << 16)
         | (get_byte(b, 1) <<  8)
         |  get_byte(b, 0)
$$;

CREATE FUNCTION text_from_bytea(b bytea) RETURNS text
LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT CASE WHEN get_byte(b, 0) & 1 = 1          -- short header: 1 byte
                THEN convert_from(substr(b, 2), 'UTF8')
                ELSE convert_from(substr(b, 5), 'UTF8')   -- long header: 4 bytes
           END
$$;


-- X-ray of ONE heap page: every line pointer with its tuple header.
--   lp_state : UNUSED / NORMAL / REDIRECT -> n (HOT chain) / DEAD
--   xmin     : transaction that created this version
--   xmax     : 0 = alive, otherwise the transaction that deleted/updated it
--   t_ctid   : for an updated tuple, where the newer version lives
--   flags    : hint bits from t_infomask / t_infomask2 (set lazily!)
CREATE FUNCTION page(blk int DEFAULT 0)
RETURNS TABLE (
    lp              smallint,
    ctid            tid,
    lp_state        text,
    xmin            xid,
    xmax            xid,
    t_ctid          tid,
    name            text,
    rating          int,
    flags           text
)
LANGUAGE sql STABLE AS $$
    SELECT  p.lp,
            format('(%s,%s)', blk, p.lp)::tid,
            CASE p.lp_flags
                WHEN 0 THEN 'UNUSED'
                WHEN 1 THEN 'NORMAL'
                WHEN 2 THEN 'REDIRECT -> ' || p.lp_off
                WHEN 3 THEN 'DEAD'
            END,
            p.t_xmin,
            p.t_xmax,
            p.t_ctid,
            mvcc.text_from_bytea(p.t_attrs[1]),
            mvcc.int4_from_bytea(p.t_attrs[2]),
            CASE WHEN p.t_infomask IS NULL THEN NULL ELSE
              ( SELECT string_agg(replace(f, 'HEAP_', ''), ' ' ORDER BY f)
                  FROM heap_tuple_infomask_flags(p.t_infomask, p.t_infomask2) h,
                       unnest(h.raw_flags || h.combined_flags) f
                 WHERE f ~ '(XMIN|XMAX|HOT|UPDATED|ONLY_TUPLE)'
                   AND f <> 'HEAP_KEYS_UPDATED'
                   -- FROZEN is the combination of these two, show only FROZEN
                   AND NOT (f IN ('HEAP_XMIN_COMMITTED','HEAP_XMIN_INVALID')
                            AND 'HEAP_XMIN_FROZEN' = ANY(h.combined_flags)) )
            END
    FROM heap_page_item_attrs(get_raw_page('mvcc.beer', blk),
                              'mvcc.beer'::regclass) p
    ORDER BY p.lp
$$;


-- Bird's-eye view of ALL pages of the table:
-- physical line pointer states + FSM free bytes + VM bits per block.
CREATE VIEW pages AS
WITH blocks AS (
    SELECT generate_series(0,
             pg_relation_size('mvcc.beer')
               / current_setting('block_size')::int - 1) AS blk
)
SELECT  b.blk,
        count(i.lp) FILTER (WHERE i.lp_flags = 1)                            AS normal,
        count(i.lp) FILTER (WHERE i.lp_flags = 1 AND i.t_xmax::text <> '0')  AS normal_xmax_set,
        count(i.lp) FILTER (WHERE i.lp_flags = 2)                            AS redirect,
        count(i.lp) FILTER (WHERE i.lp_flags = 3)                            AS dead,
        count(i.lp) FILTER (WHERE i.lp_flags = 0)                            AS unused,
        f.avail                                                              AS fsm_free_bytes,
        v.all_visible,
        v.all_frozen
FROM blocks b
     LEFT JOIN LATERAL heap_page_items(get_raw_page('mvcc.beer', b.blk::int)) i ON true
     LEFT JOIN pg_freespace('mvcc.beer')     f ON f.blkno = b.blk
     LEFT JOIN pg_visibility_map('mvcc.beer') v ON v.blkno = b.blk
GROUP BY b.blk, f.avail, v.all_visible, v.all_frozen
ORDER BY b.blk;


-- What the DBA normally looks at: file, size, tuple counters, last vacuum.
-- Note: the cumulative statistics (n_*_tup) are flushed by the backend only
-- when it goes idle, and at most once a second. Run
--     SELECT pg_stat_force_next_flush();
-- as a separate statement before reading this view if you want them current.
CREATE VIEW status AS
SELECT  pg_relation_filepath('mvcc.beer')                  AS file,
        pg_size_pretty(pg_relation_size('mvcc.beer'))      AS size,
        pg_relation_size('mvcc.beer')
          / current_setting('block_size')::int                     AS pages,
        s.n_live_tup,
        s.n_dead_tup,
        s.n_tup_ins,
        s.n_tup_upd,
        s.n_tup_hot_upd,
        s.n_tup_del,
        age(c.relfrozenxid)                                        AS xid_age,
        to_char(s.last_vacuum, 'HH24:MI:SS')                       AS last_vacuum
FROM pg_class c
     LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
WHERE c.oid = 'mvcc.beer'::regclass;


\set QUIET off
\echo
\echo 'Setup done. Table mvcc.beer is ready, autovacuum is OFF for it.'
\echo 'Helpers: SELECT * FROM mvcc.page();  SELECT * FROM mvcc.pages;  SELECT * FROM mvcc.status;'
\echo
SELECT * FROM mvcc.status;

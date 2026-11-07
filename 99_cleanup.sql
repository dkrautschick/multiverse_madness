/*
================================================================================
 multiverse_madness - MVCC demo for PostgreSQL
 99_cleanup.sql - remove everything the demo created

 The extensions are left in place (they are harmless and you may want them
 again). Uncomment the DROP EXTENSION lines if you want them gone as well.
================================================================================
*/

DROP SCHEMA IF EXISTS mvcc CASCADE;

-- DROP EXTENSION IF EXISTS pg_visibility;
-- DROP EXTENSION IF EXISTS pg_freespacemap;
-- DROP EXTENSION IF EXISTS pageinspect;

\echo 'multiverse_madness: cleaned up.'

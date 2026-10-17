-- =============================================================================
-- run_all.sql  —  build the warehouse from scratch and run both batches
--
--   psql -d grokmart -f pipeline/run_all.sql        (from the repository root)
-- =============================================================================
\set ON_ERROR_STOP on
\timing off
SET client_min_messages = notice;

\echo '=== 1/4  DDL: schemas, dimensions, partitions, staging, triggers'
\ir ../sql/00_init.sql
\ir ../sql/01_dimensions.sql
\ir ../sql/02_partitioning.sql
\ir ../sql/03_staging.sql
\ir ../sql/04_triggers.sql

\echo '=== 2/4  ETL code: MERGE functions, fact loader, run_batch procedure'
\ir ../sql/05_merge_dimensions.sql
\ir ../sql/06_load_facts.sql
\ir ../sql/07_run_batch.sql

\echo '=== 3/4  Load batches'
\timing on
\ir load_batch1.sql
\ir ../sql/08_post_load_indexes.sql
\ir load_batch2.sql
\timing off

\echo '=== 4/4  Data-quality tests'
\ir ../tests/validate.sql

\echo ''
\echo 'Batch log:'
SELECT batch_id, status, rows_staged, rows_rejected, facts_inserted, facts_updated,
       products_merged, stores_merged, customers_merged, events_inserted,
       round(extract(epoch FROM finished_at - started_at)::numeric, 2) AS seconds
FROM etl.batch_log ORDER BY started_at;

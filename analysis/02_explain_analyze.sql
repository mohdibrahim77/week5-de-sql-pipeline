-- =============================================================================
-- 02_explain_analyze.sql  —  reading plans, partition pruning, index effects
-- -----------------------------------------------------------------------------
-- EXPLAIN           -> the plan the optimizer WOULD use (estimates only)
-- EXPLAIN ANALYZE   -> actually RUNS the query and shows real rows + timings
--   BUFFERS         -> pages read from cache (hit) vs disk (read)
-- Careful: EXPLAIN ANALYZE on INSERT/UPDATE/DELETE really modifies data —
-- wrap it in BEGIN ... ROLLBACK.
--
-- Index experiments use BEGIN; DROP INDEX ...; EXPLAIN ...; ROLLBACK;
-- DDL is transactional in PostgreSQL, so the index comes back on ROLLBACK.
-- Captured output: docs/explain_plans.md
-- =============================================================================
\set ON_ERROR_STOP on
\pset pager off

\echo '\n### 1. Partition pruning — one month out of six is scanned'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*), sum(net_amount)
FROM dw.fact_sales
WHERE sale_date >= DATE '2026-03-01' AND sale_date < DATE '2026-04-01';

\echo '\n### 2. No pruning — function on the partition key hides it from the planner'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*), sum(net_amount)
FROM dw.fact_sales
WHERE date_trunc('month', sale_date) = DATE '2026-03-01';

\echo '\n### 3a. Composite index (customer_sk, sale_date) — WITHOUT it'
BEGIN;
DROP INDEX dw.ix_fact_sales_customer_date;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT sale_id, sale_date, net_amount
FROM dw.fact_sales
WHERE customer_sk = 42 AND sale_date BETWEEN DATE '2026-02-01' AND DATE '2026-04-30';
ROLLBACK;

\echo '\n### 3b. Composite index (customer_sk, sale_date) — WITH it'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT sale_id, sale_date, net_amount
FROM dw.fact_sales
WHERE customer_sk = 42 AND sale_date BETWEEN DATE '2026-02-01' AND DATE '2026-04-30';

\echo '\n### 4. Partial index — returns-desk query uses ix_fact_sales_returns (WHERE is_returned)'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT sale_date, count(*)
FROM dw.fact_sales
WHERE is_returned AND store_sk = 3 AND sale_date >= DATE '2026-05-01'
GROUP BY sale_date;

\echo '\n### 4b. Same query without is_returned -> the partial index can NOT be used'
EXPLAIN (COSTS OFF)
SELECT sale_date, count(*)
FROM dw.fact_sales
WHERE store_sk = 3 AND sale_date >= DATE '2026-05-01'
GROUP BY sale_date;

\echo '\n### 5. Covering index -> Index Only Scan (no heap visits)'
VACUUM (ANALYZE) dw.fact_sales;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT sum(quantity), sum(net_amount)
FROM dw.fact_sales
WHERE product_sk = 7 AND sale_date >= DATE '2026-06-01';

\echo '\n### 6. Leftmost-prefix rule: (customer_sk, sale_date) does not help a sale_date-only filter'
EXPLAIN (COSTS OFF)
SELECT * FROM dw.fact_sales_2026_05 WHERE sale_date = DATE '2026-05-17';

\echo '\n### 7a. GIN containment on JSONB — selective predicate -> Bitmap Index Scan'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*)
FROM raw.clickstream_events
WHERE payload @> '{"event_type": "purchase", "cart": {"items": [{"product_id": "P063"}]}}';

\echo '\n### 7b. Same index, unselective predicate (~1 row in 75) -> planner decides per partition, mostly Seq Scan'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*)
FROM raw.clickstream_events
WHERE payload @> '{"utm": {"campaign": "summer_sale"}, "event_type": "purchase"}';

\echo '\n### 8. HASH partition pruning on customer_id'
EXPLAIN (COSTS OFF)
SELECT * FROM raw.clickstream_events WHERE customer_id = 'C0042';

\echo '\n### 9. EXPLAIN ANALYZE on DML — safe inside a rolled-back transaction'
BEGIN;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
UPDATE dw.fact_sales
SET    is_returned = true
WHERE  sale_date = DATE '2026-02-14' AND store_sk = 5;
ROLLBACK;

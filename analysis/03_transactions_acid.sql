-- =============================================================================
-- 03_transactions_acid.sql  —  ACID in practice (single session)
-- -----------------------------------------------------------------------------
-- A  Atomicity    all statements of a transaction succeed, or none do
-- C  Consistency  constraints hold before and after every transaction
-- I  Isolation    concurrent transactions don't see each other's half-done work
--                 -> see scripts/isolation_demo.py for a real 2-connection demo
-- D  Durability   once COMMIT returns, the change survives a crash (WAL)
--                 (and why UNLOGGED staging tables trade D for load speed)
-- Nothing in this file changes the warehouse permanently.
-- =============================================================================
\set ON_ERROR_STOP off
\pset pager off

-- -----------------------------------------------------------------------------
-- Atomicity: an error aborts the whole transaction
-- -----------------------------------------------------------------------------
\echo '\n--- Atomicity: second statement fails -> first one is undone too'
SELECT product_id, unit_price AS before FROM dw.dim_product WHERE product_id IN ('P001', 'P002');
BEGIN;
UPDATE dw.dim_product SET unit_price = unit_price * 2 WHERE product_id = 'P001';
UPDATE dw.dim_product SET unit_price = -1          WHERE product_id = 'P002';  -- violates CHECK
COMMIT;                                       -- turns into ROLLBACK because the txn is aborted
SELECT product_id, unit_price FROM dw.dim_product WHERE product_id IN ('P001', 'P002');

-- -----------------------------------------------------------------------------
-- SAVEPOINT: partial rollback inside a transaction
-- -----------------------------------------------------------------------------
\echo '\n--- SAVEPOINT: keep the good part, discard the bad part'
BEGIN;
INSERT INTO etl.rejected_rows (batch_id, source_table, reason, payload)
VALUES ('demo', 'manual', 'savepoint demo — kept until outer ROLLBACK', '{}');
SAVEPOINT before_risky_step;
UPDATE dw.dim_store SET current_region = 'CENTRAL' WHERE store_id = 'S01';  -- CHECK violation
ROLLBACK TO SAVEPOINT before_risky_step;      -- txn is usable again
SELECT count(*) AS demo_rows_visible_inside_txn FROM etl.rejected_rows WHERE batch_id = 'demo';
ROLLBACK;
SELECT count(*) AS demo_rows_after_rollback FROM etl.rejected_rows WHERE batch_id = 'demo';

-- -----------------------------------------------------------------------------
-- Consistency: deferred constraint is checked at COMMIT, not per statement
-- -----------------------------------------------------------------------------
\echo '\n--- Consistency: two "current" versions of one customer are rejected at COMMIT'
BEGIN;
INSERT INTO dw.dim_customer (customer_id, full_name, email, city, segment, valid_from, batch_id)
VALUES ('C0001', 'Duplicate Current', 'dup@example.com', 'Pune', 'Consumer', CURRENT_DATE, 'demo');
\echo '    (insert accepted — the EXCLUDE constraint is DEFERRABLE INITIALLY DEFERRED)'
COMMIT;                                       -- ERROR: conflicting key value violates exclusion constraint

-- -----------------------------------------------------------------------------
-- Isolation levels
-- -----------------------------------------------------------------------------
\echo '\n--- Isolation: default level and how to change it'
SHOW default_transaction_isolation;

BEGIN ISOLATION LEVEL REPEATABLE READ;
SHOW transaction_isolation;
-- Every statement in here sees the SAME snapshot, taken at the first query.
-- Ideal for a consistent multi-query report (e.g. reconcile fact vs mart).
SELECT (SELECT sum(net_amount)  FROM dw.fact_sales WHERE NOT is_returned) AS facts,
       (SELECT sum(net_revenue) FROM dw.agg_daily_region_sales)           AS mart;
COMMIT;

BEGIN ISOLATION LEVEL SERIALIZABLE READ ONLY DEFERRABLE;
-- READ ONLY DEFERRABLE: waits for a "safe" snapshot, then can never fail with a
-- serialization error and takes no predicate locks — the best mode for long reports.
SHOW transaction_isolation;
COMMIT;

/*
  Level            Dirty read  Non-repeatable read  Phantom read  Serialization anomaly
  ---------------  ----------  -------------------  ------------  ---------------------
  READ UNCOMMITTED  not in PG*  possible             possible      possible
  READ COMMITTED    no          possible             possible      possible     <- PG default
  REPEATABLE READ   no          no                   no in PG**    possible
  SERIALIZABLE      no          no                   no            no

  *  PostgreSQL treats READ UNCOMMITTED exactly like READ COMMITTED.
  ** The SQL standard allows phantoms at REPEATABLE READ; PostgreSQL's snapshot
     implementation prevents them.

  Two-terminal walkthrough (or run: python scripts/isolation_demo.py)

  T1: BEGIN;  -- READ COMMITTED
  T1: SELECT unit_price FROM dw.dim_product WHERE product_id = 'P005';   -- 100
  T2: UPDATE dw.dim_product SET unit_price = 200 WHERE product_id = 'P005';  -- autocommit
  T1: SELECT unit_price FROM dw.dim_product WHERE product_id = 'P005';   -- 200  (non-repeatable read)
  T1: COMMIT;

  Repeat with  T1: BEGIN ISOLATION LEVEL REPEATABLE READ;  -> T1 sees 100 both times.
*/

-- -----------------------------------------------------------------------------
-- Durability vs speed
-- -----------------------------------------------------------------------------
\echo '\n--- Durability: logged vs UNLOGGED tables'
SELECT c.oid::regclass AS table_name,
       CASE c.relpersistence WHEN 'u' THEN 'UNLOGGED (no WAL, emptied after crash)'
                             WHEN 'p' THEN 'LOGGED (WAL, crash-safe)' END AS durability
FROM pg_class c
WHERE c.oid IN ('staging.sales_raw'::regclass, 'dw.dim_customer'::regclass);

-- =============================================================================
-- 08_post_load_indexes.sql  —  composite, partial and GIN indexes
-- -----------------------------------------------------------------------------
-- Created AFTER the initial bulk load on purpose: building an index once over
-- 45k rows is far cheaper than updating it 45k times during COPY / INSERT.
-- Indexes created on a partitioned parent cascade to every partition
-- (existing and future).
-- See analysis/02_explain_analyze.sql for before/after plans.
-- =============================================================================

-- COMPOSITE: "sales of customer X between dates" — equality column first,
-- range column second. The same index also serves "WHERE customer_sk = X" alone
-- (leftmost prefix) but NOT "WHERE sale_date = ..." alone.
CREATE INDEX IF NOT EXISTS ix_fact_sales_customer_date
    ON dw.fact_sales (customer_sk, sale_date);

-- COMPOSITE covering index: product revenue lookups can be answered from the
-- index alone (Index Only Scan) thanks to INCLUDE.
CREATE INDEX IF NOT EXISTS ix_fact_sales_product_date
    ON dw.fact_sales (product_sk, sale_date) INCLUDE (quantity, net_amount);

-- PARTIAL: only ~3% of sales are returns. Indexing just those rows gives a tiny
-- index that is perfect for the returns-desk queries and costs nothing on the
-- 97% of inserts that are not returns.
CREATE INDEX IF NOT EXISTS ix_fact_sales_returns
    ON dw.fact_sales (store_sk, sale_date)
    WHERE is_returned;

-- PARTIAL on a dimension: the hot path for "current version of customer X".
CREATE INDEX IF NOT EXISTS ix_dim_customer_current
    ON dw.dim_customer (customer_id)
    INCLUDE (customer_sk, city, segment)
    WHERE is_current;

-- GIN (jsonb_path_ops): accelerates containment queries  payload @> '{...}'
CREATE INDEX IF NOT EXISTS ix_events_payload
    ON raw.clickstream_events USING gin (payload jsonb_path_ops);

-- EXPRESSION index on a JSON field that is filtered on constantly.
CREATE INDEX IF NOT EXISTS ix_events_type
    ON raw.clickstream_events ((payload ->> 'event_type'));

-- Fresh statistics so the planner makes good choices right away.
ANALYZE dw.fact_sales;
ANALYZE dw.dim_customer;
ANALYZE raw.clickstream_events;

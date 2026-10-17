-- =============================================================================
-- 02_partitioning.sql  —  RANGE, LIST and HASH partitioning
-- -----------------------------------------------------------------------------
--   dw.fact_sales               RANGE by sale_date (monthly)   time-series facts
--   dw.agg_daily_region_sales   LIST  by region                one partition per regional team
--   raw.clickstream_events      HASH  by customer_id (4 ways)  even spread, no natural range
-- =============================================================================

-- -----------------------------------------------------------------------------
-- RANGE — fact_sales, one partition per month
-- -----------------------------------------------------------------------------
-- Rules worth remembering:
--   * a PRIMARY KEY / UNIQUE constraint on a partitioned table must include the
--     partition key  ->  PK is (sale_id, sale_date), not just sale_id
--   * indexes created on the parent are created on every partition automatically
--   * FOREIGN KEYS from a partitioned table to normal tables are fine (PG 11+)
CREATE TABLE dw.fact_sales (
    sale_id       bigint        NOT NULL,
    sale_date     date          NOT NULL,
    date_key      int           NOT NULL REFERENCES dw.dim_date (date_key),
    customer_sk   int           NOT NULL REFERENCES dw.dim_customer (customer_sk),
    product_sk    int           NOT NULL REFERENCES dw.dim_product (product_sk),
    store_sk      int           NOT NULL REFERENCES dw.dim_store (store_sk),
    channel       text          NOT NULL CHECK (channel IN ('store', 'online', 'mobile')),
    quantity      int           NOT NULL CHECK (quantity > 0),
    unit_price    numeric(10,2) NOT NULL,
    discount_pct  numeric(4,2)  NOT NULL DEFAULT 0 CHECK (discount_pct BETWEEN 0 AND 1),
    net_amount    numeric(12,2) GENERATED ALWAYS AS
                      (round(quantity * unit_price * (1 - discount_pct), 2)) STORED,
    is_returned   boolean       NOT NULL DEFAULT false,
    batch_id      text          NOT NULL,       -- batch that inserted the row
    updated_batch text,                         -- batch that last corrected it (upsert)
    PRIMARY KEY (sale_id, sale_date)
) PARTITION BY RANGE (sale_date);

-- Catches anything outside the months we created — nothing is ever silently lost.
CREATE TABLE dw.fact_sales_default PARTITION OF dw.fact_sales DEFAULT;

-- Creates the partition for a month if it does not exist yet. Called by the
-- pipeline before every fact load, so new months "just work".
CREATE OR REPLACE FUNCTION etl.ensure_month_partition(p_any_day date)
RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
    v_from  date := date_trunc('month', p_any_day)::date;
    v_to    date := (date_trunc('month', p_any_day) + INTERVAL '1 month')::date;
    v_name  text := format('fact_sales_%s', to_char(v_from, 'YYYY_MM'));
BEGIN
    IF to_regclass('dw.' || v_name) IS NULL THEN
        EXECUTE format(
            'CREATE TABLE dw.%I PARTITION OF dw.fact_sales FOR VALUES FROM (%L) TO (%L)',
            v_name, v_from, v_to);
        RAISE NOTICE 'created partition dw.% [% , %)', v_name, v_from, v_to;
    END IF;
    RETURN v_name;
END;
$$;

-- Pre-create Q1 2026; later months are created on demand by the pipeline.
SELECT etl.ensure_month_partition(d::date)
FROM generate_series(DATE '2026-01-01', DATE '2026-03-01', INTERVAL '1 month') AS g(d);

-- -----------------------------------------------------------------------------
-- LIST — regional daily aggregate mart
-- -----------------------------------------------------------------------------
CREATE TABLE dw.agg_daily_region_sales (
    region        text          NOT NULL,
    sale_date     date          NOT NULL,
    orders        int           NOT NULL,
    units         int           NOT NULL,
    gross_revenue numeric(14,2) NOT NULL,
    net_revenue   numeric(14,2) NOT NULL,
    PRIMARY KEY (region, sale_date)
) PARTITION BY LIST (region);

CREATE TABLE dw.agg_daily_region_sales_north PARTITION OF dw.agg_daily_region_sales FOR VALUES IN ('NORTH');
CREATE TABLE dw.agg_daily_region_sales_south PARTITION OF dw.agg_daily_region_sales FOR VALUES IN ('SOUTH');
CREATE TABLE dw.agg_daily_region_sales_east  PARTITION OF dw.agg_daily_region_sales FOR VALUES IN ('EAST');
CREATE TABLE dw.agg_daily_region_sales_west  PARTITION OF dw.agg_daily_region_sales FOR VALUES IN ('WEST');

-- -----------------------------------------------------------------------------
-- HASH — clickstream events, spread evenly over 4 partitions
-- -----------------------------------------------------------------------------
CREATE TABLE raw.clickstream_events (
    event_id     bigint      NOT NULL,
    customer_id  text        NOT NULL,
    event_ts     timestamp   NOT NULL,
    payload      jsonb       NOT NULL,
    batch_id     text        NOT NULL,
    PRIMARY KEY (event_id, customer_id)
) PARTITION BY HASH (customer_id);

CREATE TABLE raw.clickstream_events_p0 PARTITION OF raw.clickstream_events FOR VALUES WITH (MODULUS 4, REMAINDER 0);
CREATE TABLE raw.clickstream_events_p1 PARTITION OF raw.clickstream_events FOR VALUES WITH (MODULUS 4, REMAINDER 1);
CREATE TABLE raw.clickstream_events_p2 PARTITION OF raw.clickstream_events FOR VALUES WITH (MODULUS 4, REMAINDER 2);
CREATE TABLE raw.clickstream_events_p3 PARTITION OF raw.clickstream_events FOR VALUES WITH (MODULUS 4, REMAINDER 3);

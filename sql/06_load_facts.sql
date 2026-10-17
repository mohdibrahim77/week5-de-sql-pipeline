-- =============================================================================
-- 06_load_facts.sql  —  validate, upsert facts, load JSON events, refresh mart
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Validation: DELETE bad rows out of staging and INSERT them into quarantine
-- in a single statement (data-modifying CTE + RETURNING).
-- Must run AFTER the dimension merges so lookups see this batch's new keys.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION etl.validate_staged_sales(p_batch_id text)
RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
    v_rows int;
BEGIN
    WITH checks AS (
        SELECT s.ctid AS row_ctid,
               CASE
                   WHEN s.sale_id     IS NULL THEN 'missing sale_id'
                   WHEN s.sale_date   IS NULL THEN 'missing sale_date'
                   WHEN s.customer_id IS NULL THEN 'missing customer_id'
                   WHEN s.quantity IS NULL OR s.quantity <= 0 THEN 'non-positive quantity'
                   WHEN NOT EXISTS (SELECT 1 FROM dw.dim_product p WHERE p.product_id = s.product_id)
                        THEN 'unknown product_id'
                   WHEN NOT EXISTS (SELECT 1 FROM dw.dim_store st WHERE st.store_id = s.store_id)
                        THEN 'unknown store_id'
                   WHEN NOT EXISTS (SELECT 1 FROM dw.dim_customer c
                                    WHERE c.customer_id = s.customer_id
                                      AND s.sale_date BETWEEN c.valid_from AND c.valid_to)
                        THEN 'no customer version valid on sale_date'
               END AS reason
        FROM staging.sales_raw s
    ),
    moved AS (
        DELETE FROM staging.sales_raw s
        USING checks c
        WHERE s.ctid = c.row_ctid
          AND c.reason IS NOT NULL
        RETURNING s.*, c.reason
    )
    INSERT INTO etl.rejected_rows (batch_id, source_table, reason, payload)
    SELECT p_batch_id, 'staging.sales_raw', m.reason, to_jsonb(m) - 'reason'
    FROM moved m;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows;
END;
$$;

-- -----------------------------------------------------------------------------
-- Fact load: INSERT ... ON CONFLICT DO UPDATE  (a.k.a. UPSERT)
--   * new sale_id                -> inserted
--   * re-sent sale_id, changed   -> updated  (late-arriving correction)
--   * re-sent sale_id, identical -> skipped  (WHERE on DO UPDATE)
-- SCD2 surrogate key is resolved point-in-time: the customer version that was
-- valid ON THE SALE DATE, not today's version.
-- Insert vs update is told apart via updated_batch: NULL on the insert path,
-- set by the DO UPDATE path. (The popular "RETURNING xmax = 0" trick does not
-- work here: system columns can't be returned from a partitioned table.)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION etl.load_fact_sales(p_batch_id text, OUT inserted int, OUT updated int)
LANGUAGE plpgsql AS $$
BEGIN
    -- make sure every month in this batch has its own partition
    PERFORM etl.ensure_month_partition(m)
    FROM (SELECT DISTINCT date_trunc('month', sale_date)::date AS m FROM staging.sales_raw) months;

    WITH upserted AS (
        INSERT INTO dw.fact_sales AS f (
            sale_id, sale_date, date_key, customer_sk, product_sk, store_sk,
            channel, quantity, unit_price, discount_pct, is_returned, batch_id)
        SELECT s.sale_id,
               s.sale_date,
               to_char(s.sale_date, 'YYYYMMDD')::int,
               c.customer_sk,
               p.product_sk,
               st.store_sk,
               lower(s.channel),
               s.quantity,
               s.unit_price,
               coalesce(s.discount_pct, 0),
               coalesce(s.is_returned, false),
               p_batch_id
        FROM (SELECT DISTINCT ON (sale_id, sale_date) * FROM staging.sales_raw
              ORDER BY sale_id, sale_date) s
        JOIN dw.dim_customer c ON c.customer_id = s.customer_id
                              AND s.sale_date BETWEEN c.valid_from AND c.valid_to
        JOIN dw.dim_product  p ON p.product_id  = s.product_id
        JOIN dw.dim_store   st ON st.store_id   = s.store_id
        ON CONFLICT (sale_id, sale_date) DO UPDATE
            SET customer_sk   = EXCLUDED.customer_sk,
                product_sk    = EXCLUDED.product_sk,
                store_sk      = EXCLUDED.store_sk,
                channel       = EXCLUDED.channel,
                quantity      = EXCLUDED.quantity,
                unit_price    = EXCLUDED.unit_price,
                discount_pct  = EXCLUDED.discount_pct,
                is_returned   = EXCLUDED.is_returned,
                updated_batch = EXCLUDED.batch_id
            WHERE (f.customer_sk, f.product_sk, f.store_sk, f.channel, f.quantity,
                   f.unit_price, f.discount_pct, f.is_returned)
                  IS DISTINCT FROM
                  (EXCLUDED.customer_sk, EXCLUDED.product_sk, EXCLUDED.store_sk, EXCLUDED.channel,
                   EXCLUDED.quantity, EXCLUDED.unit_price, EXCLUDED.discount_pct, EXCLUDED.is_returned)
        RETURNING (f.updated_batch IS NULL) AS is_insert
    )
    SELECT count(*) FILTER (WHERE is_insert),
           count(*) FILTER (WHERE NOT is_insert)
      INTO inserted, updated
    FROM upserted;
END;
$$;

-- -----------------------------------------------------------------------------
-- Clickstream: text -> jsonb, idempotent on replays (ON CONFLICT DO NOTHING).
-- pg_input_is_valid() (PostgreSQL 16+) lets us reject malformed JSON row by row
-- instead of failing the whole batch on the first bad cast.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION etl.load_events(p_batch_id text, OUT inserted int, OUT rejected int)
LANGUAGE plpgsql AS $$
BEGIN
    WITH moved AS (
        DELETE FROM staging.events_raw e
        WHERE e.event_id IS NULL
           OR e.customer_id IS NULL
           OR NOT pg_input_is_valid(e.payload, 'jsonb')
        RETURNING e.*
    )
    INSERT INTO etl.rejected_rows (batch_id, source_table, reason, payload)
    SELECT p_batch_id, 'staging.events_raw',
           CASE WHEN m.event_id IS NULL OR m.customer_id IS NULL THEN 'missing key'
                ELSE 'malformed JSON payload' END,
           jsonb_build_object('event_id', m.event_id, 'customer_id', m.customer_id,
                              'event_ts', m.event_ts, 'raw_payload', m.payload)
    FROM moved m;
    GET DIAGNOSTICS rejected = ROW_COUNT;

    INSERT INTO raw.clickstream_events (event_id, customer_id, event_ts, payload, batch_id)
    SELECT event_id, customer_id, event_ts, payload::jsonb, p_batch_id
    FROM staging.events_raw
    ON CONFLICT (event_id, customer_id) DO NOTHING;
    GET DIAGNOSTICS inserted = ROW_COUNT;
END;
$$;

-- -----------------------------------------------------------------------------
-- LIST-partitioned mart: full refresh. TRUNCATE + INSERT inside the batch
-- transaction, so readers never see an empty table (MVCC) — they see the old
-- data until the batch commits, then the new data.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION etl.refresh_region_agg()
RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
    v_rows int;
BEGIN
    TRUNCATE dw.agg_daily_region_sales;

    INSERT INTO dw.agg_daily_region_sales (region, sale_date, orders, units, gross_revenue, net_revenue)
    SELECT st.current_region,
           f.sale_date,
           count(*),
           sum(f.quantity),
           sum(f.quantity * f.unit_price),
           sum(f.net_amount)
    FROM dw.fact_sales f
    JOIN dw.dim_store st USING (store_sk)
    WHERE NOT f.is_returned
    GROUP BY st.current_region, f.sale_date;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows;
END;
$$;

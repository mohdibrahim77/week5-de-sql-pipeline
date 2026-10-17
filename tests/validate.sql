-- =============================================================================
-- tests/validate.sql  —  data-quality assertions
-- Every check raises an exception on failure (psql stops with ON_ERROR_STOP),
-- and prints a PASS notice otherwise.
-- =============================================================================

-- SCD2 -------------------------------------------------------------------------
DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM (
        SELECT customer_id FROM dw.dim_customer GROUP BY customer_id
        HAVING count(*) FILTER (WHERE is_current) <> 1) x;
    ASSERT n = 0, format('%s customers do not have exactly one current version', n);
    RAISE NOTICE 'PASS  scd2: exactly one current version per customer';

    SELECT count(*) INTO n FROM (
        SELECT valid_from, lag(valid_to) OVER w AS prev_to
        FROM dw.dim_customer
        WINDOW w AS (PARTITION BY customer_id ORDER BY valid_from)) x
    WHERE prev_to IS NOT NULL AND valid_from <> prev_to + 1;
    ASSERT n = 0, format('%s SCD2 versions overlap or leave a gap', n);
    RAISE NOTICE 'PASS  scd2: version ranges are contiguous, no overlap, no gap';

    SELECT count(*) INTO n FROM (
        SELECT customer_id FROM dw.dim_customer GROUP BY customer_id HAVING count(*) = 2) x;
    ASSERT n = 40, format('expected 40 customers with 2 versions, got %s', n);
    RAISE NOTICE 'PASS  scd2: 40 changed customers got a second version';
END $$;

-- SCD1 / SCD3 ------------------------------------------------------------------
DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM dw.dim_product;
    ASSERT n = 65, format('expected 65 products, got %s', n);
    SELECT count(*) INTO n FROM dw.dim_product WHERE NOT is_active;
    ASSERT n = 2, format('expected 2 discontinued products, got %s', n);
    SELECT count(*) INTO n FROM etl.price_audit;
    ASSERT n BETWEEN 1 AND 8, format('price audit should hold 1-8 rows, got %s', n);
    RAISE NOTICE 'PASS  scd1: products overwritten in place, % price changes audited by trigger', n;

    SELECT count(*) INTO n FROM dw.dim_store WHERE previous_region IS NOT NULL;
    ASSERT n = 2, format('expected 2 stores with a previous_region, got %s', n);
    RAISE NOTICE 'PASS  scd3: 2 stores carry current_region + previous_region';
END $$;

-- facts -----------------------------------------------------------------------
DO $$
DECLARE n int; m int;
BEGIN
    SELECT count(*) INTO n FROM dw.fact_sales;
    SELECT sum(facts_inserted) INTO m FROM etl.batch_log WHERE status = 'SUCCESS';
    ASSERT n = m, format('fact rows %s <> inserted rows in batch log %s', n, m);
    RAISE NOTICE 'PASS  facts: % rows, matches batch log', n;

    SELECT facts_updated INTO n FROM etl.batch_log WHERE batch_id = 'batch2';
    ASSERT n = 50, format('expected 50 late corrections upserted, got %s', n);
    SELECT count(*) INTO n FROM dw.fact_sales WHERE updated_batch = 'batch2';
    ASSERT n = 50;
    RAISE NOTICE 'PASS  upsert: 50 April sales corrected by batch2';

    SELECT count(*) INTO n FROM etl.rejected_rows WHERE source_table = 'staging.sales_raw';
    ASSERT n = 14, format('expected 14 rejected sales rows, got %s', n);
    RAISE NOTICE 'PASS  quarantine: 14 bad sales rows moved to etl.rejected_rows';

    SELECT count(*) INTO n FROM dw.fact_sales_default;
    ASSERT n = 0, format('%s rows fell into the DEFAULT partition', n);
    SELECT count(*) INTO n FROM pg_inherits WHERE inhparent = 'dw.fact_sales'::regclass;
    ASSERT n = 7, format('expected 6 monthly + 1 default partition, got %s', n);
    RAISE NOTICE 'PASS  partitions: 6 monthly partitions, default partition empty';

    SELECT count(*) INTO n
    FROM dw.fact_sales f JOIN dw.dim_customer c USING (customer_sk)
    WHERE f.sale_date NOT BETWEEN c.valid_from AND c.valid_to;
    ASSERT n = 0, format('%s facts point to a customer version not valid on the sale date', n);
    RAISE NOTICE 'PASS  point-in-time: every fact joins the customer version valid on its sale date';
END $$;

-- mart reconciliation ---------------------------------------------------------
DO $$
DECLARE a numeric; b numeric;
BEGIN
    SELECT sum(net_revenue) INTO a FROM dw.agg_daily_region_sales;
    SELECT sum(net_amount)  INTO b FROM dw.fact_sales WHERE NOT is_returned;
    ASSERT a = b, format('mart %s <> facts %s', a, b);
    RAISE NOTICE 'PASS  mart: LIST-partitioned aggregate reconciles to the fact table (%)', a;
END $$;

-- events ----------------------------------------------------------------------
DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM raw.clickstream_events;
    ASSERT n = 12000, format('expected 12000 unique events (replays ignored), got %s', n);
    SELECT count(*) INTO n FROM etl.rejected_rows WHERE reason = 'malformed JSON payload';
    ASSERT n = 1;
    RAISE NOTICE 'PASS  events: 12000 unique events, replays ignored, 1 malformed JSON quarantined';
END $$;

-- idempotency -----------------------------------------------------------------
DO $$
BEGIN
    BEGIN
        CALL etl.run_batch('batch1');
        RAISE EXCEPTION 'batch1 was loaded twice!';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM LIKE '%already loaded%' THEN
            RAISE NOTICE 'PASS  idempotency: re-running a successful batch is refused';
        ELSE
            RAISE;
        END IF;
    END;
END $$;

-- SCD2 history guard (trigger) -----------------------------------------------
DO $$
BEGIN
    BEGIN
        UPDATE dw.dim_customer SET city = 'Atlantis' WHERE NOT is_current;
        RAISE EXCEPTION 'history row was modified!';
    EXCEPTION WHEN integrity_constraint_violation THEN
        RAISE NOTICE 'PASS  trigger: expired SCD2 versions are immutable';
    END;
END $$;

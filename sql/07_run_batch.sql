-- =============================================================================
-- 07_run_batch.sql  —  the orchestrating STORED PROCEDURE
-- -----------------------------------------------------------------------------
-- CALL etl.run_batch('batch1');
--
-- Why a PROCEDURE and not a FUNCTION?  Procedures may COMMIT / ROLLBACK.
-- We use that to make failures visible:
--
--   1. all pipeline work runs inside a BEGIN ... EXCEPTION block
--      (a sub-transaction): if any step fails, ALL of its changes are undone
--      — dimensions, facts, events, mart. That is the "A" in ACID.
--   2. the error is caught, the batch is marked FAILED, and we COMMIT so that
--      the FAILED row survives.
--   3. then the error is re-raised so the caller (psql, Airflow, ...) fails too.
--
-- A FAILED batch may be re-run; a SUCCESS batch may not (idempotency guard).
-- Note: CALL must not be wrapped in an explicit BEGIN/COMMIT by the caller,
-- otherwise the COMMIT inside the procedure is not allowed.
-- =============================================================================

CREATE OR REPLACE PROCEDURE etl.run_batch(p_batch_id text)
LANGUAGE plpgsql AS $$
DECLARE
    v_staged         int;
    v_rej_sales      int;
    v_prod           int;
    v_store          int;
    v_cust           int;
    v_ins            int;
    v_upd            int;
    v_ev_ins         int;
    v_ev_rej         int;
    v_err            text;
BEGIN
    -- idempotency guard: new batch, or retry of a FAILED one — nothing else
    INSERT INTO etl.batch_log AS b (batch_id)
    VALUES (p_batch_id)
    ON CONFLICT (batch_id) DO UPDATE
        SET status = 'RUNNING', started_at = clock_timestamp(),
            finished_at = NULL, error_message = NULL
        WHERE b.status = 'FAILED';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'batch "%" was already loaded successfully (or is running)', p_batch_id;
    END IF;

    BEGIN
        SELECT count(*) INTO v_staged FROM staging.sales_raw;

        -- 1. dimensions (order matters: facts need their keys)
        v_prod  := etl.merge_dim_product(p_batch_id);
        v_store := etl.merge_dim_store(p_batch_id);
        v_cust  := etl.merge_dim_customer(p_batch_id);

        -- 2. quarantine bad fact rows
        v_rej_sales := etl.validate_staged_sales(p_batch_id);

        -- 3. facts + events
        SELECT inserted, updated INTO v_ins, v_upd    FROM etl.load_fact_sales(p_batch_id);
        SELECT inserted, rejected INTO v_ev_ins, v_ev_rej FROM etl.load_events(p_batch_id);

        -- 4. downstream mart
        PERFORM etl.refresh_region_agg();

        -- 5. fresh planner statistics for what we just loaded
        ANALYZE dw.dim_customer;
        ANALYZE dw.fact_sales;
        ANALYZE raw.clickstream_events;

        -- 6. empty the landing zone
        TRUNCATE staging.customers_raw, staging.products_raw, staging.stores_raw,
                 staging.sales_raw, staging.events_raw;

        -- check deferred constraints NOW (inside this block) rather than at COMMIT,
        -- so a violation is caught by the handler below
        SET CONSTRAINTS ALL IMMEDIATE;

        UPDATE etl.batch_log
           SET status            = 'SUCCESS',
               finished_at       = clock_timestamp(),
               rows_staged       = v_staged,
               rows_rejected     = v_rej_sales + v_ev_rej,
               facts_inserted    = v_ins,
               facts_updated     = v_upd,
               products_merged   = v_prod,
               stores_merged     = v_store,
               customers_merged  = v_cust,
               events_inserted   = v_ev_ins
         WHERE batch_id = p_batch_id;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    END;

    IF v_err IS NOT NULL THEN
        UPDATE etl.batch_log
           SET status = 'FAILED', finished_at = clock_timestamp(), error_message = v_err
         WHERE batch_id = p_batch_id;
        COMMIT;                                   -- persist the FAILED marker
        RAISE EXCEPTION 'batch "%" failed and was rolled back: %', p_batch_id, v_err;
    END IF;

    COMMIT;
    RAISE NOTICE 'batch % OK | staged % | rejected % | facts +% ~% | dims P% S% C% | events +%',
        p_batch_id, v_staged, v_rej_sales + v_ev_rej, v_ins, v_upd, v_prod, v_store, v_cust, v_ev_ins;
END;
$$;

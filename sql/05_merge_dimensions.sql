-- =============================================================================
-- 05_merge_dimensions.sql  —  MERGE staging -> dimensions (SCD 1 / 2 / 3)
-- -----------------------------------------------------------------------------
-- Each function returns the number of target rows the MERGE touched.
-- All of them first de-duplicate staging with DISTINCT ON, keeping the latest
-- record per business key — upstream systems happily send the same key twice.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- SCD TYPE 1 — dim_product
--   changed  -> overwrite in place (old value is gone; trg_product_price_audit
--               still records price changes)
--   new      -> insert
--   inactive -> soft delete via is_active = false (facts still point at it)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION etl.merge_dim_product(p_batch_id text)
RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
    v_rows int;
BEGIN
    MERGE INTO dw.dim_product AS t
    USING (
        SELECT DISTINCT ON (product_id)
               product_id, product_name, category, unit_price, coalesce(is_active, true) AS is_active
        FROM staging.products_raw
        WHERE product_id IS NOT NULL
        ORDER BY product_id, updated_at DESC
    ) AS s
    ON t.product_id = s.product_id
    WHEN MATCHED AND (t.product_name, t.category, t.unit_price, t.is_active)
                     IS DISTINCT FROM
                     (s.product_name, s.category, s.unit_price, s.is_active) THEN
        UPDATE SET product_name = s.product_name,
                   category     = s.category,
                   unit_price   = s.unit_price,
                   is_active    = s.is_active
    WHEN NOT MATCHED THEN
        INSERT (product_id, product_name, category, unit_price, is_active)
        VALUES (s.product_id, s.product_name, s.category, s.unit_price, s.is_active);
    -- (unchanged rows match neither WHEN clause and are skipped -> no useless writes)

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows;
END;
$$;

-- -----------------------------------------------------------------------------
-- SCD TYPE 3 — dim_store
--   region changed -> previous_region := current_region, current_region := new
--   other change   -> plain overwrite
--   new store      -> insert
-- Only ONE level of history is kept; that is the point of Type 3.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION etl.merge_dim_store(p_batch_id text)
RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
    v_rows int;
BEGIN
    MERGE INTO dw.dim_store AS t
    USING (
        SELECT DISTINCT ON (store_id)
               store_id, store_name, city, upper(region) AS region, updated_at::date AS effective_date
        FROM staging.stores_raw
        WHERE store_id IS NOT NULL
        ORDER BY store_id, updated_at DESC
    ) AS s
    ON t.store_id = s.store_id
    WHEN MATCHED AND t.current_region <> s.region THEN           -- first matching WHEN wins
        UPDATE SET previous_region   = t.current_region,
                   current_region    = s.region,
                   region_changed_on = s.effective_date,
                   store_name        = s.store_name,
                   city              = s.city
    WHEN MATCHED AND (t.store_name, t.city) IS DISTINCT FROM (s.store_name, s.city) THEN
        UPDATE SET store_name = s.store_name,
                   city       = s.city
    WHEN NOT MATCHED THEN
        INSERT (store_id, store_name, city, current_region)
        VALUES (s.store_id, s.store_name, s.city, s.region);

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows;
END;
$$;

-- -----------------------------------------------------------------------------
-- SCD TYPE 2 — dim_customer, in ONE MERGE statement
--
-- A MERGE row can either UPDATE or INSERT, never both — yet a changed customer
-- needs both (expire the old version AND insert a new one). The trick is to feed
-- every changed customer into the MERGE twice:
--
--   merge_key = customer_id  -> MATCHES the current version -> UPDATE (expire it)
--   merge_key = NULL         -> can never match              -> INSERT (new version)
--
-- Brand-new customers appear once with merge_key = customer_id, don't match,
-- and are inserted. Unchanged customers match but fail the AND condition -> skip.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION etl.merge_dim_customer(p_batch_id text)
RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
    v_rows int;
BEGIN
    WITH src AS (
        SELECT DISTINCT ON (customer_id)
               customer_id, full_name, lower(email) AS email, city, segment,
               updated_at::date AS effective_date
        FROM staging.customers_raw
        WHERE customer_id IS NOT NULL
        ORDER BY customer_id, updated_at DESC
    ),
    changed AS (
        SELECT s.*
        FROM src s
        JOIN dw.dim_customer d
          ON d.customer_id = s.customer_id
         AND d.is_current
        WHERE (d.full_name, d.email, d.city, d.segment)
              IS DISTINCT FROM
              (s.full_name, s.email, s.city, s.segment)
    )
    MERGE INTO dw.dim_customer AS t
    USING (
        SELECT customer_id AS merge_key, * FROM src
        UNION ALL
        SELECT NULL::text  AS merge_key, * FROM changed
    ) AS s
    ON t.customer_id = s.merge_key
   AND t.is_current
    WHEN MATCHED AND (t.full_name, t.email, t.city, t.segment)
                     IS DISTINCT FROM
                     (s.full_name, s.email, s.city, s.segment) THEN
        UPDATE SET valid_to   = s.effective_date - 1,
                   is_current = false
    WHEN NOT MATCHED THEN
        INSERT (customer_id, full_name, email, city, segment, valid_from, valid_to, is_current, batch_id)
        VALUES (s.customer_id, s.full_name, s.email, s.city, s.segment,
                s.effective_date, DATE '9999-12-31', true, p_batch_id);

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows;
END;
$$;

-- =============================================================================
-- 03_staging.sql  —  landing tables for COPY
-- -----------------------------------------------------------------------------
-- UNLOGGED: no WAL is written, so bulk loads are much faster. The trade-off is
-- that the table is emptied after a crash — perfectly fine for staging, because
-- the source CSV files can always be re-loaded.
--
-- Staging deliberately has NO constraints: bad rows must land here so that the
-- pipeline can inspect them and move them to etl.rejected_rows, instead of the
-- whole COPY failing on row 14,203.
-- =============================================================================

CREATE UNLOGGED TABLE staging.customers_raw (
    customer_id  text,
    full_name    text,
    email        text,
    city         text,
    segment      text,
    updated_at   timestamp
);

CREATE UNLOGGED TABLE staging.products_raw (
    product_id    text,
    product_name  text,
    category      text,
    unit_price    numeric(10,2),
    is_active     boolean,
    updated_at    timestamp
);

CREATE UNLOGGED TABLE staging.stores_raw (
    store_id    text,
    store_name  text,
    city        text,
    region      text,
    updated_at  timestamp
);

CREATE UNLOGGED TABLE staging.sales_raw (
    sale_id       bigint,
    sale_date     date,
    customer_id   text,
    product_id    text,
    store_id      text,
    channel       text,
    quantity      int,
    unit_price    numeric(10,2),
    discount_pct  numeric(4,2),
    is_returned   boolean
);

-- payload arrives as text; it is cast to jsonb (and therefore validated) on load.
CREATE UNLOGGED TABLE staging.events_raw (
    event_id     bigint,
    customer_id  text,
    event_ts     timestamp,
    payload      text
);

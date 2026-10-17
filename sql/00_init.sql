-- =============================================================================
-- 00_init.sql  —  schemas + ETL control tables
-- -----------------------------------------------------------------------------
-- Layered warehouse layout (a classic DE pattern):
--   staging : raw landing zone, COPY targets, truncated after every batch
--   dw      : the star schema (dimensions + partitioned facts)
--   raw     : semi-structured data kept as JSONB (clickstream)
--   etl     : pipeline metadata — batch log, rejected rows, audit trails
-- Re-running this file drops everything and starts clean.
-- =============================================================================

DROP SCHEMA IF EXISTS staging CASCADE;
DROP SCHEMA IF EXISTS dw      CASCADE;
DROP SCHEMA IF EXISTS raw     CASCADE;
DROP SCHEMA IF EXISTS etl     CASCADE;

CREATE SCHEMA staging;
CREATE SCHEMA dw;
CREATE SCHEMA raw;
CREATE SCHEMA etl;

-- One row per pipeline run. The PRIMARY KEY makes a batch impossible to load twice.
CREATE TABLE etl.batch_log (
    batch_id          text        PRIMARY KEY,
    started_at        timestamptz NOT NULL DEFAULT clock_timestamp(),
    finished_at       timestamptz,
    status            text        NOT NULL DEFAULT 'RUNNING'
                                  CHECK (status IN ('RUNNING', 'SUCCESS', 'FAILED')),
    rows_staged       int,
    rows_rejected     int,
    facts_inserted    int,
    facts_updated     int,
    products_merged   int,                -- rows touched by each dimension MERGE
    stores_merged     int,
    customers_merged  int,
    events_inserted   int,
    error_message     text
);

-- Quarantine for rows that fail validation. Whole row kept as JSONB for debugging.
CREATE TABLE etl.rejected_rows (
    reject_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_id     text        NOT NULL,
    source_table text        NOT NULL,
    reason       text        NOT NULL,
    payload      jsonb       NOT NULL,
    rejected_at  timestamptz NOT NULL DEFAULT now()
);

-- Filled by a trigger: SCD Type 1 overwrites prices, this keeps the history anyway.
CREATE TABLE etl.price_audit (
    audit_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id  text          NOT NULL,
    old_price   numeric(10,2),
    new_price   numeric(10,2),
    changed_by  text          NOT NULL DEFAULT current_user,
    changed_at  timestamptz   NOT NULL DEFAULT now()
);

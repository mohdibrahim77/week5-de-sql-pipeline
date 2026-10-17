-- =============================================================================
-- 01_dimensions.sql  —  star-schema dimensions
-- -----------------------------------------------------------------------------
--   dim_date      static calendar, smart key YYYYMMDD
--   dim_product   SCD Type 1  (overwrite — only the latest value matters)
--   dim_customer  SCD Type 2  (new row per change — full history)
--   dim_store     SCD Type 3  (previous value kept in an extra column)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- dim_date — generated, never loaded from a file
-- -----------------------------------------------------------------------------
CREATE TABLE dw.dim_date (
    date_key      int      PRIMARY KEY,            -- 20260131
    full_date     date     NOT NULL UNIQUE,
    year          smallint NOT NULL,
    quarter       smallint NOT NULL,
    month         smallint NOT NULL,
    month_name    text     NOT NULL,
    iso_week      smallint NOT NULL,
    day_of_week   smallint NOT NULL,                -- 1 = Monday
    day_name      text     NOT NULL,
    is_weekend    boolean  NOT NULL
);

INSERT INTO dw.dim_date
SELECT to_char(d, 'YYYYMMDD')::int,
       d::date,
       extract(year    FROM d),
       extract(quarter FROM d),
       extract(month   FROM d),
       to_char(d, 'FMMonth'),
       extract(week    FROM d),
       extract(isodow  FROM d),
       to_char(d, 'FMDay'),
       extract(isodow  FROM d) IN (6, 7)
FROM generate_series(DATE '2024-01-01', DATE '2027-12-31', INTERVAL '1 day') AS g(d);

-- -----------------------------------------------------------------------------
-- dim_product — SCD Type 1
-- -----------------------------------------------------------------------------
CREATE TABLE dw.dim_product (
    product_sk    int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id    text          NOT NULL UNIQUE,    -- business / natural key
    product_name  text          NOT NULL,
    category      text          NOT NULL,
    unit_price    numeric(10,2) NOT NULL CHECK (unit_price >= 0),
    is_active     boolean       NOT NULL DEFAULT true,  -- soft delete, facts still reference it
    created_at    timestamptz   NOT NULL DEFAULT now(),
    updated_at    timestamptz   NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- dim_customer — SCD Type 2
-- -----------------------------------------------------------------------------
CREATE TABLE dw.dim_customer (
    customer_sk   int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,   -- surrogate key, one per version
    customer_id   text    NOT NULL,                               -- business key, repeats across versions
    full_name     text    NOT NULL,
    email         text    NOT NULL,
    city          text    NOT NULL,
    segment       text    NOT NULL,
    valid_from    date    NOT NULL,
    valid_to      date    NOT NULL DEFAULT DATE '9999-12-31',
    is_current    boolean NOT NULL DEFAULT true,
    batch_id      text    NOT NULL,
    CHECK (valid_from <= valid_to),
    CHECK (is_current = (valid_to = DATE '9999-12-31')),

    -- "At most one current version per customer".
    -- An EXCLUDE constraint with a WHERE clause is a *partial unique constraint* that,
    -- unlike a partial unique index, can be DEFERRABLE. That matters: the SCD2 MERGE
    -- inserts the new version and expires the old one in the same statement, and the
    -- order it touches those rows is up to the planner. Deferring the check to COMMIT
    -- avoids a false duplicate-key error mid-statement.
    CONSTRAINT one_current_version_per_customer
        EXCLUDE USING btree (customer_id WITH =) WHERE (is_current)
        DEFERRABLE INITIALLY DEFERRED
);

-- Point-in-time lookups used by the fact load: customer_id + date range.
CREATE INDEX ix_dim_customer_bk_validity ON dw.dim_customer (customer_id, valid_from, valid_to);

-- -----------------------------------------------------------------------------
-- dim_store — SCD Type 3
-- -----------------------------------------------------------------------------
CREATE TABLE dw.dim_store (
    store_sk          int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    store_id          text NOT NULL UNIQUE,
    store_name        text NOT NULL,
    city              text NOT NULL,
    current_region    text NOT NULL CHECK (current_region  IN ('NORTH', 'SOUTH', 'EAST', 'WEST')),
    previous_region   text          CHECK (previous_region IN ('NORTH', 'SOUTH', 'EAST', 'WEST')),
    region_changed_on date,
    updated_at        timestamptz NOT NULL DEFAULT now()
);

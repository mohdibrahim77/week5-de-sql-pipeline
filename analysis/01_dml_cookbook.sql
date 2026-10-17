-- =============================================================================
-- 01_dml_cookbook.sql  —  INSERT / UPDATE / DELETE / MERGE / UPSERT patterns
-- -----------------------------------------------------------------------------
-- Everything runs inside BEGIN ... ROLLBACK, so the warehouse is left untouched.
-- Run after the pipeline:  psql -d grokmart -f analysis/01_dml_cookbook.sql
-- =============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE promo (
    promo_code  text PRIMARY KEY,
    category    text          NOT NULL,
    discount    numeric(4,2)  NOT NULL CHECK (discount BETWEEN 0 AND 0.5),
    uses        int           NOT NULL DEFAULT 0,
    active      boolean       NOT NULL DEFAULT true
) ON COMMIT DROP;

-- -----------------------------------------------------------------------------
-- INSERT
-- -----------------------------------------------------------------------------
-- 1) multi-row VALUES
INSERT INTO promo (promo_code, category, discount)
VALUES ('DIWALI25', 'Electronics', 0.25),
       ('BOOKWORM', 'Books',       0.10),
       ('FITNESS',  'Sports',      0.15);

-- 2) INSERT ... SELECT — derive rows from another table
INSERT INTO promo (promo_code, category, discount)
SELECT 'CAT_' || upper(left(replace(category, ' ', ''), 6)), category, 0.05
FROM dw.dim_product
WHERE category NOT IN (SELECT category FROM promo)
GROUP BY category;

-- 3) RETURNING — get generated / computed values back without a second query
INSERT INTO promo (promo_code, category, discount)
VALUES ('BEAUTY20', 'Beauty', 0.20)
RETURNING promo_code, discount, uses;

-- -----------------------------------------------------------------------------
-- UPDATE
-- -----------------------------------------------------------------------------
-- 4) UPDATE ... FROM — set a value from a join (count how often each category sold)
UPDATE promo p
SET    uses = s.orders
FROM  (SELECT dp.category, count(*) AS orders
       FROM dw.fact_sales f JOIN dw.dim_product dp USING (product_sk)
       WHERE f.discount_pct > 0
       GROUP BY dp.category) s
WHERE  s.category = p.category
RETURNING p.promo_code, p.uses;

-- 5) conditional UPDATE with CASE
UPDATE promo
SET discount = CASE WHEN uses > 1500 THEN discount - 0.05 ELSE discount END
WHERE active;

-- -----------------------------------------------------------------------------
-- DELETE
-- -----------------------------------------------------------------------------
-- 6) DELETE ... USING (join) + RETURNING
DELETE FROM promo p
USING dw.dim_product dp
WHERE dp.category = p.category
  AND dp.product_id = 'P001'          -- the category of product P001
RETURNING p.*;

-- 7) "move" rows: DELETE from one table and INSERT into another, one statement
CREATE TEMP TABLE promo_archive (LIKE promo) ON COMMIT DROP;
WITH gone AS (
    DELETE FROM promo WHERE discount <= 0.05 RETURNING *
)
INSERT INTO promo_archive SELECT * FROM gone;

SELECT 'live' AS t, count(*) FROM promo
UNION ALL
SELECT 'archived', count(*) FROM promo_archive;

-- -----------------------------------------------------------------------------
-- UPSERT  (INSERT ... ON CONFLICT)
-- -----------------------------------------------------------------------------
-- 8) DO NOTHING — idempotent insert
INSERT INTO promo (promo_code, category, discount)
VALUES ('BOOKWORM', 'Books', 0.30)
ON CONFLICT (promo_code) DO NOTHING;

-- 9) DO UPDATE — EXCLUDED is the row that *would* have been inserted
INSERT INTO promo (promo_code, category, discount)
VALUES ('BOOKWORM', 'Books', 0.30),
       ('MONSOON',  'Fashion', 0.20)
ON CONFLICT (promo_code) DO UPDATE
   SET discount = GREATEST(promo.discount, EXCLUDED.discount)
RETURNING promo_code, discount;

-- -----------------------------------------------------------------------------
-- MERGE  (SQL standard, PostgreSQL 15+)
-- -----------------------------------------------------------------------------
-- 10) all three actions in one statement: UPDATE, DELETE, INSERT
--     MERGE is more flexible than ON CONFLICT: any join condition (no unique
--     index needed), multiple WHEN clauses, and it can DELETE.
MERGE INTO promo AS t
USING (VALUES ('DIWALI25', 'Electronics', 0.30, true),     -- exists  -> update
              ('FITNESS',  'Sports',      0.15, false),    -- exists  -> delete
              ('NEWYEAR',  'Home & Kitchen', 0.12, true))  -- missing -> insert
     AS s(promo_code, category, discount, active)
ON t.promo_code = s.promo_code
WHEN MATCHED AND NOT s.active THEN
    DELETE
WHEN MATCHED THEN
    UPDATE SET discount = s.discount
WHEN NOT MATCHED AND s.active THEN
    INSERT (promo_code, category, discount) VALUES (s.promo_code, s.category, s.discount);

TABLE promo ORDER BY promo_code;

ROLLBACK;

-- =============================================================================
-- 06_scd_inspection.sql  —  what SCD Type 1 / 2 / 3 actually look like
-- =============================================================================
\pset pager off

\echo '\n--- SCD TYPE 2: full history of customers that changed in batch2'
SELECT customer_id, customer_sk, city, segment, valid_from, valid_to, is_current, batch_id
FROM dw.dim_customer
WHERE customer_id IN (SELECT customer_id FROM dw.dim_customer GROUP BY 1 HAVING count(*) > 1)
ORDER BY customer_id, valid_from
LIMIT 12;

\echo '\n--- SCD TYPE 2 pay-off: revenue by the city the customer lived in AT THE TIME of the sale'
\echo '    vs. naively attributing everything to the CURRENT city'
WITH movers AS (
    SELECT customer_id FROM dw.dim_customer GROUP BY 1 HAVING count(DISTINCT city) > 1
)
SELECT c.customer_id,
       c.city                                        AS city_at_time_of_sale,
       cur.city                                      AS current_city,
       count(*)                                      AS orders,
       sum(f.net_amount)                             AS revenue
FROM dw.fact_sales f
JOIN dw.dim_customer c   ON c.customer_sk = f.customer_sk                 -- historical version
JOIN dw.dim_customer cur ON cur.customer_id = c.customer_id AND cur.is_current
WHERE c.customer_id IN (SELECT customer_id FROM movers LIMIT 3)
GROUP BY c.customer_id, c.city, cur.city
ORDER BY c.customer_id, c.city;

\echo '\n--- SCD TYPE 2: "as-of" query — what did the customer table look like on 2026-04-15?'
SELECT segment, count(*) AS customers
FROM dw.dim_customer
WHERE DATE '2026-04-15' BETWEEN valid_from AND valid_to
GROUP BY segment
ORDER BY segment;

\echo '\n--- SCD TYPE 1: dim_product keeps only the latest price ...'
SELECT p.product_id, p.product_name, p.unit_price AS current_price, p.is_active, p.updated_at
FROM dw.dim_product p
WHERE p.product_id IN (SELECT product_id FROM etl.price_audit)
   OR NOT p.is_active
ORDER BY p.product_id;

\echo '\n--- ... while the trigger-filled audit table remembers what it overwrote'
SELECT product_id, old_price, new_price,
       round(100.0 * (new_price - old_price) / old_price, 1) AS change_pct,
       changed_at
FROM etl.price_audit
ORDER BY product_id;

\echo '\n--- SCD TYPE 3: current + previous region side by side'
SELECT store_id, store_name, previous_region, current_region, region_changed_on
FROM dw.dim_store
ORDER BY store_id;

\echo '\n--- SCD TYPE 3 pay-off: report under the old AND the new regional structure'
SELECT coalesce(st.previous_region, st.current_region) AS region_old_structure,
       st.current_region                               AS region_new_structure,
       sum(f.net_amount)                               AS revenue
FROM dw.fact_sales f
JOIN dw.dim_store st USING (store_sk)
WHERE NOT f.is_returned
GROUP BY 1, 2
ORDER BY 1, 2;

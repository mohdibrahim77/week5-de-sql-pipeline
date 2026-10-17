-- =============================================================================
-- 05_star_schema_reports.sql  —  business questions answered from the star
-- =============================================================================
\pset pager off

\echo '\n--- 1. Monthly revenue, MoM growth and running total'
SELECT d.year, d.month, d.month_name,
       sum(f.net_amount)                                          AS net_revenue,
       round(100.0 * (sum(f.net_amount) - lag(sum(f.net_amount)) OVER w)
                   / lag(sum(f.net_amount)) OVER w, 1)            AS mom_growth_pct,
       sum(sum(f.net_amount)) OVER (ORDER BY d.year, d.month)     AS running_total
FROM dw.fact_sales f
JOIN dw.dim_date d USING (date_key)
WHERE NOT f.is_returned
GROUP BY d.year, d.month, d.month_name
WINDOW w AS (ORDER BY d.year, d.month)
ORDER BY d.year, d.month;

\echo '\n--- 2. Revenue by region x channel, with a ROLLUP grand total'
SELECT st.current_region AS region,
       sum(f.net_amount) FILTER (WHERE f.channel = 'store')  AS store,
       sum(f.net_amount) FILTER (WHERE f.channel = 'online') AS online,
       sum(f.net_amount) FILTER (WHERE f.channel = 'mobile') AS mobile,
       sum(f.net_amount)                                     AS total
FROM dw.fact_sales f
JOIN dw.dim_store st USING (store_sk)
WHERE NOT f.is_returned
GROUP BY ROLLUP (st.current_region)
ORDER BY st.current_region NULLS LAST;

\echo '\n--- 3. Top 3 products per category (window ranking)'
SELECT category, product_name, units, revenue, rnk
FROM (
    SELECT p.category, p.product_name,
           sum(f.quantity)   AS units,
           sum(f.net_amount) AS revenue,
           dense_rank() OVER (PARTITION BY p.category ORDER BY sum(f.net_amount) DESC) AS rnk
    FROM dw.fact_sales f
    JOIN dw.dim_product p USING (product_sk)
    WHERE NOT f.is_returned
    GROUP BY p.category, p.product_name
) ranked
WHERE rnk <= 3
ORDER BY category, rnk;

\echo '\n--- 4. Weekend vs weekday basket size'
SELECT d.is_weekend,
       count(*)                          AS orders,
       round(avg(f.net_amount), 2)       AS avg_order_value,
       round(avg(f.quantity), 2)         AS avg_units
FROM dw.fact_sales f
JOIN dw.dim_date d USING (date_key)
GROUP BY d.is_weekend;

\echo '\n--- 5. Return rate by category (partial index friendly: WHERE is_returned)'
SELECT p.category,
       count(*)                                        AS orders,
       count(*) FILTER (WHERE f.is_returned)           AS returns,
       round(100.0 * avg(f.is_returned::int), 2)       AS return_rate_pct
FROM dw.fact_sales f
JOIN dw.dim_product p USING (product_sk)
GROUP BY p.category
ORDER BY return_rate_pct DESC;

\echo '\n--- 6. Discount effectiveness'
SELECT f.discount_pct,
       count(*)                     AS orders,
       round(avg(f.quantity), 2)    AS avg_units,
       sum(f.net_amount)            AS net_revenue,
       sum(f.quantity * f.unit_price) - sum(f.net_amount) AS discount_given
FROM dw.fact_sales f
GROUP BY f.discount_pct
ORDER BY f.discount_pct;

-- =============================================================================
-- 04_json_queries.sql  —  querying semi-structured clickstream (JSONB)
-- -----------------------------------------------------------------------------
--   ->   returns jsonb          ->>  returns text
--   #>   path, returns jsonb    #>>  path, returns text
--   @>   containment (GIN-indexable)
--   ?    key exists             ?|  any key exists     ?&  all keys exist
--   jsonb_array_elements / jsonb_to_recordset  — explode arrays into rows
--   jsonb_path_query / @?  — SQL/JSON path language
-- =============================================================================
\pset pager off

\echo '\n--- 1. Field extraction: events by type and device OS'
SELECT payload ->> 'event_type'      AS event_type,
       payload #>> '{device,os}'     AS os,
       count(*)                      AS events
FROM raw.clickstream_events
GROUP BY 1, 2
ORDER BY 1, 3 DESC;

\echo '\n--- 2. Funnel: events at each step (FILTER + JSON)'
SELECT count(*) FILTER (WHERE payload ->> 'event_type' = 'page_view')   AS page_views,
       count(*) FILTER (WHERE payload ->> 'event_type' = 'add_to_cart') AS add_to_cart,
       count(*) FILTER (WHERE payload ->> 'event_type' = 'checkout')    AS checkout,
       count(*) FILTER (WHERE payload ->> 'event_type' = 'purchase')    AS purchase,
       round(100.0 * count(*) FILTER (WHERE payload ->> 'event_type' = 'purchase')
                   / nullif(count(*) FILTER (WHERE payload ->> 'event_type' = 'add_to_cart'), 0), 1)
                                                                        AS cart_to_purchase_pct
FROM raw.clickstream_events;

\echo '\n--- 3. Containment @> (uses GIN index): purchases from the summer_sale campaign'
SELECT count(*) AS summer_sale_purchases,
       sum((payload #>> '{cart,total}')::numeric) AS revenue
FROM raw.clickstream_events
WHERE payload @> '{"event_type": "purchase", "utm": {"campaign": "summer_sale"}}';

\echo '\n--- 4. Key existence ?: share of events that carry UTM attribution'
SELECT payload ? 'utm' AS has_utm, count(*),
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM raw.clickstream_events
GROUP BY 1;

\echo '\n--- 5. Explode cart arrays with jsonb_to_recordset and join to the product dimension'
SELECT p.category,
       sum(i.qty)                      AS units_in_purchases,
       sum(i.qty * i.price)            AS cart_value
FROM raw.clickstream_events e
CROSS JOIN LATERAL jsonb_to_recordset(e.payload #> '{cart,items}')
         AS i(product_id text, qty int, price numeric)
JOIN dw.dim_product p ON p.product_id = i.product_id
WHERE e.payload ->> 'event_type' = 'purchase'
GROUP BY p.category
ORDER BY cart_value DESC;

\echo '\n--- 6. SQL/JSON path: carts containing any line with qty >= 3'
SELECT event_id,
       jsonb_path_query_array(payload, '$.cart.items[*] ? (@.qty >= 3).product_id') AS bulk_items,
       payload #>> '{cart,total}' AS cart_total
FROM raw.clickstream_events
WHERE payload @? '$.cart.items[*] ? (@.qty >= 3)'
ORDER BY (payload #>> '{cart,total}')::numeric DESC
LIMIT 5;

\echo '\n--- 7. Top search terms, and searches that returned nothing'
SELECT payload ->> 'search_query'                                 AS term,
       count(*)                                                    AS searches,
       count(*) FILTER (WHERE (payload ->> 'results')::int = 0)    AS zero_result
FROM raw.clickstream_events
WHERE payload ? 'search_query'
GROUP BY 1
ORDER BY 2 DESC
LIMIT 10;

\echo '\n--- 8. App-version adoption over time (NULL for web)'
SELECT to_char(date_trunc('month', event_ts), 'YYYY-MM') AS month,
       payload #>> '{device,app_version}'                AS app_version,
       count(*)
FROM raw.clickstream_events
WHERE payload #>> '{device,os}' <> 'web'
GROUP BY 1, 2
ORDER BY 1, 2;

\echo '\n--- 9. Building JSON: one document per customer for a downstream API'
SELECT jsonb_pretty(jsonb_build_object(
           'customer_id', c.customer_id,
           'city',        c.city,
           'segment',     c.segment,
           'lifetime',    jsonb_build_object('orders', count(f.*), 'net_spend', sum(f.net_amount)),
           'top_categories', (
               SELECT jsonb_agg(x.category ORDER BY x.spend DESC)
               FROM (SELECT p.category, sum(f2.net_amount) AS spend
                     FROM dw.fact_sales f2
                     JOIN dw.dim_customer c2 USING (customer_sk)
                     JOIN dw.dim_product  p  USING (product_sk)
                     WHERE c2.customer_id = c.customer_id
                     GROUP BY p.category
                     ORDER BY spend DESC
                     LIMIT 3) x)
       )) AS customer_doc
FROM dw.dim_customer c
JOIN dw.dim_customer v ON v.customer_id = c.customer_id
JOIN dw.fact_sales f   ON f.customer_sk = v.customer_sk
WHERE c.customer_id = 'C0042' AND c.is_current
GROUP BY c.customer_id, c.city, c.segment;

\echo '\n--- 10. Rejected rows are JSONB too: why was each row quarantined?'
SELECT batch_id, source_table, reason, count(*),
       min(payload ->> 'sale_id') AS example_sale_id
FROM etl.rejected_rows
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

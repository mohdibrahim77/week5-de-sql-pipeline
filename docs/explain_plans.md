# EXPLAIN ANALYZE — captured plans

Real output of [`analysis/02_explain_analyze.sql`](../analysis/02_explain_analyze.sql) on PostgreSQL 16.2, after both batches were loaded (45,000 fact rows, 12,000 events). `COSTS OFF, TIMING OFF` keeps the plans short and reproducible; run the script yourself to see costs and timings.

| # | Takeaway | |
|---|---|---|
| 1 | Only one month scanned | [plan](#1-partition-pruning--one-month-out-of-six-is-scanned) |
| 2 | Function on the key disables pruning | [plan](#2-no-pruning--function-on-the-partition-key-hides-it-from-the-planner) |
| 3a | No index: 290 buffers | [plan](#3a-composite-index-customer_sk-sale_date--without-it) |
| 3b | Composite index: 53 buffers | [plan](#3b-composite-index-customer_sk-sale_date--with-it) |
| 4 | Partial index used | [plan](#4-partial-index--returns-desk-query-uses-ix_fact_sales_returns-where-is_returned) |
| 4b | Partial index not applicable | [plan](#4b-same-query-without-is_returned---the-partial-index-can-not-be-used) |
| 5 | Index Only Scan, 0 heap fetches | [plan](#5-covering-index---index-only-scan-no-heap-visits) |
| 6 | Leftmost-prefix rule | [plan](#6-leftmost-prefix-rule-customer_sk-sale_date-does-not-help-a-sale_date-only-filter) |
| 7a | GIN index for @> | [plan](#7a-gin-containment-on-jsonb--selective-predicate---bitmap-index-scan) |
| 7b | Cost-based choice | [plan](#7b-same-index-unselective-predicate-1-row-in-75---planner-decides-per-partition-mostly-seq-scan) |
| 8 | Hash pruning | [plan](#8-hash-partition-pruning-on-customer_id) |
| 9 | EXPLAIN ANALYZE runs DML | [plan](#9-explain-analyze-on-dml--safe-inside-a-rolled-back-transaction) |

## 1. Partition pruning — one month out of six is scanned

Only `fact_sales_2026_03` appears in the plan — the other 6 partitions were **pruned at plan time** because the WHERE clause compares the partition key directly with constants.

```text
                                        QUERY PLAN                                        
------------------------------------------------------------------------------------------
 Aggregate (actual rows=1 loops=1)
   ->  Seq Scan on fact_sales_2026_03 fact_sales (actual rows=7802 loops=1)
         Filter: ((sale_date >= '2026-03-01'::date) AND (sale_date < '2026-04-01'::date))
(3 rows)
```

## 2. No pruning — function on the partition key hides it from the planner

Same result, but wrapping the partition key in `date_trunc()` hides it from the pruning logic: **all 7 partitions are scanned** and ~37k rows are thrown away. Rule: keep the partition key bare in predicates.

```text
                                                  QUERY PLAN                                                   
---------------------------------------------------------------------------------------------------------------
 Aggregate (actual rows=1 loops=1)
   ->  Append (actual rows=7802 loops=1)
         ->  Seq Scan on fact_sales_2026_01 fact_sales_1 (actual rows=0 loops=1)
               Filter: (date_trunc('month'::text, (sale_date)::timestamp with time zone) = '2026-03-01'::date)
               Rows Removed by Filter: 7689
         ->  Seq Scan on fact_sales_2026_02 fact_sales_2 (actual rows=0 loops=1)
               Filter: (date_trunc('month'::text, (sale_date)::timestamp with time zone) = '2026-03-01'::date)
               Rows Removed by Filter: 6940
         ->  Seq Scan on fact_sales_2026_03 fact_sales_3 (actual rows=7802 loops=1)
               Filter: (date_trunc('month'::text, (sale_date)::timestamp with time zone) = '2026-03-01'::date)
         ->  Seq Scan on fact_sales_2026_04 fact_sales_4 (actual rows=0 loops=1)
               Filter: (date_trunc('month'::text, (sale_date)::timestamp with time zone) = '2026-03-01'::date)
               Rows Removed by Filter: 7569
         ->  Seq Scan on fact_sales_2026_05 fact_sales_5 (actual rows=0 loops=1)
               Filter: (date_trunc('month'::text, (sale_date)::timestamp with time zone) = '2026-03-01'::date)
               Rows Removed by Filter: 7445
         ->  Seq Scan on fact_sales_2026_06 fact_sales_6 (actual rows=0 loops=1)
               Filter: (date_trunc('month'::text, (sale_date)::timestamp with time zone) = '2026-03-01'::date)
               Rows Removed by Filter: 7555
         ->  Seq Scan on fact_sales_default fact_sales_7 (actual rows=0 loops=1)
               Filter: (date_trunc('month'::text, (sale_date)::timestamp with time zone) = '2026-03-01'::date)
(21 rows)
```

## 3a. Composite index (customer_sk, sale_date) — WITHOUT it

Without the composite index every remaining partition is read sequentially: **290 buffers**, ~22k rows removed by filter.

```text
                                                    QUERY PLAN                                                    
------------------------------------------------------------------------------------------------------------------
 Append (actual rows=49 loops=1)
   Buffers: shared hit=290
   ->  Seq Scan on fact_sales_2026_02 fact_sales_1 (actual rows=17 loops=1)
         Filter: ((sale_date >= '2026-02-01'::date) AND (sale_date <= '2026-04-30'::date) AND (customer_sk = 42))
         Rows Removed by Filter: 6923
         Buffers: shared hit=90
   ->  Seq Scan on fact_sales_2026_03 fact_sales_2 (actual rows=16 loops=1)
         Filter: ((sale_date >= '2026-02-01'::date) AND (sale_date <= '2026-04-30'::date) AND (customer_sk = 42))
         Rows Removed by Filter: 7786
         Buffers: shared hit=101
   ->  Seq Scan on fact_sales_2026_04 fact_sales_3 (actual rows=16 loops=1)
         Filter: ((sale_date >= '2026-02-01'::date) AND (sale_date <= '2026-04-30'::date) AND (customer_sk = 42))
         Rows Removed by Filter: 7553
         Buffers: shared hit=99
 Planning:
   Buffers: shared hit=113
 Planning Time: 0.929 ms
 Execution Time: 2.007 ms
(18 rows)
```

## 3b. Composite index (customer_sk, sale_date) — WITH it

With `(customer_sk, sale_date)` the planner does a Bitmap Index Scan with *both* columns in the Index Cond: **53 buffers instead of 290** (~5x less I/O) and ~5x faster. Equality column first, range column second.

```text
                                                         QUERY PLAN                                                         
----------------------------------------------------------------------------------------------------------------------------
 Append (actual rows=49 loops=1)
   Buffers: shared hit=52
   ->  Bitmap Heap Scan on fact_sales_2026_02 fact_sales_1 (actual rows=17 loops=1)
         Recheck Cond: ((customer_sk = 42) AND (sale_date >= '2026-02-01'::date) AND (sale_date <= '2026-04-30'::date))
         Heap Blocks: exact=15
         Buffers: shared hit=17
         ->  Bitmap Index Scan on fact_sales_2026_02_customer_sk_sale_date_idx (actual rows=17 loops=1)
               Index Cond: ((customer_sk = 42) AND (sale_date >= '2026-02-01'::date) AND (sale_date <= '2026-04-30'::date))
               Buffers: shared hit=2
   ->  Bitmap Heap Scan on fact_sales_2026_03 fact_sales_2 (actual rows=16 loops=1)
         Recheck Cond: ((customer_sk = 42) AND (sale_date >= '2026-02-01'::date) AND (sale_date <= '2026-04-30'::date))
         Heap Blocks: exact=15
         Buffers: shared hit=17
         ->  Bitmap Index Scan on fact_sales_2026_03_customer_sk_sale_date_idx (actual rows=16 loops=1)
               Index Cond: ((customer_sk = 42) AND (sale_date >= '2026-02-01'::date) AND (sale_date <= '2026-04-30'::date))
               Buffers: shared hit=2
   ->  Bitmap Heap Scan on fact_sales_2026_04 fact_sales_3 (actual rows=16 loops=1)
         Recheck Cond: ((customer_sk = 42) AND (sale_date >= '2026-02-01'::date) AND (sale_date <= '2026-04-30'::date))
         Heap Blocks: exact=15
         Buffers: shared hit=18
         ->  Bitmap Index Scan on fact_sales_2026_04_customer_sk_sale_date_idx (actual rows=16 loops=1)
               Index Cond: ((customer_sk = 42) AND (sale_date >= '2026-02-01'::date) AND (sale_date <= '2026-04-30'::date))
               Buffers: shared hit=3
 Planning:
   Buffers: shared hit=133
 Planning Time: 0.832 ms
 Execution Time: 0.181 ms
(27 rows)
```

## 4. Partial index — returns-desk query uses ix_fact_sales_returns (WHERE is_returned)

The partial index `ix_fact_sales_returns ... WHERE is_returned` is used (it shows up per partition as `fact_sales_2026_0X_store_sk_sale_date_idx`). It only contains the ~3% of rows that are returns.

```text
                                                               QUERY PLAN                                                                
-----------------------------------------------------------------------------------------------------------------------------------------
 HashAggregate (actual rows=17 loops=1)
   Group Key: fact_sales.sale_date
   Batches: 1  Memory Usage: 24kB
   ->  Append (actual rows=27 loops=1)
         ->  Index Only Scan using fact_sales_2026_05_store_sk_sale_date_idx on fact_sales_2026_05 fact_sales_1 (actual rows=12 loops=1)
               Index Cond: ((store_sk = 3) AND (sale_date >= '2026-05-01'::date))
               Heap Fetches: 0
         ->  Index Only Scan using fact_sales_2026_06_store_sk_sale_date_idx on fact_sales_2026_06 fact_sales_2 (actual rows=15 loops=1)
               Index Cond: ((store_sk = 3) AND (sale_date >= '2026-05-01'::date))
               Heap Fetches: 0
         ->  Seq Scan on fact_sales_default fact_sales_3 (actual rows=0 loops=1)
               Filter: (is_returned AND (sale_date >= '2026-05-01'::date) AND (store_sk = 3))
(12 rows)
```

## 4b. Same query without is_returned -> the partial index can NOT be used

Drop `is_returned` from the WHERE clause and the planner can no longer prove the partial index covers the query — back to sequential scans.

```text
                                  QUERY PLAN                                  
------------------------------------------------------------------------------
 HashAggregate
   Group Key: fact_sales.sale_date
   ->  Append
         ->  Seq Scan on fact_sales_2026_05 fact_sales_1
               Filter: ((sale_date >= '2026-05-01'::date) AND (store_sk = 3))
         ->  Seq Scan on fact_sales_2026_06 fact_sales_2
               Filter: ((sale_date >= '2026-05-01'::date) AND (store_sk = 3))
         ->  Seq Scan on fact_sales_default fact_sales_3
               Filter: ((sale_date >= '2026-05-01'::date) AND (store_sk = 3))
(9 rows)
```

## 5. Covering index -> Index Only Scan (no heap visits)

`INCLUDE (quantity, net_amount)` makes the index *covering*: **Index Only Scan, Heap Fetches: 0** — the table itself is never read (needs an up-to-date visibility map, hence the `VACUUM` first).

```text
                                                                           QUERY PLAN                                                                           
----------------------------------------------------------------------------------------------------------------------------------------------------------------
 Aggregate (actual rows=1 loops=1)
   ->  Append (actual rows=115 loops=1)
         ->  Index Only Scan using fact_sales_2026_06_product_sk_sale_date_quantity_net_amount_idx on fact_sales_2026_06 fact_sales_1 (actual rows=115 loops=1)
               Index Cond: ((product_sk = 7) AND (sale_date >= '2026-06-01'::date))
               Heap Fetches: 0
         ->  Seq Scan on fact_sales_default fact_sales_2 (actual rows=0 loops=1)
               Filter: ((sale_date >= '2026-06-01'::date) AND (product_sk = 7))
(7 rows)
```

## 6. Leftmost-prefix rule: (customer_sk, sale_date) does not help a sale_date-only filter

An index on `(customer_sk, sale_date)` cannot serve a filter on `sale_date` alone → Seq Scan.

```text
                 QUERY PLAN                 
--------------------------------------------
 Seq Scan on fact_sales_2026_05
   Filter: (sale_date = '2026-05-17'::date)
(2 rows)
```

## 7a. GIN containment on JSONB — selective predicate -> Bitmap Index Scan

A selective containment query (`@>`) uses the GIN `jsonb_path_ops` index on every hash partition.

```text
                                                          QUERY PLAN                                                           
-------------------------------------------------------------------------------------------------------------------------------
 Aggregate (actual rows=1 loops=1)
   ->  Append (actual rows=11 loops=1)
         ->  Bitmap Heap Scan on clickstream_events_p0 clickstream_events_1 (actual rows=4 loops=1)
               Recheck Cond: (payload @> '{"cart": {"items": [{"product_id": "P063"}]}, "event_type": "purchase"}'::jsonb)
               Heap Blocks: exact=4
               ->  Bitmap Index Scan on clickstream_events_p0_payload_idx (actual rows=4 loops=1)
                     Index Cond: (payload @> '{"cart": {"items": [{"product_id": "P063"}]}, "event_type": "purchase"}'::jsonb)
         ->  Bitmap Heap Scan on clickstream_events_p1 clickstream_events_2 (actual rows=2 loops=1)
               Recheck Cond: (payload @> '{"cart": {"items": [{"product_id": "P063"}]}, "event_type": "purchase"}'::jsonb)
               Heap Blocks: exact=2
               ->  Bitmap Index Scan on clickstream_events_p1_payload_idx (actual rows=2 loops=1)
                     Index Cond: (payload @> '{"cart": {"items": [{"product_id": "P063"}]}, "event_type": "purchase"}'::jsonb)
         ->  Bitmap Heap Scan on clickstream_events_p2 clickstream_events_3 (actual rows=2 loops=1)
               Recheck Cond: (payload @> '{"cart": {"items": [{"product_id": "P063"}]}, "event_type": "purchase"}'::jsonb)
               Heap Blocks: exact=2
               ->  Bitmap Index Scan on clickstream_events_p2_payload_idx (actual rows=2 loops=1)
                     Index Cond: (payload @> '{"cart": {"items": [{"product_id": "P063"}]}, "event_type": "purchase"}'::jsonb)
         ->  Bitmap Heap Scan on clickstream_events_p3 clickstream_events_4 (actual rows=3 loops=1)
               Recheck Cond: (payload @> '{"cart": {"items": [{"product_id": "P063"}]}, "event_type": "purchase"}'::jsonb)
               Heap Blocks: exact=3
               ->  Bitmap Index Scan on clickstream_events_p3_payload_idx (actual rows=3 loops=1)
                     Index Cond: (payload @> '{"cart": {"items": [{"product_id": "P063"}]}, "event_type": "purchase"}'::jsonb)
(22 rows)
```

## 7b. Same index, unselective predicate (~1 row in 75) -> planner decides per partition, mostly Seq Scan

Same index, ~1-in-75 selectivity: the planner estimates each partition separately and picks Seq Scan for most of them. An index is only used when it is estimated to be cheaper.

```text
                                                      QUERY PLAN                                                      
----------------------------------------------------------------------------------------------------------------------
 Aggregate (actual rows=1 loops=1)
   ->  Append (actual rows=158 loops=1)
         ->  Bitmap Heap Scan on clickstream_events_p0 clickstream_events_1 (actual rows=33 loops=1)
               Recheck Cond: (payload @> '{"utm": {"campaign": "summer_sale"}, "event_type": "purchase"}'::jsonb)
               Heap Blocks: exact=31
               ->  Bitmap Index Scan on clickstream_events_p0_payload_idx (actual rows=33 loops=1)
                     Index Cond: (payload @> '{"utm": {"campaign": "summer_sale"}, "event_type": "purchase"}'::jsonb)
         ->  Bitmap Heap Scan on clickstream_events_p1 clickstream_events_2 (actual rows=44 loops=1)
               Recheck Cond: (payload @> '{"utm": {"campaign": "summer_sale"}, "event_type": "purchase"}'::jsonb)
               Heap Blocks: exact=41
               ->  Bitmap Index Scan on clickstream_events_p1_payload_idx (actual rows=44 loops=1)
                     Index Cond: (payload @> '{"utm": {"campaign": "summer_sale"}, "event_type": "purchase"}'::jsonb)
         ->  Bitmap Heap Scan on clickstream_events_p2 clickstream_events_3 (actual rows=46 loops=1)
               Recheck Cond: (payload @> '{"utm": {"campaign": "summer_sale"}, "event_type": "purchase"}'::jsonb)
               Heap Blocks: exact=40
               ->  Bitmap Index Scan on clickstream_events_p2_payload_idx (actual rows=46 loops=1)
                     Index Cond: (payload @> '{"utm": {"campaign": "summer_sale"}, "event_type": "purchase"}'::jsonb)
         ->  Bitmap Heap Scan on clickstream_events_p3 clickstream_events_4 (actual rows=35 loops=1)
               Recheck Cond: (payload @> '{"utm": {"campaign": "summer_sale"}, "event_type": "purchase"}'::jsonb)
               Heap Blocks: exact=33
               ->  Bitmap Index Scan on clickstream_events_p3_payload_idx (actual rows=35 loops=1)
                     Index Cond: (payload @> '{"utm": {"campaign": "summer_sale"}, "event_type": "purchase"}'::jsonb)
(22 rows)
```

## 8. HASH partition pruning on customer_id

Hash partitioning prunes too: `customer_id = 'C0042'` hashes to exactly one of the 4 partitions.

```text
                      QUERY PLAN                      
------------------------------------------------------
 Seq Scan on clickstream_events_p3 clickstream_events
   Filter: (customer_id = 'C0042'::text)
(2 rows)
```

## 9. EXPLAIN ANALYZE on DML — safe inside a rolled-back transaction

`EXPLAIN ANALYZE` *executes* the statement, so on DML always wrap it in `BEGIN ... ROLLBACK`. Only the February partition is touched.

```text
                                 QUERY PLAN                                 
----------------------------------------------------------------------------
 Update on fact_sales (actual rows=0 loops=1)
   Update on fact_sales_2026_02 fact_sales_1
   ->  Seq Scan on fact_sales_2026_02 fact_sales_1 (actual rows=20 loops=1)
         Filter: ((sale_date = '2026-02-14'::date) AND (store_sk = 5))
         Rows Removed by Filter: 6920
(5 rows)
```

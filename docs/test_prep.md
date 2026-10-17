# Test prep — predict output · DML scenario · optimization

Format of the weekly test: **predict the output + 1 DML scenario + 1 optimization question (40 min)**.
All questions use this project's schema, so you can check every answer with `psql`.

---

## Part A — Predict the output

**A1.** `dw.dim_customer` has customer `C0042` with two versions (Lucknow until 2026‑04‑30, Patna from 2026‑05‑01). What does this return?

```sql
SELECT city FROM dw.dim_customer
WHERE customer_id = 'C0042' AND DATE '2026-05-01' BETWEEN valid_from AND valid_to;
```

<details><summary>Answer</summary>

`Patna`. One row only: the old version ends on `2026-04-30` (= new `valid_from - 1`), so the ranges never overlap.
</details>

**A2.** Run inside one transaction:

```sql
BEGIN;
INSERT INTO etl.rejected_rows (batch_id, source_table, reason, payload) VALUES ('x','t','r','{}');
SAVEPOINT s1;
INSERT INTO etl.rejected_rows (batch_id, source_table, reason, payload) VALUES ('x','t','r', NULL);
ROLLBACK TO s1;
INSERT INTO etl.rejected_rows (batch_id, source_table, reason, payload) VALUES ('x','t','r','{}');
COMMIT;
SELECT count(*) FROM etl.rejected_rows WHERE batch_id = 'x';
```

<details><summary>Answer</summary>

`2`. The NULL payload violates `NOT NULL`; `ROLLBACK TO s1` undoes only that failed statement and makes the transaction usable again.
</details>

**A3.** Table `t(id int PRIMARY KEY, v int)` contains `(1, 10)`. What is in `t` afterwards?

```sql
INSERT INTO t VALUES (1, 99), (2, 20)
ON CONFLICT (id) DO UPDATE SET v = t.v + EXCLUDED.v;
```

<details><summary>Answer</summary>

`(1, 109)` and `(2, 20)`. `t.v` is the existing row (10) and `EXCLUDED.v` is the row that would have been inserted (99).
</details>

**A4.** How many rows does this MERGE touch, and what is in `t` afterwards? Start: `t = {(1,'a'), (2,'b')}`.

```sql
MERGE INTO t USING (VALUES (1,'a'), (2,'z'), (3,'c')) s(id, v) ON t.id = s.id
WHEN MATCHED AND t.v = s.v THEN DELETE
WHEN MATCHED THEN UPDATE SET v = s.v
WHEN NOT MATCHED THEN INSERT VALUES (s.id, s.v);
```

<details><summary>Answer</summary>

3 rows (`MERGE 3`). id 1 matches with the same value and is **deleted**. id 2 is updated to `'z'`. id 3 is inserted. Result: `{(2,'z'), (3,'c')}`. The first `WHEN` clause whose condition holds wins.
</details>

**A5.** Which partitions does this query scan?

```sql
SELECT count(*) FROM dw.fact_sales WHERE extract(month FROM sale_date) = 3;
```

<details><summary>Answer</summary>

**All of them** (6 monthly and the default). The partition key is wrapped in a function, so the planner can't prune. Rewrite it as `sale_date >= '2026-03-01' AND sale_date < '2026-04-01'` (see [explain_plans.md §2](explain_plans.md)).
</details>

**A6.** SCD Type 3: store S06 moves from SOUTH to NORTH, then later from NORTH to EAST. What do `previous_region` and `current_region` hold now?

<details><summary>Answer</summary>

`previous_region = NORTH`, `current_region = EAST`. Type 3 keeps only **one** level of history, so SOUTH is lost. If you need the full history, use Type 2.
</details>

---

## Part B — DML scenario

> Upstream re-sends yesterday's sales file. Some rows are new, some are corrections of rows already loaded, and some are exact duplicates. A handful have `quantity <= 0`. Load it **idempotently**, keep bad rows for inspection, and report how many rows were inserted versus updated.

<details><summary>Model answer (this is what <code>etl.validate_staged_sales</code> + <code>etl.load_fact_sales</code> do)</summary>

```sql
BEGIN;

-- 1. quarantine bad rows: DELETE from staging, INSERT into rejects, in one statement
WITH bad AS (
    DELETE FROM staging.sales_raw WHERE quantity IS NULL OR quantity <= 0
    RETURNING *
)
INSERT INTO etl.rejected_rows (batch_id, source_table, reason, payload)
SELECT 'retry-2026-06-30', 'staging.sales_raw', 'non-positive quantity', to_jsonb(bad) FROM bad;

-- 2. upsert; identical rows are skipped by the WHERE on DO UPDATE
WITH up AS (
    INSERT INTO dw.fact_sales AS f (sale_id, sale_date, date_key, customer_sk, product_sk, store_sk,
                                    channel, quantity, unit_price, discount_pct, is_returned, batch_id)
    SELECT s.sale_id, s.sale_date, to_char(s.sale_date,'YYYYMMDD')::int, c.customer_sk, p.product_sk,
           st.store_sk, s.channel, s.quantity, s.unit_price, s.discount_pct, s.is_returned, 'retry-2026-06-30'
    FROM (SELECT DISTINCT ON (sale_id, sale_date) * FROM staging.sales_raw ORDER BY sale_id, sale_date) s
    JOIN dw.dim_customer c ON c.customer_id = s.customer_id AND s.sale_date BETWEEN c.valid_from AND c.valid_to
    JOIN dw.dim_product  p USING (product_id)
    JOIN dw.dim_store   st USING (store_id)
    ON CONFLICT (sale_id, sale_date) DO UPDATE
       SET quantity = EXCLUDED.quantity, unit_price = EXCLUDED.unit_price,
           discount_pct = EXCLUDED.discount_pct, updated_batch = EXCLUDED.batch_id
       WHERE (f.quantity, f.unit_price, f.discount_pct)
             IS DISTINCT FROM (EXCLUDED.quantity, EXCLUDED.unit_price, EXCLUDED.discount_pct)
    RETURNING (f.updated_batch IS NULL) AS inserted
)
SELECT count(*) FILTER (WHERE inserted) AS inserted,
       count(*) FILTER (WHERE NOT inserted) AS updated
FROM up;

COMMIT;
```

Points examiners look for:
- `DISTINCT ON` first. Without it, a key that appears twice in one statement raises *"ON CONFLICT DO UPDATE command cannot affect row a second time"*.
- The conflict target must match a unique index, which on a partitioned table includes the partition key `(sale_id, sale_date)`.
- `WHERE ... IS DISTINCT FROM` avoids rewriting unchanged rows (less WAL, less bloat, fewer trigger firings).
- Everything runs in one transaction, so a failure leaves nothing half-loaded.
</details>

---

## Part C — Optimization question

> This query takes seconds on a large fact table. Explain why and fix it.
>
> ```sql
> SELECT sale_date, sum(net_amount)
> FROM dw.fact_sales
> WHERE to_char(sale_date, 'YYYY-MM') = '2026-05'
>   AND customer_sk = 1234
> GROUP BY sale_date;
> ```

<details><summary>Model answer</summary>

1. **Diagnose** with `EXPLAIN (ANALYZE, BUFFERS)`. You'll see a Seq Scan on **every** partition with a large *Rows Removed by Filter*.
2. **Make the predicate sargable.** The function on `sale_date` blocks both partition pruning and index use:
   `WHERE sale_date >= DATE '2026-05-01' AND sale_date < DATE '2026-06-01' AND customer_sk = 1234`.
   Now only `fact_sales_2026_05` is scanned.
3. **Add a composite index** with the equality column first and the range column second:
   `CREATE INDEX ON dw.fact_sales (customer_sk, sale_date) INCLUDE (net_amount);`
   The `INCLUDE` makes it covering, which allows an Index Only Scan.
4. **Verify** with `EXPLAIN ANALYZE` again: one partition, Index (Only) Scan, buffers down by an order of magnitude ([explain_plans.md §3](explain_plans.md)).
5. **Mention the trade-offs.** Every index slows down writes. Build big indexes *after* bulk loads, keep statistics fresh with `ANALYZE`, and consider a **partial index** if only a subset of rows is ever queried.
</details>

---

## One-line cheat sheet

| Topic | Remember |
|---|---|
| UPSERT | `ON CONFLICT (cols) DO NOTHING / DO UPDATE SET c = EXCLUDED.c` needs a unique index on `cols` |
| MERGE | PG15+. Supports `WHEN MATCHED [AND ..] THEN UPDATE/DELETE` and `WHEN NOT MATCHED THEN INSERT`, plus any join condition |
| RANGE / LIST / HASH | time series / discrete categories / even spread. A PK must include the partition key |
| COPY vs `\copy` | server reads the file (needs privileges) vs psql streams a local file |
| Composite index | leftmost-prefix rule; equality columns before range columns |
| Partial index | `WHERE` predicate; the query must imply it |
| Isolation | PG default READ COMMITTED; RR = one snapshot; SERIALIZABLE = retry on `40001` |
| Procedure vs function | `CALL`, can `COMMIT`/`ROLLBACK`, vs `SELECT`, returns a value |
| SCD 1 / 2 / 3 | overwrite / new row with validity range / previous-value column |

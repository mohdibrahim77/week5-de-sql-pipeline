-- =============================================================================
-- load_batch2.sql  —  incremental load (May–Jun 2026)
--   SCD2 customer moves, SCD1 price changes, SCD3 store re-alignment,
--   late corrections to April sales, replayed events, and some bad rows.
-- Run from the REPOSITORY ROOT.
-- =============================================================================
\echo '>> batch2: COPY CSV files into staging'

\copy staging.customers_raw FROM 'data/batch2/customers.csv' WITH (FORMAT csv, HEADER true)
\copy staging.products_raw  FROM 'data/batch2/products.csv'  WITH (FORMAT csv, HEADER true)
\copy staging.stores_raw    FROM 'data/batch2/stores.csv'    WITH (FORMAT csv, HEADER true)
\copy staging.sales_raw     FROM 'data/batch2/sales.csv'     WITH (FORMAT csv, HEADER true)
\copy staging.events_raw    FROM 'data/batch2/events.csv'    WITH (FORMAT csv, HEADER true)

\echo '>> batch2: CALL etl.run_batch'
CALL etl.run_batch('batch2');

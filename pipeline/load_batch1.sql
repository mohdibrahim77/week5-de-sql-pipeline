-- =============================================================================
-- load_batch1.sql  —  initial full load (Jan–Apr 2026)
-- Run from the REPOSITORY ROOT: \copy paths are relative to psql's working dir.
-- =============================================================================
\echo '>> batch1: COPY CSV files into staging'

-- \copy is psql's client-side wrapper around COPY ... FROM STDIN:
--   * the file is read by psql on YOUR machine and streamed to the server
--   * needs no superuser / pg_read_server_files privilege
-- Server-side equivalent (file must exist on the DB server):
--   COPY staging.sales_raw FROM '/data/batch1/sales.csv' WITH (FORMAT csv, HEADER true);
\copy staging.customers_raw FROM 'data/batch1/customers.csv' WITH (FORMAT csv, HEADER true)
\copy staging.products_raw  FROM 'data/batch1/products.csv'  WITH (FORMAT csv, HEADER true)
\copy staging.stores_raw    FROM 'data/batch1/stores.csv'    WITH (FORMAT csv, HEADER true)
\copy staging.sales_raw     FROM 'data/batch1/sales.csv'     WITH (FORMAT csv, HEADER true)
\copy staging.events_raw    FROM 'data/batch1/events.csv'    WITH (FORMAT csv, HEADER true)

\echo '>> batch1: CALL etl.run_batch'
CALL etl.run_batch('batch1');

#!/usr/bin/env bash
# Build the warehouse and run both batches + tests.
# Uses the standard libpq env vars: PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE
#   PGDATABASE=grokmart ./scripts/run_pipeline.sh
set -euo pipefail
cd "$(dirname "$0")/.."

DB="${PGDATABASE:-grokmart}"
createdb "$DB" 2>/dev/null || true          # ignore "already exists"
psql -d "$DB" -v ON_ERROR_STOP=1 -q -f pipeline/run_all.sql

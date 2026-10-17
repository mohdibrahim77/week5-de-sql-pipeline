# Build the warehouse and run both batches + tests (Windows PowerShell).
# Uses the standard libpq env vars: PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE
#   $env:PGUSER = "postgres"; .\scripts\run_pipeline.ps1
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

$db = if ($env:PGDATABASE) { $env:PGDATABASE } else { "grokmart" }
& createdb $db 2>$null            # ignore "already exists"
& psql -d $db -v ON_ERROR_STOP=1 -q -f pipeline/run_all.sql
if ($LASTEXITCODE -ne 0) { throw "pipeline failed (exit $LASTEXITCODE)" }

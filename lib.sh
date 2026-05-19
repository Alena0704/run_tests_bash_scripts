#!/bin/bash
# Shared variables and helpers for JOB benchmark scripts.
#
# Override any of these via env vars before sourcing:
#   PG_BASE=$HOME/my_postgres11 ./script.sh   # use a different PG tree
#   PGPORT=5432 ./script.sh                   # use default port
#   PGDATA=/custom/data ./script.sh
# The defaults below assume a single PG source tree at $PG_BASE.

# Single point of customization — change here or override at invocation.
PG_BASE="${PG_BASE:-$HOME/my_postgres12}"
PG_DATA_NAME="${PG_DATA_NAME:-vacuum_stats9}"   # subdir name under $PG_BASE

# PostgreSQL install
INSTDIR="${INSTDIR:-$PG_BASE/my/inst/bin}"

# Cluster
export PGDATA="${PGDATA:-$PG_BASE/$PG_DATA_NAME}"
export PGPORT="${PGPORT:-5499}"
export PGUSER="${PGUSER:-$(whoami)}"
export PGDATABASE="${PGDATABASE:-postgres}"

# Benchmark
QUERY_DIR="${QUERY_DIR:-$HOME/source}"
QUERY_FILES="${QUERY_FILES:-$QUERY_DIR/queries}"

# Output
BENCH_ROOT="${BENCH_ROOT:-$HOME/min_job}"
PLANS_DIR="${PLANS_DIR:-$BENCH_ROOT/plans}"
RESULTS_DIR="${RESULTS_DIR:-$BENCH_ROOT/results}"
LOG_DIR="${LOG_DIR:-$BENCH_ROOT/logs}"

# Per-query repetitions and timeout
ITERS="${ITERS:-5}"
STATEMENT_TIMEOUT_MS="${STATEMENT_TIMEOUT_MS:-600000}" # 10 minutes

PSQL="$INSTDIR/psql -p $PGPORT -d $PGDATABASE -U $PGUSER -X -q"

# Ensure server is up; restart only if not running on this PGDATA.
# Uses pg_ctl status (data-dir based) so we don't false-start a cluster that
# is alive but listening on a different port than $PGPORT.
pg_ensure_up() {
    if "$INSTDIR/pg_ctl" status -D "$PGDATA" >/dev/null 2>&1; then
        return 0
    fi
    "$INSTDIR/pg_ctl" -w -D "$PGDATA" -l "$BENCH_ROOT/logfile.log" start
}

# Write EXPLAIN (cost-only) for query $1 into plans dir for method $2.
save_plain_explain() {
    local query_file="$1" method="$2"
    local name plan_file
    name="$(basename "$query_file" .sql)"
    plan_file="$PLANS_DIR/$method/${name}.plan"
    mkdir -p "$PLANS_DIR/$method"
    {
        echo "SET statement_timeout = ${STATEMENT_TIMEOUT_MS};"
        echo "EXPLAIN"
        sed 's/;[[:space:]]*$//' "$query_file"
        echo ";"
    } | $PSQL -f - > "$plan_file" 2>&1
}

# Run query $1 once, print elapsed ms to stdout.
# Uses \timing on; greps the first 'Time: X ms' line.
run_query_once() {
    local query_file="$1"
    {
        echo "SET statement_timeout = ${STATEMENT_TIMEOUT_MS};"
        echo "\\timing on"
        sed 's/;[[:space:]]*$//' "$query_file"
        echo ";"
    } | $PSQL -f - 2>/dev/null \
        | awk '/^Time: / { print $2; exit }'
}

# CSV header for results
csv_header() { echo "query,iter,exec_ms"; }

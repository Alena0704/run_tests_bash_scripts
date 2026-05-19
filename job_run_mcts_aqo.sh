#!/bin/bash
# Compare three configurations to gauge how cardinality error affects
# MCTS-driven join ordering:
#
#   1. plain_pg   -- vanilla PostgreSQL planner (DP), default statistics
#   2. mcts_only  -- MCTS_extreme join search, default statistics
#   3. mcts_aqo   -- MCTS_extreme join search, AQO 'learn' mode (cardinality
#                    estimates are corrected per-query as AQO learns from
#                    actual row counts of previous executions)
#
# For each configuration, we:
#   - save EXPLAIN (cost-only) plans into plans/<cfg>/
#   - capture per-iter execution times into results/<cfg>_job.csv
#
# AQO learning is built up over the ITERS reruns of each query: AQO starts
# from PG's cardinality estimates, learns from instrumentation on iter 1,
# and feeds corrected estimates back on iters 2..N.  We expect mcts_aqo to
# converge to lower cost / faster wall time than mcts_only on queries where
# PG's cardinality estimates are systematically off.
#
# Prerequisites:
#   - PG built with the AQO core hooks patch (see contrib/aqo/aqo_master.patch)
#   - shared_preload_libraries = 'aqo' in postgresql.conf
#   - CREATE EXTENSION aqo (per database)
#   - mcts_extreme.so installed (LOAD'ed per session)
#
# Usage: ./job_run_mcts_aqo.sh [database] [iters] [configs]
#   configs: space-separated subset of {plain_pg mcts_only mcts_aqo}
#   defaults: imdb, $ITERS from lib.sh, all three configs.

set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

DB="${1:-imdb}"
ITERS="${2:-$ITERS}"
CONFIGS="${3:-plain_pg mcts_only mcts_aqo}"

export PGDATABASE="$DB"
PSQL="$INSTDIR/psql -p $PGPORT -d $DB -U $PGUSER -X -q"

mkdir -p "$RESULTS_DIR" "$LOG_DIR"
pg_ensure_up

# Per-config SET block, emitted at the start of each psql script.
cfg_setup() {
    local cfg="$1"
    case "$cfg" in
        plain_pg)
            cat <<'EOF'
SET aqo.mode = 'disabled';
EOF
            ;;
        mcts_only)
            cat <<'EOF'
LOAD 'mcts_extreme';
SET mcts_extreme.enabled = on;
SET mcts_extreme.log_debug = off;
SET mcts_extreme.log_steps = off;
SET aqo.mode = 'disabled';
EOF
            ;;
        mcts_aqo)
            # 'learn' = AQO replaces cardinality estimates with its own
            # ML-predicted values and learns from instrumentation each run.
            cat <<'EOF'
LOAD 'mcts_extreme';
SET mcts_extreme.enabled = on;
SET mcts_extreme.log_debug = off;
SET mcts_extreme.log_steps = off;
SET aqo.mode = 'learn';
EOF
            ;;
        *)
            echo "Unknown config: $cfg" >&2
            return 1
            ;;
    esac
}

save_explain_cfg() {
    local query_file="$1" cfg="$2"
    local name plan_file
    name="$(basename "$query_file" .sql)"
    plan_file="$PLANS_DIR/$cfg/${name}.plan"
    mkdir -p "$PLANS_DIR/$cfg"
    {
        cfg_setup "$cfg"
        echo "SET statement_timeout = ${STATEMENT_TIMEOUT_MS};"
        echo "EXPLAIN"
        sed 's/;[[:space:]]*$//' "$query_file"
        echo ";"
    } | $PSQL -f - > "$plan_file" 2>&1
}

# One timed run, echoes elapsed ms.  Caller must run iter 1..N in order so
# AQO has a chance to learn between iterations.
run_query_once_cfg() {
    local query_file="$1" cfg="$2"
    {
        cfg_setup "$cfg"
        echo "SET statement_timeout = ${STATEMENT_TIMEOUT_MS};"
        echo "\\timing on"
        sed 's/;[[:space:]]*$//' "$query_file"
        echo ";"
    } | $PSQL -f - 2>/dev/null \
        | awk '/^Time: / { print $2; exit }'
}

queries=("$QUERY_FILES"/*.sql)
total=${#queries[@]}

for cfg in $CONFIGS; do
    echo
    echo "========================================"
    echo "Config: $cfg"
    echo "========================================"

    OUT_CSV="$RESULTS_DIR/${cfg}_job.csv"
    csv_header > "$OUT_CSV"

    for idx in "${!queries[@]}"; do
        qf="${queries[$idx]}"
        name="$(basename "$qf" .sql)"
        n=$((idx + 1))
        echo "[$cfg][$n/$total] $name"

        save_explain_cfg "$qf" "$cfg"

        for i in $(seq 1 "$ITERS"); do
            ms=$(run_query_once_cfg "$qf" "$cfg")
            ms="${ms:-NA}"
            echo "$name,$i,$ms" >> "$OUT_CSV"
        done
    done

    echo "  Plans -> $PLANS_DIR/$cfg"
    echo "  Times -> $OUT_CSV"
done

echo
echo "Done. CSVs in $RESULTS_DIR/{plain_pg,mcts_only,mcts_aqo}_job.csv"

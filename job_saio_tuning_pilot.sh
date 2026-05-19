#!/bin/bash
# SAIO parameter pilot: a/b/c configurations vs SAIO defaults on 4
# worst-case JOB queries.  Output: per_query.csv with planning_ms,
# exec_ms columns per (config, query, iter).
#
# Usage: ./job_saio_tuning_pilot.sh [database] [iters]
#   defaults: imdb, 3 iters
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

DB="${1:-imdb}"
ITERS_LOCAL="${2:-3}"

export PGDATABASE="$DB"
PSQL="$INSTDIR/psql -p $PGPORT -d $DB -U $PGUSER -X -q"

RUN_ID="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="$RESULTS_DIR/saio_tuning/$RUN_ID"
mkdir -p "$OUT_DIR"
PER_Q="$OUT_DIR/per_query.csv"
LOG="$OUT_DIR/log.txt"

pg_ensure_up

# Selected pilot queries.
QUERIES=(29a 29c 26c 28a 33c)

# ---- per-config GUC blocks --------------------------------------------
PG_BLOCK=$(cat <<'EOF'
SET geqo = on;
SET geqo_threshold = 12;
SET from_collapse_limit = 100;
SET join_collapse_limit = 100;
EOF
)

# Defaults — match the original baseline run for control.
SAIO_DEFAULT=$(cat <<'EOF'
LOAD 'saio';
SET saio = on;
SET geqo = off;
SET from_collapse_limit = 100;
SET join_collapse_limit = 100;
SET saio_equilibrium_factor = 16;
SET saio_initial_temperature_factor = 2.0;
SET saio_temperature_reduction_factor = 0.9;
SET saio_moves_before_frozen = 4;
EOF
)

# (a) Cheap — short equilibrium, fast cool, early freeze.  ~10x cheaper
#     loop than defaults; assumes the algorithm is now actually exploring.
SAIO_CHEAP=$(cat <<'EOF'
LOAD 'saio';
SET saio = on;
SET geqo = off;
SET from_collapse_limit = 100;
SET join_collapse_limit = 100;
SET saio_equilibrium_factor = 4;
SET saio_initial_temperature_factor = 2.0;
SET saio_temperature_reduction_factor = 0.7;
SET saio_moves_before_frozen = 2;
EOF
)

# (b) Cheaper still — tiny equilibrium, very fast cool.  ~25x cheaper than
#     defaults but may sacrifice plan quality.
SAIO_CHEAPER=$(cat <<'EOF'
LOAD 'saio';
SET saio = on;
SET geqo = off;
SET from_collapse_limit = 100;
SET join_collapse_limit = 100;
SET saio_equilibrium_factor = 2;
SET saio_initial_temperature_factor = 1.0;
SET saio_temperature_reduction_factor = 0.5;
SET saio_moves_before_frozen = 2;
EOF
)

cfg_gucs() {
    case "$1" in
        pg)             echo "$PG_BLOCK" ;;
        saio_default)   echo "$SAIO_DEFAULT" ;;
        saio_cheap)     echo "$SAIO_CHEAP" ;;
        saio_cheaper)   echo "$SAIO_CHEAPER" ;;
        *) echo "Unknown config: $1" >&2; return 1 ;;
    esac
    echo "SET statement_timeout = ${STATEMENT_TIMEOUT_MS};"
}

run_once() {
    local qf="$1" cfg="$2"
    local body raw top planning exec
    body=$(sed 's/;[[:space:]]*$//' "$qf")
    raw=$(
        {
            cfg_gucs "$cfg"
            echo "EXPLAIN (ANALYZE, TIMING ON, BUFFERS OFF)"
            echo "$body"
            echo ";"
        } | "$INSTDIR/psql" -p "$PGPORT" -d "$DB" -U "$PGUSER" -X -f /dev/stdin 2>&1
    )
    top=$(echo "$raw" | awk 'match($0, /cost=[0-9.]+\.\.[0-9.]+/) {
        c = substr($0, RSTART+5, RLENGTH-5); split(c, a, /\.\./); print a[2]; exit
    }')
    planning=$(echo "$raw" | awk '/Planning Time:/ { print $3; exit }')
    exec=$(echo "$raw" | awk '/Execution Time:/ { print $3; exit }')
    [[ -z "$top" ]]      && top="NA"
    [[ -z "$planning" ]] && planning="NA"
    [[ -z "$exec" ]]     && exec="NA"
    echo "$top $planning $exec"
}

{
    echo "RUN_ID=$RUN_ID"
    echo "DB=$DB  ITERS=$ITERS_LOCAL  QUERIES=${QUERIES[*]}"
    echo "Output: $OUT_DIR"
} | tee "$LOG"

echo "query,config,iter,planning_ms,exec_ms,top_cost" > "$PER_Q"

CONFIGS=(pg saio_default saio_cheap saio_cheaper)
for cfg in "${CONFIGS[@]}"; do
    t0=$(date +%s)
    printf "[%s] === %s ===\n" "$(date +%H:%M:%S)" "$cfg" | tee -a "$LOG"
    for q in "${QUERIES[@]}"; do
        qf="$QUERY_FILES/${q}.sql"
        for i in $(seq 1 "$ITERS_LOCAL"); do
            read -r top planning exec <<<"$(run_once "$qf" "$cfg")"
            echo "$q,$cfg,$i,$planning,$exec,$top" >> "$PER_Q"
            printf "  [%s] %s iter %d  plan=%s  exec=%s\n" \
                "$(date +%H:%M:%S)" "$q" "$i" "$planning" "$exec" \
                | tee -a "$LOG"
        done
    done
    t1=$(date +%s)
    printf "  %s done in %ds\n" "$cfg" "$((t1 - t0))" | tee -a "$LOG"
done

echo "---" | tee -a "$LOG"
echo "Per-query CSV: $PER_Q" | tee -a "$LOG"

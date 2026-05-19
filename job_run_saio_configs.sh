#!/bin/bash
# Compare planning + execution time across PostgreSQL and two SAIO tunings on
# JOB queries with more than 11 base relations.
#
# Configs:
#   pg            : default planner (geqo=on, geqo_threshold=12).
#   saio_default  : LOAD 'saio'; defaults (equilibrium_factor=16,
#                   T_init_factor=2.0, reduction=0.9, moves_before_frozen=4).
#   saio_cheap    : LOAD 'saio'; cheaper SA loop (equilibrium_factor=4,
#                   reduction=0.7, moves_before_frozen=2).
#
# Output schema matches job_run_saio_vs_pg.sh so make_saio_plots.py can pick it
# up if the plot script is taught about the extra config; we'll also emit a
# dedicated 3-way summary.
#
# Usage: ./job_run_saio_configs.sh [database] [iters] [min_rels]
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

DB="${1:-imdb}"
ITERS_LOCAL="${2:-3}"
MIN_RELS="${3:-12}"

export PGDATABASE="$DB"
PSQL="$INSTDIR/psql -p $PGPORT -d $DB -U $PGUSER -X -q"

RUN_ID="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="$RESULTS_DIR/compare_saio/$RUN_ID"
mkdir -p "$OUT_DIR"
PER_Q="$OUT_DIR/per_query.csv"
LOG="$OUT_DIR/log.txt"

pg_ensure_up

# ---- per-config GUC blocks --------------------------------------------
PG_BLOCK=$(cat <<'EOF'
SET geqo = on;
SET geqo_threshold = 12;
SET from_collapse_limit = 100;
SET join_collapse_limit = 100;
EOF
)

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
SET saio_restarts = 1;
EOF
)

CHEAP_BASE=$(cat <<'EOF'
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

SAIO_CHEAP="$CHEAP_BASE"$'\nSET saio_restarts = 1;'
SAIO_CHEAP_R3="$CHEAP_BASE"$'\nSET saio_restarts = 3;'
SAIO_CHEAP_R5="$CHEAP_BASE"$'\nSET saio_restarts = 5;'

cfg_gucs() {
    case "$1" in
        pg)             echo "$PG_BLOCK" ;;
        saio_default)   echo "$SAIO_DEFAULT" ;;
        saio_cheap)     echo "$SAIO_CHEAP" ;;
        saio_cheap_r3)  echo "$SAIO_CHEAP_R3" ;;
        saio_cheap_r5)  echo "$SAIO_CHEAP_R5" ;;
        *) echo "Unknown config: $1" >&2; return 1 ;;
    esac
    echo "SET statement_timeout = ${STATEMENT_TIMEOUT_MS};"
}

n_rels_for() {
    awk '
        BEGIN { in_from = 0; from_buf = "" }
        /^[[:space:]]*FROM([[:space:]]|$)/ { in_from = 1 }
        in_from {
            sub(/^[[:space:]]*FROM[[:space:]]+/, "")
            if (match($0, /^[[:space:]]*WHERE([[:space:]]|$)/)) { in_from = 0; exit }
            from_buf = from_buf " " $0
        }
        END {
            sub(/[[:space:]]+WHERE[[:space:]].*/, "", from_buf)
            n = split(from_buf, _, ","); print n
        }
    ' "$1"
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

    local qname plan_dir plan_file
    qname="$(basename "$qf" .sql)"
    plan_dir="$OUT_DIR/plans/$cfg"
    plan_file="$plan_dir/${qname}.plan"
    if [[ ! -f "$plan_file" ]]; then
        mkdir -p "$plan_dir"
        echo "$raw" | awk '
            /QUERY PLAN/ {keep=1}
            keep { print; if (/\([0-9]+ rows?\)/) { keep=0; exit } }
        ' > "$plan_file"
    fi
    echo "$top $planning $exec"
}

queries=( "$QUERY_FILES"/*.sql )
total=${#queries[@]}

{
    echo "RUN_ID=$RUN_ID"
    echo "DB=$DB  ITERS=$ITERS_LOCAL  MIN_RELS=$MIN_RELS"
    echo "QUERY_DIR=$QUERY_FILES  count=$total"
    echo "STMT_TIMEOUT_MS=$STATEMENT_TIMEOUT_MS"
    echo "Output: $OUT_DIR"
} | tee "$LOG"

declare -a SEL_QF SEL_NAME SEL_NRELS
for qf in "${queries[@]}"; do
    name="$(basename "$qf" .sql)"
    nr=$(n_rels_for "$qf")
    [[ -z "$nr" || "$nr" -lt "$MIN_RELS" ]] && continue
    SEL_QF+=("$qf"); SEL_NAME+=("$name"); SEL_NRELS+=("$nr")
done
sel_total=${#SEL_QF[@]}
echo "Selected $sel_total queries with n_rels >= $MIN_RELS" | tee -a "$LOG"
(( sel_total == 0 )) && exit 0

echo "query,n_rels,config,iter,planning_ms,exec_ms,top_cost" > "$PER_Q"

for cfg in pg saio_cheap saio_cheap_r3; do
    cfg_t_start=$(date +%s)
    printf "[%s] === %s ===\n" "$(date +%H:%M:%S)" "$cfg" | tee -a "$LOG"
    for idx in "${!SEL_QF[@]}"; do
        qf="${SEL_QF[$idx]}"; name="${SEL_NAME[$idx]}"; nrels="${SEL_NRELS[$idx]}"
        for i in $(seq 1 "$ITERS_LOCAL"); do
            read -r top planning exec <<<"$(run_once "$qf" "$cfg")"
            echo "$name,$nrels,$cfg,$i,$planning,$exec,$top" >> "$PER_Q"
        done
        printf "  [%s] %s n_rels=%s  planning=%s  exec=%s\n" \
            "$(date +%H:%M:%S)" "$name" "$nrels" "$planning" "$exec" \
            | tee -a "$LOG"
    done
    cfg_t_end=$(date +%s)
    printf "  config %s done in %ds\n" "$cfg" "$((cfg_t_end - cfg_t_start))" \
        | tee -a "$LOG"
done

echo "---" | tee -a "$LOG"
echo "Per-query CSV: $PER_Q" | tee -a "$LOG"

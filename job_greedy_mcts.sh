#!/bin/bash
# Greedy (coordinate-descent) parameter search for MCTS_extreme GUCs.
#
# For each parameter, in a fixed order, we sweep a small candidate set,
# rerun the JOB benchmark with all other GUCs pinned to the best values
# discovered so far, and keep the candidate that minimises the chosen
# metric.  Much cheaper than grid search; gives a reasonable local optimum.
#
# Two metrics:
#   --metric=cost  (default) -- geomean of "MCTS Best Cost" from EXPLAIN.
#                                Plan-only run (no execution); fast.
#   --metric=exec  -- geomean of median exec_ms across ITERS reruns.
#                     Honest end-to-end signal; slow.
#
# Output:
#   results/greedy/<run-id>/log.csv        every sweep recorded
#   results/greedy/<run-id>/best.env       shell-sourceable final config
#
# Usage:
#   ./job_greedy_mcts.sh [database] [iters] [--metric=cost|exec] \
#                        [--queries=path]   [--start-from=PARAM] \
#                        [--skip=PARAM,...] [--dry-run]
#
# NOTE: written for /bin/bash 3.2 (macOS default) -- no associative arrays.

set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

# ---- arg parsing --------------------------------------------------------
DB="imdb"
ITERS_LOCAL="$ITERS"
METRIC="cost"
QUERIES_DIR="$QUERY_FILES"
START_FROM=""
SKIP_LIST=""
DRY_RUN=0
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --metric=*)     METRIC="${arg#--metric=}" ;;
        --queries=*)    QUERIES_DIR="${arg#--queries=}" ;;
        --start-from=*) START_FROM="${arg#--start-from=}" ;;
        --skip=*)       SKIP_LIST="${arg#--skip=}" ;;
        --dry-run)      DRY_RUN=1 ;;
        --*)            echo "Unknown flag: $arg" >&2; exit 2 ;;
        *)              POSITIONAL+=("$arg") ;;
    esac
done
[[ ${#POSITIONAL[@]} -ge 1 ]] && DB="${POSITIONAL[0]}"
[[ ${#POSITIONAL[@]} -ge 2 ]] && ITERS_LOCAL="${POSITIONAL[1]}"

export PGDATABASE="$DB"
PSQL="$INSTDIR/psql -p $PGPORT -d $DB -U $PGUSER -X -q"

case "$METRIC" in
    cost|exec) ;;
    *) echo "metric must be cost|exec, got '$METRIC'" >&2; exit 2 ;;
esac

# ---- parameter sweep order, grids, and starting point ------------------
# Greedy order: most plan-shape-impactful first.  Edit freely.
PARAM_ORDER="kernels depth start_budget phases exploration_constant top_k rollouts_per_leaf patience"

grid_for() {
    case "$1" in
        kernels)              echo "0 1 2" ;;
        depth)                echo "2 3 4 5 8" ;;
        start_budget)         echo "50 100 200 400" ;;
        phases)               echo "1 3 5 10" ;;
        exploration_constant) echo "0.7 1.0 1.4 2.0 3.0" ;;
        top_k)                echo "0 3 5 10" ;;
        rollouts_per_leaf)    echo "1 2 4 8" ;;
        patience)             echo "0 2 5" ;;
        *)                    echo "" ;;
    esac
}

# Current best (mutated as the greedy walk picks winners).
# Each CUR_* can be pre-seeded via environment variable so a second pass
# can pin the first pass's winners (e.g. CUR_depth=8 CUR_top_k=10 ...).
CUR_kernels="${CUR_kernels:-1}"
CUR_depth="${CUR_depth:-2}"
CUR_start_budget="${CUR_start_budget:-100}"
CUR_phases="${CUR_phases:-5}"
CUR_exploration_constant="${CUR_exploration_constant:-1.4}"
CUR_top_k="${CUR_top_k:-5}"
CUR_rollouts_per_leaf="${CUR_rollouts_per_leaf:-1}"
CUR_patience="${CUR_patience:-0}"

get_cur() { eval "echo \$CUR_$1"; }
set_cur() { eval "CUR_$1=\"$2\""; }

# Honour --start-from / --skip filters by trimming PARAM_ORDER.
if [[ -n "$START_FROM" ]]; then
    new=""; found=0
    for p in $PARAM_ORDER; do
        [[ "$p" == "$START_FROM" ]] && found=1
        [[ "$found" -eq 1 ]] && new="$new $p"
    done
    PARAM_ORDER="$(echo "$new" | sed 's/^ //')"
fi
if [[ -n "$SKIP_LIST" ]]; then
    skips="$(echo "$SKIP_LIST" | tr ',' ' ')"
    new=""
    for p in $PARAM_ORDER; do
        keep=1
        for s in $skips; do [[ "$p" == "$s" ]] && keep=0; done
        [[ "$keep" -eq 1 ]] && new="$new $p"
    done
    PARAM_ORDER="$(echo "$new" | sed 's/^ //')"
fi

# ---- output paths -------------------------------------------------------
RUN_ID="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="$RESULTS_DIR/greedy/$RUN_ID"
mkdir -p "$OUT_DIR"
LOG_CSV="$OUT_DIR/log.csv"
echo "round,param,value,metric,${METRIC}_geomean,n_queries,fixed_config" > "$LOG_CSV"
echo "RUN_ID=$RUN_ID  METRIC=$METRIC  DB=$DB  ITERS=$ITERS_LOCAL"
echo "PARAM_ORDER: $PARAM_ORDER"
echo "Output: $OUT_DIR"

pg_ensure_up

# ---- helpers ------------------------------------------------------------
queries=( "$QUERIES_DIR"/*.sql )
total_queries=${#queries[@]}

mcts_set_block() {
    cat <<EOF
LOAD 'mcts_extreme';
SET mcts_extreme.enabled = on;
SET mcts_extreme.log_debug = off;
SET mcts_extreme.log_steps = off;
SET mcts_extreme.kernels = $CUR_kernels;
SET mcts_extreme.depth = $CUR_depth;
SET mcts_extreme.start_budget = $CUR_start_budget;
SET mcts_extreme.phases = $CUR_phases;
SET mcts_extreme.exploration_constant = $CUR_exploration_constant;
SET mcts_extreme.top_k = $CUR_top_k;
SET mcts_extreme.rollouts_per_leaf = $CUR_rollouts_per_leaf;
SET mcts_extreme.patience = $CUR_patience;
SET statement_timeout = ${STATEMENT_TIMEOUT_MS};
EOF
}

# EXPLAIN one query; echo MCTS Best Cost or "NA".
explain_one_cost() {
    local qf="$1"
    {
        mcts_set_block
        echo "EXPLAIN"
        sed 's/;[[:space:]]*$//' "$qf"
        echo ";"
    } | $PSQL -f - 2>/dev/null \
      | awk '/MCTS Best Cost:/ { gsub(",", "", $4); print $4; found=1; exit }
             END { if (!found) print "NA" }'
}

# Run one query once; echo elapsed ms.
exec_one_ms() {
    local qf="$1"
    {
        mcts_set_block
        echo "\\timing on"
        sed 's/;[[:space:]]*$//' "$qf"
        echo ";"
    } | $PSQL -f - 2>/dev/null \
      | awk '/^Time: / { print $2; exit }'
}

# Geomean of numbers from stdin (NA / empty / non-positive ignored).
geomean() {
    awk '
        BEGIN { n = 0; logsum = 0 }
        /^NA$/ || NF == 0 { next }
        ($1 + 0) > 0 { logsum += log($1); n++ }
        END {
            if (n == 0) { print "NA"; exit }
            printf "%.4f\n", exp(logsum / n)
        }'
}

run_one_config_cost() {
    for qf in "${queries[@]}"; do
        explain_one_cost "$qf"
    done
}

run_one_config_exec() {
    for qf in "${queries[@]}"; do
        ms_list=()
        for _ in $(seq 1 "$ITERS_LOCAL"); do
            ms="$(exec_one_ms "$qf")"
            [[ -z "$ms" ]] && ms="NA"
            ms_list+=("$ms")
        done
        # Median (lower-mid for even count).
        printf "%s\n" "${ms_list[@]}" | sort -g | awk -v n="${#ms_list[@]}" '
            NR == int((n + 1) / 2) { print; exit }'
    done
}

eval_current() {
    case "$METRIC" in
        cost) run_one_config_cost | geomean ;;
        exec) run_one_config_exec | geomean ;;
    esac
}

dump_current_config() {
    printf "kernels=%s depth=%s start_budget=%s phases=%s exploration_constant=%s top_k=%s rollouts_per_leaf=%s patience=%s" \
        "$CUR_kernels" "$CUR_depth" "$CUR_start_budget" "$CUR_phases" \
        "$CUR_exploration_constant" "$CUR_top_k" "$CUR_rollouts_per_leaf" \
        "$CUR_patience"
}

# Strict-less compare using awk; treats NA as +inf.
better_than() {
    # better_than NEW OLD -> exit 0 if NEW < OLD
    local new="$1" old="$2"
    [[ "$new" == "NA" ]] && return 1
    [[ "$old" == "NA" ]] && return 0
    awk -v a="$new" -v b="$old" 'BEGIN { exit !(a + 0 < b + 0) }'
}

# ---- greedy loop --------------------------------------------------------
round=0

echo
echo "=== Baseline (round 0): $(dump_current_config)"
if [[ "$DRY_RUN" -eq 1 ]]; then
    base_metric="dry-run"
else
    base_metric="$(eval_current)"
fi
echo "  ${METRIC}_geomean = $base_metric"
echo "0,baseline,,${METRIC},${base_metric},${total_queries},\"$(dump_current_config)\"" >> "$LOG_CSV"
BEST_METRIC="$base_metric"

for param in $PARAM_ORDER; do
    round=$((round + 1))
    grid="$(grid_for "$param")"
    if [[ -z "$grid" ]]; then
        echo "skip $param (no grid)"
        continue
    fi
    echo
    echo "=== Round $round: sweeping $param over [$grid]"
    saved_val="$(get_cur "$param")"
    best_val="$saved_val"
    best_m="$BEST_METRIC"

    for v in $grid; do
        set_cur "$param" "$v"
        if [[ "$DRY_RUN" -eq 1 ]]; then
            m="dry-run"
        else
            m="$(eval_current)"
        fi
        echo "    $param=$v -> ${METRIC}_geomean=$m"
        echo "$round,$param,$v,${METRIC},$m,${total_queries},\"$(dump_current_config)\"" >> "$LOG_CSV"

        if [[ "$DRY_RUN" -eq 0 ]] && better_than "$m" "$best_m"; then
            best_m="$m"
            best_val="$v"
        fi
    done

    set_cur "$param" "$best_val"
    BEST_METRIC="$best_m"
    echo "  >> picked $param=$best_val (${METRIC}_geomean=$best_m)"
done

# ---- save winning config ------------------------------------------------
BEST_ENV="$OUT_DIR/best.env"
{
    echo "# Greedy MCTS tuning result"
    echo "# metric=$METRIC  final_${METRIC}_geomean=$BEST_METRIC"
    echo "# baseline_${METRIC}_geomean=$base_metric"
    for k in kernels depth start_budget phases exploration_constant top_k rollouts_per_leaf patience; do
        printf "export MCTS_%s=%s\n" "$(echo "$k" | tr '[:lower:]' '[:upper:]')" "$(get_cur "$k")"
    done
    echo
    echo "# SQL form:"
    for k in kernels depth start_budget phases exploration_constant top_k rollouts_per_leaf patience; do
        echo "# SET mcts_extreme.$k = $(get_cur "$k");"
    done
} > "$BEST_ENV"

echo
echo "=== Done."
echo "  final ${METRIC}_geomean = $BEST_METRIC (baseline $base_metric)"
echo "  config: $(dump_current_config)"
echo "  log      -> $LOG_CSV"
echo "  best.env -> $BEST_ENV"

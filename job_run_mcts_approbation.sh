#!/bin/bash
# Approbation benchmark for contrib/mcts_extreme.
#
# Runs the JOB workload under five MCTS configurations covering the
# cartesian product of the two main UCT axes:
#
#   1. avg_only   -- reward_mode=average, luby_enabled=off, rollout=random
#   2. luby_only  -- reward_mode=best,    luby_enabled=on,  rollout=luby
#   3. avg_luby   -- reward_mode=average, luby_enabled=on,  rollout=luby
#   4. best_only  -- reward_mode=best,    luby_enabled=off, rollout=random
#   5. best_luby  -- reward_mode=best,    luby_enabled=on,  rollout=luby
#
# Plus a "plain_pg" baseline (MCTS disabled, vanilla DP/GEQO).
#
# All five MCTS configs share the **production-best substrate** we found
# in the parameter study (see min_job/adaptive_kernels/PARAM_STUDY.md):
#
#     kernels_mode = 'fixed'         kernels = 1
#     min_relations = 13             # gate: defer n<13 to PG-DP, no regression
#     depth = 8                      start_budget = 100
#     phases = 5                     top_k = 0       (no filter)
#     exploration_constant = 1.0     rollouts_per_leaf = 1
#     patience = 0
#
# The approbation thus isolates the *reward_mode x luby x rollout* axes
# against a strong baseline rather than against MCTS defaults.
#
# For each configuration we:
#   - dump plain EXPLAIN cost-only plans into plans/mcts_<cfg>/
#   - capture per-iter execution times into results/mcts_<cfg>_job.csv
#
# Usage:
#   ./job_run_mcts_approbation.sh [database] [iters] [configs]
#     configs: space-separated subset of
#              {avg_only luby_only avg_luby best_only best_luby plain_pg}
#     defaults: imdb, $ITERS from lib.sh, all six configs.
#
# Tune the production substrate via env (override only when you really
# want to retune): KERNELS_MODE, KERNELS, MIN_REL, DEPTH, START_BUDGET,
# PHASES, EXPL, TOP_K, RPL, PATIENCE.

set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

DB="${1:-imdb}"
ITERS="${2:-$ITERS}"
CONFIGS="${3:-plain_pg avg_only luby_only avg_luby best_only best_luby}"

export PGDATABASE="$DB"
PSQL="$INSTDIR/psql -p $PGPORT -d $DB -U $PGUSER -X -q"

mkdir -p "$RESULTS_DIR" "$LOG_DIR"
pg_ensure_up

# --- Production-best substrate (overridable via env) ----------------------
KERNELS_MODE="${KERNELS_MODE:-fixed}"
KERNELS="${KERNELS:-1}"
MIN_REL="${MIN_REL:-13}"
DEPTH="${DEPTH:-8}"
START_BUDGET="${START_BUDGET:-100}"
PHASES="${PHASES:-5}"
EXPL="${EXPL:-1.0}"
TOP_K="${TOP_K:-0}"
RPL="${RPL:-1}"
PATIENCE="${PATIENCE:-0}"

# Production substrate applied to every MCTS config below.
mcts_common_block() {
    cat <<EOF
SET mcts_extreme.enabled = on;
SET mcts_extreme.kernels_mode = '$KERNELS_MODE';
SET mcts_extreme.kernels = $KERNELS;
SET mcts_extreme.min_relations = $MIN_REL;
SET mcts_extreme.depth = $DEPTH;
SET mcts_extreme.start_budget = $START_BUDGET;
SET mcts_extreme.phases = $PHASES;
SET mcts_extreme.exploration_constant = $EXPL;
SET mcts_extreme.top_k = $TOP_K;
SET mcts_extreme.rollouts_per_leaf = $RPL;
SET mcts_extreme.patience = $PATIENCE;
EOF
}

# Translate a config tag into the GUC SET block that pins the axis under
# test (reward_mode x luby x rollout).  plain_pg disables MCTS entirely.
mcts_set_block() {
    local cfg="$1"
    case "$cfg" in
        plain_pg)
            cat <<'EOF'
SET mcts_extreme.enabled = off;
EOF
            ;;
        avg_only)
            mcts_common_block
            cat <<'EOF'
SET mcts_extreme.reward_mode = 'average';
SET mcts_extreme.luby_enabled = off;
SET mcts_extreme.rollout = 'random';
EOF
            ;;
        luby_only)
            mcts_common_block
            cat <<'EOF'
SET mcts_extreme.reward_mode = 'best';
SET mcts_extreme.luby_enabled = on;
SET mcts_extreme.rollout = 'luby';
EOF
            ;;
        avg_luby)
            mcts_common_block
            cat <<'EOF'
SET mcts_extreme.reward_mode = 'average';
SET mcts_extreme.luby_enabled = on;
SET mcts_extreme.rollout = 'luby';
EOF
            ;;
        best_only)
            mcts_common_block
            cat <<'EOF'
SET mcts_extreme.reward_mode = 'best';
SET mcts_extreme.luby_enabled = off;
SET mcts_extreme.rollout = 'random';
EOF
            ;;
        best_luby)
            mcts_common_block
            cat <<'EOF'
SET mcts_extreme.reward_mode = 'best';
SET mcts_extreme.luby_enabled = on;
SET mcts_extreme.rollout = 'luby';
EOF
            ;;
        *)
            echo "Unknown config: $cfg" >&2
            return 1
            ;;
    esac
}

# Quieter logging by default; flip log_debug on if you want per-step WARNINGs.
COMMON_SETUP=$(cat <<'EOF'
LOAD 'mcts_extreme';
SET mcts_extreme.log_debug = off;
SET mcts_extreme.log_steps = off;
EOF
)

# Echo the substrate to stderr so the run is self-documenting.
{
    echo "================================================================"
    echo "MCTS approbation — production-best substrate:"
    echo "  kernels_mode=$KERNELS_MODE  kernels=$KERNELS  min_relations=$MIN_REL"
    echo "  depth=$DEPTH  start_budget=$START_BUDGET  phases=$PHASES"
    echo "  exploration_constant=$EXPL  top_k=$TOP_K"
    echo "  rollouts_per_leaf=$RPL  patience=$PATIENCE"
    echo "  ITERS=$ITERS  DB=$DB"
    echo "  configs: $CONFIGS"
    echo "================================================================"
} >&2

# EXPLAIN (cost-only) with the chosen settings baked into the same session.
save_explain_mcts() {
    local query_file="$1" cfg="$2"
    local name plan_file
    name="$(basename "$query_file" .sql)"
    plan_file="$PLANS_DIR/mcts_${cfg}/${name}.plan"
    mkdir -p "$PLANS_DIR/mcts_${cfg}"
    {
        echo "$COMMON_SETUP"
        mcts_set_block "$cfg"
        echo "SET statement_timeout = ${STATEMENT_TIMEOUT_MS};"
        echo "EXPLAIN"
        sed 's/;[[:space:]]*$//' "$query_file"
        echo ";"
    } | $PSQL -f - > "$plan_file" 2>&1
}

# One timed run with MCTS settings; echoes elapsed ms.
run_query_once_mcts() {
    local query_file="$1" cfg="$2"
    {
        echo "$COMMON_SETUP"
        mcts_set_block "$cfg"
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
    echo "Config: mcts_${cfg}"
    echo "========================================"

    OUT_CSV="$RESULTS_DIR/mcts_${cfg}_job.csv"
    csv_header > "$OUT_CSV"

    for idx in "${!queries[@]}"; do
        qf="${queries[$idx]}"
        name="$(basename "$qf" .sql)"
        n=$((idx + 1))
        echo "[mcts_${cfg}][$n/$total] $name"

        save_explain_mcts "$qf" "$cfg"

        for i in $(seq 1 "$ITERS"); do
            ms=$(run_query_once_mcts "$qf" "$cfg")
            ms="${ms:-NA}"
            echo "$name,$i,$ms" >> "$OUT_CSV"
        done
    done

    echo "  Plans -> $PLANS_DIR/mcts_${cfg}"
    echo "  Times -> $OUT_CSV"
done

echo
echo "Done. Compare CSVs in $RESULTS_DIR/mcts_*_job.csv"
echo "Tip: 'plain_pg' is included as the zero-MCTS baseline.  Each other config"
echo "     should be within ±5% of plain_pg on most queries (the gate=13 setup"
echo "     makes MCTS active only for n_rels>=13, ~8% of JOB)."

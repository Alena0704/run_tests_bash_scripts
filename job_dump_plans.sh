#!/bin/bash
# Dump EXPLAIN plans for each (query, config) so you can compare plan
# structure visually per query.  Plan-only (no execution) — fast.
#
# For each config, writes:
#   $PLANS_DIR/<config>/<query>.plan
#
# Plus a single side-by-side digest:
#   $PLANS_DIR/diff/<query>.txt   -- top of each config's EXPLAIN for that query
#
# Default configs match job_compare_methods.sh.  Pass a subset as $3.
#
# Usage:
#   ./job_dump_plans.sh [database] [analyze=0|1] [configs]
#     analyze=1 -> use EXPLAIN (ANALYZE, BUFFERS) — slow but shows actual rows
#     analyze=0 -> plain EXPLAIN (fast, default)
#     configs  -- subset of: pg mcts pg_aqo mcts_aqo dp geqo dp_aqo geqo_aqo
#
# Output:
#   plans/<config>/<query>.plan
#   plans/diff/<query>.txt     -- 4 configs aligned, one block per cfg

set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

DB="${1:-imdb}"
ANALYZE="${2:-0}"
CONFIGS="${3:-pg mcts pg_aqo mcts_aqo}"

export PGDATABASE="$DB"
PSQL="$INSTDIR/psql -p $PGPORT -d $DB -U $PGUSER -X -q"

# Auto-rename legacy dp/geqo/dp_aqo/geqo_aqo to their "natural" siblings
# for the writer side.  (Reading old comparison data is up to the user.)
mkdir -p "$PLANS_DIR/diff"

pg_ensure_up

# Same blocks as job_compare_methods.sh — kept aligned for reproducibility.
MCTS_BLOCK=$(cat <<'EOF'
LOAD 'mcts_extreme';
SET mcts_extreme.enabled = on;
SET mcts_extreme.log_debug = off;
SET mcts_extreme.kernels_mode = 'fixed';
SET mcts_extreme.kernels = 1;
SET mcts_extreme.min_relations = 2;
SET mcts_extreme.depth = 8;
SET mcts_extreme.start_budget = 100;
SET mcts_extreme.phases = 5;
SET mcts_extreme.exploration_constant = 1.0;
SET mcts_extreme.top_k = 0;
SET mcts_extreme.rollouts_per_leaf = 1;
SET mcts_extreme.patience = 0;
EOF
)

AQO_CONTROLLED=$(cat <<'EOF'
LOAD 'aqo';
SET aqo.mode = 'controlled';
SET aqo.force_collect_stat = on;
SET aqo.show_details = on;
EOF
)
AQO_OFF="LOAD 'aqo'; SET aqo.mode = 'disabled';"

PG_NATURAL=$(cat <<'EOF'
SET geqo = on;
SET geqo_threshold = 12;
SET from_collapse_limit = 12;
SET join_collapse_limit = 12;
EOF
)
DP_FORCE=$(cat <<'EOF'
SET geqo = off;
SET from_collapse_limit = 100;
SET join_collapse_limit = 100;
EOF
)
GEQO_FORCE=$(cat <<'EOF'
SET geqo = on;
SET geqo_threshold = 2;
SET from_collapse_limit = 100;
SET join_collapse_limit = 100;
EOF
)

cfg_gucs() {
    local cfg="$1"
    case "$cfg" in
        pg)         echo "$AQO_OFF";        echo "$PG_NATURAL" ;;
        mcts)       echo "$AQO_OFF";        echo "$PG_NATURAL"; echo "$MCTS_BLOCK" ;;
        pg_aqo)     echo "$AQO_CONTROLLED"; echo "$PG_NATURAL" ;;
        mcts_aqo)   echo "$AQO_CONTROLLED"; echo "$PG_NATURAL"; echo "$MCTS_BLOCK" ;;
        dp)         echo "$AQO_OFF";        echo "$DP_FORCE" ;;
        geqo)       echo "$AQO_OFF";        echo "$GEQO_FORCE" ;;
        dp_aqo)     echo "$AQO_CONTROLLED"; echo "$DP_FORCE" ;;
        geqo_aqo)   echo "$AQO_CONTROLLED"; echo "$GEQO_FORCE" ;;
        *) echo "Unknown config: $cfg" >&2; return 1 ;;
    esac
    echo "SET statement_timeout = ${STATEMENT_TIMEOUT_MS};"
}

if [[ "$ANALYZE" == "1" ]]; then
    EXPLAIN_KW="EXPLAIN (ANALYZE, BUFFERS, VERBOSE)"
    SUFFIX="analyze"
else
    EXPLAIN_KW="EXPLAIN (VERBOSE)"
    SUFFIX="plan"
fi

dump_one() {
    local qf="$1" cfg="$2"
    local name="$(basename "$qf" .sql)"
    local outdir="$PLANS_DIR/$cfg"
    mkdir -p "$outdir"
    {
        cfg_gucs "$cfg"
        echo "$EXPLAIN_KW"
        sed 's/;[[:space:]]*$//' "$qf"
        echo ";"
    } | "$INSTDIR/psql" -p "$PGPORT" -d "$DB" -U "$PGUSER" -X -f /dev/stdin \
        > "$outdir/${name}.${SUFFIX}" 2>&1
}

queries=( "$QUERY_FILES"/*.sql )
total=${#queries[@]}

echo "Configs: $CONFIGS"
echo "Mode:    $([ "$ANALYZE" == "1" ] && echo "EXPLAIN ANALYZE (slow)" || echo "EXPLAIN (fast)")"
echo "Output:  $PLANS_DIR/{$CONFIGS,diff}"
echo ""

# 1) Dump per-config plans
for cfg in $CONFIGS; do
    printf "[%s] %s ... " "$(date +%H:%M:%S)" "$cfg"
    n=0
    for qf in "${queries[@]}"; do
        dump_one "$qf" "$cfg"
        n=$((n+1))
    done
    echo "$n plans -> $PLANS_DIR/$cfg/"
done

# 2) Build per-query side-by-side digest
echo ""
echo "[$(date +%H:%M:%S)] building side-by-side digests..."
for qf in "${queries[@]}"; do
    name="$(basename "$qf" .sql)"
    out="$PLANS_DIR/diff/${name}.txt"
    {
        echo "================================================================"
        echo "QUERY: $name"
        echo "================================================================"
        for cfg in $CONFIGS; do
            f="$PLANS_DIR/$cfg/${name}.${SUFFIX}"
            echo ""
            echo "---- [$cfg] ----"
            if [[ -f "$f" ]]; then
                # Strip leading psql noise (LOAD/SET output) — keep from QUERY PLAN onwards.
                awk '
                    /QUERY PLAN/ { keep=1 }
                    keep
                ' "$f" | head -40
            else
                echo "(missing)"
            fi
        done
    } > "$out"
done

echo ""
echo "=== Done ==="
echo "Per-config plans:   $PLANS_DIR/{$CONFIGS}/<query>.${SUFFIX}"
echo "Side-by-side diff:  $PLANS_DIR/diff/<query>.txt"
echo ""
echo "Tip: vimdiff/icdiff for any pair, e.g.:"
echo "  diff $PLANS_DIR/pg/1a.plan $PLANS_DIR/mcts/1a.plan | less"
echo "  cat  $PLANS_DIR/diff/1a.txt | less"

#!/bin/bash
# Compare planning quality of three join-search methods on JOB,
# with and without AQO providing learned cardinality estimates.
#
# Head-to-head comparison: PG (DP+GEQO mix) vs MCTS, with/without AQO.
#
#   pg         PG default join search.  No AQO.
#              -> auto: DP for n_rels < 12, GEQO for n_rels >= 12.
#   mcts       MCTS-extreme on ALL queries (no min_relations gate).  No AQO.
#              -> MCTS handles every query; head-to-head with PG.
#   pg_aqo     PG default + AQO (controlled mode, learned cardinalities).
#   mcts_aqo   MCTS on ALL queries + AQO.   ★ flagship comparison.
#
# Optional configs (pass as 3rd arg if needed):
#   dp_only    Force DP for ALL n_rels (geqo=off).            diagnostic.
#   geqo_only  Force GEQO for ALL n_rels (geqo_threshold=2).   diagnostic.
#
# Prerequisites (must be done BEFORE this script):
#   ./aqo_setup.sh imdb                            # extension installed
#   ./aqo_train.sh imdb 30                         # AQO trains on DP/GEQO plans
#   ./aqo_train.sh imdb 30 --with-mcts --no-reset  # AQO trains on MCTS plans
#
# (The second pass is critical: AQO's predictions are keyed by Plan node
#  shape, and MCTS produces different plan shapes than DP/GEQO. Without
#  the --with-mcts pass, mcts_aqo runs against an AQO trained on DP-only
#  plan shapes — unfair to MCTS.)
#
# Output:
#   $RESULTS_DIR/compare/<run-id>/per_query.csv  (long: query,n_rels,config,iter,exec_ms,top_cost)
#   $RESULTS_DIR/compare/<run-id>/summary.csv    (per-config aggregates vs DP)
#   $RESULTS_DIR/compare/<run-id>/log.txt
#
# Usage:
#   ./job_compare_methods.sh [database] [iters] [configs]
#     configs: any subset of {dp geqo mcts dp_aqo geqo_aqo mcts_aqo}
#     defaults: imdb, $ITERS from lib.sh, all six configs.

set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

DB="${1:-imdb}"
ITERS_LOCAL="${2:-$ITERS}"
CONFIGS="${3:-pg mcts pg_aqo mcts_aqo}"

export PGDATABASE="$DB"
PSQL="$INSTDIR/psql -p $PGPORT -d $DB -U $PGUSER -X -q"

RUN_ID="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="$RESULTS_DIR/compare/$RUN_ID"
mkdir -p "$OUT_DIR"
PER_Q="$OUT_DIR/per_query.csv"
SUMMARY="$OUT_DIR/summary.csv"
LOG="$OUT_DIR/log.txt"

pg_ensure_up

# Pre-check AQO presence if needed.
if echo "$CONFIGS" | grep -qE "_aqo"; then
    have_aqo=$($PSQL -tA -c "SELECT 1 FROM pg_extension WHERE extname='aqo'" 2>/dev/null || echo "")
    if [[ -z "$have_aqo" ]]; then
        echo "FATAL: aqo extension not installed in $DB" >&2
        echo "Hint: ./aqo_setup.sh $DB && ./aqo_train.sh $DB 30" >&2
        exit 1
    fi
fi

# ---- per-config GUC blocks ---------------------------------------------
MCTS_BLOCK=$(cat <<'EOF'
LOAD 'mcts_extreme';
SET mcts_extreme.enabled = on;
SET mcts_extreme.log_debug = off;
SET mcts_extreme.log_steps = off;
SET mcts_extreme.kernels_mode = 'fixed';
SET mcts_extreme.kernels = 1;
SET mcts_extreme.min_relations = 2;    -- NO GATE: MCTS runs on every query
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

AQO_OFF=$(cat <<'EOF'
LOAD 'aqo';
SET aqo.mode = 'disabled';
EOF
)

# PG natural behaviour: geqo=on, geqo_threshold=12 (defaults).
# DP runs for n_rels<12, GEQO for n_rels>=12 within the SAME config.
PG_NATURAL=$(cat <<'EOF'
SET geqo = on;
SET geqo_threshold = 12;
SET from_collapse_limit = 12;
SET join_collapse_limit = 12;
EOF
)

# Diagnostic-only: force DP for ALL queries.
DP_FORCE=$(cat <<'EOF'
SET geqo = off;
SET from_collapse_limit = 100;
SET join_collapse_limit = 100;
EOF
)

# Diagnostic-only: force GEQO for ALL queries (n>=2).
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
        dp_only)    echo "$AQO_OFF";        echo "$DP_FORCE" ;;
        geqo_only)  echo "$AQO_OFF";        echo "$GEQO_FORCE" ;;
        *)          echo "Unknown config: $cfg" >&2; return 1 ;;
    esac
    echo "SET statement_timeout = ${STATEMENT_TIMEOUT_MS};"
}

# ---- helpers ------------------------------------------------------------

# Run query once: capture top-level EXPLAIN cost AND exec time.
# Echoes "<top_cost> <ms>"; either may be "NA".
run_once() {
    local qf="$1" cfg="$2"
    local body="$(sed 's/;[[:space:]]*$//' "$qf")"
    local raw
    raw=$(
        {
            cfg_gucs "$cfg"
            echo "EXPLAIN"
            echo "$body"
            echo ";"
            echo "\\timing on"
            echo "$body"
            echo ";"
        } | "$INSTDIR/psql" -p "$PGPORT" -d "$DB" -U "$PGUSER" -X -f /dev/stdin 2>&1
    )
    # First cost= line = top of EXPLAIN
    local top
    top=$(echo "$raw" | awk 'match($0, /cost=[0-9.]+\.\.[0-9.]+/) {
        c = substr($0, RSTART+5, RLENGTH-5); split(c, a, /\.\./); print a[2]; exit
    }')
    # \timing is on AFTER the EXPLAIN, so there is exactly ONE "Time:" line —
    # the actual query.  Take the last to be safe in case AQO emits extras.
    local ms
    ms=$(echo "$raw" | awk '/^Time: / {last=$2} END {if (last!="") print last}')
    [[ -z "$top" ]] && top="NA"
    [[ -z "$ms"  ]] && ms="NA"

    # Save the EXPLAIN section to plans/<cfg>/<query>.plan (once per
    # (cfg, query) — first iter only, to avoid overwriting on each iter).
    local qname="$(basename "$qf" .sql)"
    local plan_dir="$OUT_DIR/plans/$cfg"
    local plan_file="$plan_dir/${qname}.plan"
    if [[ ! -f "$plan_file" ]]; then
        mkdir -p "$plan_dir"
        # Extract just the EXPLAIN portion: from "QUERY PLAN" to the blank
        # line that follows "(N rows)".
        echo "$raw" | awk '
            /QUERY PLAN/ {keep=1}
            keep {
                print
                if (/\([0-9]+ rows?\)/) { keep=0; exit }
            }
        ' > "$plan_file"
    fi

    echo "$top $ms"
}

# Compute n_rels per query via a cheap MCTS probe (min_relations=2, budget=1).
n_rels_for() {
    local qf="$1"
    {
        echo "LOAD 'mcts_extreme';"
        echo "SET mcts_extreme.enabled = on;"
        echo "SET mcts_extreme.log_debug = off;"
        echo "SET mcts_extreme.kernels = 1;"
        echo "SET mcts_extreme.min_relations = 2;"
        echo "SET mcts_extreme.start_budget = 1;"
        echo "SET mcts_extreme.phases = 1;"
        echo "EXPLAIN"; sed 's/;[[:space:]]*$//' "$qf"; echo ";"
    } | $PSQL 2>&1 | awk '/MCTS Relations:/ {print $3; exit}'
}

queries=( "$QUERY_FILES"/*.sql )
total=${#queries[@]}

{
    echo "RUN_ID=$RUN_ID"
    echo "DB=$DB  ITERS=$ITERS_LOCAL  CONFIGS=$CONFIGS"
    echo "QUERY_DIR=$QUERY_FILES  count=$total"
    echo "STMT_TIMEOUT_MS=$STATEMENT_TIMEOUT_MS"
    echo "Output: $OUT_DIR"
} | tee "$LOG"

echo "query,n_rels,config,iter,exec_ms,top_cost" > "$PER_Q"

# Cache n_rels lookup once.
declare -a Q_NAMES Q_NRELS
echo "[$(date +%H:%M:%S)] computing n_rels for $total queries..." | tee -a "$LOG"
for qf in "${queries[@]}"; do
    name="$(basename "$qf" .sql)"
    nr=$(n_rels_for "$qf")
    [[ -z "$nr" ]] && nr=0
    Q_NAMES+=("$name"); Q_NRELS+=("$nr")
done

# ---- main loop ----------------------------------------------------------
for cfg in $CONFIGS; do
    cfg_t_start=$(date +%s)
    printf "[%s] === %s ===\n" "$(date +%H:%M:%S)" "$cfg" | tee -a "$LOG"
    for idx in "${!queries[@]}"; do
        qf="${queries[$idx]}"; name="${Q_NAMES[$idx]}"; nrels="${Q_NRELS[$idx]}"
        for i in $(seq 1 "$ITERS_LOCAL"); do
            read -r top ms <<<"$(run_once "$qf" "$cfg")"
            echo "$name,$nrels,$cfg,$i,$ms,$top" >> "$PER_Q"
        done
    done
    cfg_t_end=$(date +%s)
    printf "  done in %ds\n" "$((cfg_t_end - cfg_t_start))" | tee -a "$LOG"
done

# ---- summary (pure awk) -------------------------------------------------
# Per (cfg, q) take the median exec_ms.  Then compute:
#   n_valid, geomean, median, total_s, wins/neutral/losses vs dp, geomean_ratio_vs_pg.
echo "config,n_valid,geomean_ms,median_ms,total_s,wins_vs_pg,neutral_vs_pg,losses_vs_pg,geomean_ratio_vs_pg" > "$SUMMARY"

awk -F, -v summary="$SUMMARY" '
    NR == 1 { next }
    $5 == "NA" { next }
    {
        cfg = $3; q = $1; ms = $5 + 0
        if (ms <= 0) next
        key = cfg SUBSEP q
        n[key]++
        # Accumulate sorted array per key using insertion (small N)
        vals[key, n[key]] = ms
        cfgs[cfg] = 1
        queries_seen[q] = 1
    }
    END {
        # median per (cfg, q)
        for (key in n) {
            split(key, kk, SUBSEP); cfg = kk[1]; q = kk[2]
            cnt = n[key]
            # sort the values
            for (i=1; i<=cnt; i++) arr[i] = vals[key, i]
            # insertion sort (cnt is small, e.g. ITERS=5)
            for (i=2; i<=cnt; i++) {
                v = arr[i]; j = i-1
                while (j >= 1 && arr[j] > v) { arr[j+1] = arr[j]; j-- }
                arr[j+1] = v
            }
            med = (cnt % 2) ? arr[(cnt+1)/2] : (arr[cnt/2] + arr[cnt/2 + 1]) / 2
            mq[cfg, q] = med
        }
        # collect baseline (dp) medians
        for (q in queries_seen) {
            if ((("pg", q) in mq)) pg_med[q] = mq["pg", q]
        }
        # per-config aggregates
        for (cfg in cfgs) {
            nq = 0; sumlog = 0; med_count = 0
            delete medlist
            tot_ms = 0
            wins = neut = losses = 0; nr = 0; sum_log_r = 0
            for (q in queries_seen) {
                if (!((cfg, q) in mq)) continue
                v = mq[cfg, q]
                if (v <= 0) continue
                nq++
                sumlog += log(v)
                tot_ms += v
                medlist[++med_count] = v
                if (cfg != "pg" && (q in pg_med) && pg_med[q] > 0) {
                    r = v / pg_med[q]
                    if (r < 0.95) wins++
                    else if (r > 1.05) losses++
                    else neut++
                    sum_log_r += log(r); nr++
                }
            }
            if (nq == 0) continue
            gm = exp(sumlog / nq)
            # median of medians (per cfg)
            for (i=2; i<=med_count; i++) {
                v=medlist[i]; j=i-1
                while (j>=1 && medlist[j]>v) { medlist[j+1]=medlist[j]; j-- }
                medlist[j+1]=v
            }
            if (med_count % 2) {
                mmed = medlist[(med_count+1)/2]
            } else {
                mmed = (medlist[med_count/2] + medlist[med_count/2+1]) / 2
            }
            gr = (nr > 0) ? exp(sum_log_r / nr) : "NA"
            printf "%s,%d,%.2f,%.2f,%.2f,%d,%d,%d,%s\n",
                cfg, nq, gm, mmed, tot_ms/1000.0, wins, neut, losses,
                (nr > 0 ? sprintf("%.4f", gr) : "NA") >> summary
        }
    }
' "$PER_Q"

# Pretty-print summary table
echo "" | tee -a "$LOG"
echo "=== Summary (median exec per query, aggregated) ===" | tee -a "$LOG"
{
    column -s, -t "$SUMMARY"
} | tee -a "$LOG"

{
    echo ""
    echo "=== compare done ==="
    echo "  per_query.csv -> $PER_Q"
    echo "  summary.csv   -> $SUMMARY"
    echo "  log.txt       -> $LOG"
    echo ""
    echo "Interpretation:"
    echo "  wins_vs_pg   -- queries where this config is >=5% FASTER than 'dp'"
    echo "  losses_vs_pg -- queries where this config is >=5% SLOWER  than 'dp'"
    echo "  geomean_ratio_vs_pg < 1 -- this config faster than DP on geomean"
} | tee -a "$LOG"

#!/bin/bash
# MCTS feature-ablation: start from production-best, turn ONE knob off at
# a time, measure the cost of removing each feature on JOB.
#
# Variants (each differs from `best` by ONE knob):
#
#   pg              No MCTS at all (PG default).               baseline-pg
#   best            Production-best config.                    baseline-mcts
#   no_gate         min_relations=2 (MCTS runs everywhere)
#   k0_bushy        kernels=0  (bushy instead of left-deep)
#   k_heur          kernels_mode=heuristic
#   k_bandit        kernels_mode=bandit  (cands 0,1,2)
#   with_topk5      top_k=5  (filter on)
#   low_depth       depth=2  (instead of 8)
#   low_budget      start_budget=50 phases=1
#   no_luby         luby_enabled=off rollout=random
#   reward_avg      reward_mode=average
#
# Output: for each variant a CSV of per-query (iter, exec_ms, top_cost)
# plus a summary that quantifies the cost of removing each feature
# (geomean ratio vs `best`, win/loss count vs `best`, vs `pg`).
#
# Usage:
#   ./job_run_mcts_ablation.sh [database] [iters] [variants]
#     variants: subset of the names above
#     defaults: imdb, ITERS from lib.sh, all variants
#
#   Optional env: METRIC=cost|exec (default: exec)
#   - METRIC=cost  -- plan-only via EXPLAIN (fast: ~min per variant)
#   - METRIC=exec  -- real exec time     (slow: ~5-10 min per variant @ ITERS=5)

set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

DB="${1:-imdb}"
ITERS_LOCAL="${2:-$ITERS}"
VARIANTS="${3:-pg best no_gate k0_bushy k_heur k_bandit with_topk5 low_depth low_budget no_luby reward_avg}"
METRIC="${METRIC:-exec}"

export PGDATABASE="$DB"
PSQL="$INSTDIR/psql -p $PGPORT -d $DB -U $PGUSER -X -q"

RUN_ID="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="$RESULTS_DIR/ablation/$RUN_ID"
mkdir -p "$OUT_DIR"
PER_Q="$OUT_DIR/per_query.csv"
SUMMARY="$OUT_DIR/summary.csv"
LOG="$OUT_DIR/log.txt"

pg_ensure_up

# Production-best substrate.  Each variant flips ONE setting.
PG_NATURAL="SET geqo = on; SET geqo_threshold = 12; SET from_collapse_limit = 12; SET join_collapse_limit = 12;"

variant_gucs() {
    local v="$1"
    # PG defaults always
    echo "LOAD 'aqo'; SET aqo.mode = 'disabled';"
    echo "$PG_NATURAL"

    if [[ "$v" == "pg" ]]; then
        return
    fi

    # All MCTS variants share this block; we then override ONE setting below.
    cat <<'EOF'
LOAD 'mcts_extreme';
SET mcts_extreme.enabled = on;
SET mcts_extreme.log_debug = off;
SET mcts_extreme.kernels_mode = 'fixed';
SET mcts_extreme.kernels = 1;
SET mcts_extreme.min_relations = 13;
SET mcts_extreme.depth = 8;
SET mcts_extreme.start_budget = 100;
SET mcts_extreme.phases = 5;
SET mcts_extreme.exploration_constant = 1.0;
SET mcts_extreme.top_k = 0;
SET mcts_extreme.rollouts_per_leaf = 1;
SET mcts_extreme.patience = 0;
SET mcts_extreme.luby_enabled = on;
SET mcts_extreme.rollout = 'luby';
SET mcts_extreme.reward_mode = 'best';
EOF
    # Per-variant override (ONE knob)
    case "$v" in
        best)        ;;  # nothing to flip
        no_gate)     echo "SET mcts_extreme.min_relations = 2;" ;;
        k0_bushy)    echo "SET mcts_extreme.kernels = 0;" ;;
        k_heur)      echo "SET mcts_extreme.kernels_mode = 'heuristic';" ;;
        k_bandit)    echo "SET mcts_extreme.kernels_mode = 'bandit';
                          SET mcts_extreme.kernels_candidates = '0,1,2';
                          SET mcts_extreme.kernels_max = 2;" ;;
        with_topk5)  echo "SET mcts_extreme.top_k = 5;" ;;
        low_depth)   echo "SET mcts_extreme.depth = 2;" ;;
        low_budget)  echo "SET mcts_extreme.start_budget = 50;
                          SET mcts_extreme.phases = 1;" ;;
        no_luby)     echo "SET mcts_extreme.luby_enabled = off;
                          SET mcts_extreme.rollout = 'random';" ;;
        reward_avg)  echo "SET mcts_extreme.reward_mode = 'average';" ;;
        *)           echo "Unknown variant: $v" >&2; return 1 ;;
    esac
}

# Run once: capture top-level cost AND exec time.
run_once() {
    local qf="$1" v="$2"
    local body="$(sed 's/;[[:space:]]*$//' "$qf")"

    if [[ "$METRIC" == "cost" ]]; then
        # Plan-only: just EXPLAIN, no exec.
        local raw
        raw=$(
            {
                variant_gucs "$v"
                echo "SET statement_timeout = ${STATEMENT_TIMEOUT_MS};"
                echo "EXPLAIN"
                echo "$body"
                echo ";"
            } | "$INSTDIR/psql" -p "$PGPORT" -d "$DB" -U "$PGUSER" -X -f /dev/stdin 2>&1
        )
        local top
        top=$(echo "$raw" | awk 'match($0, /cost=[0-9.]+\.\.[0-9.]+/) {
            c = substr($0, RSTART+5, RLENGTH-5); split(c, a, /\.\./); print a[2]; exit
        }')
        [[ -z "$top" ]] && top="NA"
        echo "NA $top"
    else
        # Full exec.
        local raw
        raw=$(
            {
                variant_gucs "$v"
                echo "SET statement_timeout = ${STATEMENT_TIMEOUT_MS};"
                echo "EXPLAIN"
                echo "$body"
                echo ";"
                echo "\\timing on"
                echo "$body"
                echo ";"
            } | "$INSTDIR/psql" -p "$PGPORT" -d "$DB" -U "$PGUSER" -X -f /dev/stdin 2>&1
        )
        local top
        top=$(echo "$raw" | awk 'match($0, /cost=[0-9.]+\.\.[0-9.]+/) {
            c = substr($0, RSTART+5, RLENGTH-5); split(c, a, /\.\./); print a[2]; exit
        }')
        local ms
        ms=$(echo "$raw" | awk '/^Time: / {last=$2} END {if (last!="") print last}')
        [[ -z "$top" ]] && top="NA"
        [[ -z "$ms"  ]] && ms="NA"
        echo "$top $ms"
    fi
}

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
    echo "DB=$DB  ITERS=$ITERS_LOCAL  METRIC=$METRIC  VARIANTS=$VARIANTS"
    echo "QUERY_DIR=$QUERY_FILES  count=$total"
    echo "Output: $OUT_DIR"
} | tee "$LOG"

echo "query,n_rels,variant,iter,exec_ms,top_cost" > "$PER_Q"

declare -a Q_NAMES Q_NRELS
echo "[$(date +%H:%M:%S)] resolving n_rels..." | tee -a "$LOG"
for qf in "${queries[@]}"; do
    nm="$(basename "$qf" .sql)"
    nr="$(n_rels_for "$qf")"; [[ -z "$nr" ]] && nr=0
    Q_NAMES+=("$nm"); Q_NRELS+=("$nr")
done

# ---- main loop ----------------------------------------------------------
for v in $VARIANTS; do
    t0=$(date +%s)
    printf "[%s] === %s ===\n" "$(date +%H:%M:%S)" "$v" | tee -a "$LOG"
    for idx in "${!queries[@]}"; do
        qf="${queries[$idx]}"; nm="${Q_NAMES[$idx]}"; nr="${Q_NRELS[$idx]}"
        for i in $(seq 1 "$ITERS_LOCAL"); do
            read -r top ms <<<"$(run_once "$qf" "$v")"
            echo "$nm,$nr,$v,$i,$ms,$top" >> "$PER_Q"
        done
    done
    t1=$(date +%s)
    printf "  done in %ds\n" "$((t1-t0))" | tee -a "$LOG"
done

# ---- summary: per-variant deltas vs `best` (and vs `pg`) ----------------
echo "variant,n,geomean_ms,median_ms,total_s,wins_vs_best,losses_vs_best,geo_ratio_vs_best,geo_ratio_vs_pg" > "$SUMMARY"

awk -F, -v summary="$SUMMARY" -v metric="$METRIC" '
    function colidx() { return (metric=="cost" ? 6 : 5) }
    NR == 1 { next }
    {
        v_ = $3; q_ = $1
        val_str = $(metric=="cost" ? 6 : 5)
        if (val_str == "NA") next
        val = val_str + 0
        if (val <= 0) next
        cnt[v_, q_]++
        vals[v_, q_, cnt[v_, q_]] = val
        variants[v_] = 1
        queries_seen[q_] = 1
    }
    END {
        # median per (variant, query)
        for (k in cnt) {
            split(k, kk, SUBSEP); v_ = kk[1]; q_ = kk[2]
            n_ = cnt[k]
            for (i=1; i<=n_; i++) arr[i] = vals[v_, q_, i]
            for (i=2; i<=n_; i++) {
                vv = arr[i]; j = i-1
                while (j >= 1 && arr[j] > vv) { arr[j+1] = arr[j]; j-- }
                arr[j+1] = vv
            }
            med = (n_ % 2) ? arr[(n_+1)/2] : (arr[n_/2] + arr[n_/2+1])/2
            mq[v_, q_] = med
        }
        # Build baselines
        for (q_ in queries_seen) {
            if (("best", q_) in mq) best_med[q_] = mq["best", q_]
            if (("pg",   q_) in mq) pg_med[q_]   = mq["pg",   q_]
        }
        # Per-variant aggregates
        for (v_ in variants) {
            nq = 0; sumlog = 0; tot_ms = 0
            wb = lb = 0; sl_b = 0; nb = 0
            sl_p = 0; np = 0
            for (q_ in queries_seen) {
                if (!((v_, q_) in mq)) continue
                vv = mq[v_, q_]
                if (vv <= 0) continue
                nq++
                sumlog += log(vv)
                tot_ms += vv
                if (q_ in best_med && best_med[q_] > 0) {
                    r = vv / best_med[q_]
                    sl_b += log(r); nb++
                    if (r < 0.95) wb++
                    else if (r > 1.05) lb++
                }
                if (q_ in pg_med && pg_med[q_] > 0) {
                    r2 = vv / pg_med[q_]
                    sl_p += log(r2); np++
                }
            }
            if (nq == 0) continue
            gm = exp(sumlog / nq)
            gr_b = (nb > 0) ? sprintf("%.4f", exp(sl_b/nb)) : "NA"
            gr_p = (np > 0) ? sprintf("%.4f", exp(sl_p/np)) : "NA"
            # median of medians
            mc = 0
            for (q_ in queries_seen)
                if ((v_, q_) in mq) mc++
            i = 0
            for (q_ in queries_seen) if ((v_, q_) in mq) { i++; mlist[i] = mq[v_, q_] }
            for (i=2; i<=mc; i++) {
                vv = mlist[i]; j = i-1
                while (j >= 1 && mlist[j] > vv) { mlist[j+1] = mlist[j]; j-- }
                mlist[j+1] = vv
            }
            mmed = (mc % 2) ? mlist[(mc+1)/2] : (mlist[mc/2] + mlist[mc/2+1])/2
            delete mlist

            printf "%s,%d,%.2f,%.2f,%.2f,%d,%d,%s,%s\n",
                v_, nq, gm, mmed, tot_ms/1000.0, wb, lb, gr_b, gr_p >> summary
        }
    }
' "$PER_Q"

# Sort summary by geo_ratio_vs_best ASC (most-similar-to-best first)
{
    head -1 "$SUMMARY"
    tail -n +2 "$SUMMARY" | sort -t, -k8 -g
} > "$SUMMARY.sorted" && mv "$SUMMARY.sorted" "$SUMMARY"

{
    echo ""
    echo "=== Ablation summary ($METRIC) ==="
    column -s, -t "$SUMMARY"
    echo ""
    echo "Files:"
    echo "  per_query.csv -> $PER_Q"
    echo "  summary.csv   -> $SUMMARY"
    echo "  log.txt       -> $LOG"
    echo ""
    echo "Read order:"
    echo "  geo_ratio_vs_best -- closer to 1.00 = removing that feature didn't matter"
    echo "                     ratio > 1 means 'this variant is SLOWER than best'"
    echo "                     i.e. removing that feature *cost* you this much."
    echo "  geo_ratio_vs_pg   -- < 1 means still better than plain PG"
    echo "  wins/losses_vs_best -- how many of 113 queries got faster/slower"
} | tee -a "$LOG"

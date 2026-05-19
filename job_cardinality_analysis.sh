#!/bin/bash
# Phase B: Cardinality-error sensitivity analysis.
#
# Compares per-node cardinality predictions vs actual rows across the
# three join-search methods (pg / mcts) with AQO in `controlled` mode.
# All three see the SAME AQO predictions, so the experiment isolates:
#
#   - which queries still have high q-error after AQO training
#   - whether MCTS picks plans that are more / less sensitive to those
#     residual errors than PG-DP / GEQO does
#
# Mechanism:
#   We run each query with `EXPLAIN (ANALYZE, BUFFERS, VERBOSE)` so PG
#   prints `(actual rows=N width=W loops=L)` for each plan node next
#   to `cost=A..B rows=R width=W` (predicted).  We parse both and
#   compute per-node q-error = max(actual, predicted) / max(min(actual,
#   predicted), 1).  Per query we record the WORST node q-error and
#   the geomean across nodes.
#
# Prerequisites:
#   - AQO trained (run aqo_train.sh and aqo_train.sh --with-mcts --no-reset)
#   - Run only with small set of queries first — EXPLAIN ANALYZE is slow.
#
# Output:
#   $RESULTS_DIR/cardinality/<run-id>/per_query.csv
#     query,n_rels,config,iter,n_nodes,max_qerror,geomean_qerror,exec_ms,total_cost
#   $RESULTS_DIR/cardinality/<run-id>/per_node.csv
#     query,n_rels,config,iter,node_kind,relation,est_rows,actual_rows,qerror
#   $RESULTS_DIR/cardinality/<run-id>/summary.csv
#     config,n_queries,geomean_max_qerror,median_max_qerror,
#            geomean_exec_ms,total_s
#
# Usage:
#   ./job_cardinality_analysis.sh [database] [iters] [configs]
#     configs: any subset of {pg mcts pg_aqo mcts_aqo}
#     defaults: imdb, 1 iter (EXPLAIN ANALYZE expensive), pg mcts pg_aqo mcts_aqo

set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

DB="${1:-imdb}"
ITERS_LOCAL="${2:-1}"
CONFIGS="${3:-pg mcts pg_aqo mcts_aqo}"

export PGDATABASE="$DB"
PSQL="$INSTDIR/psql -p $PGPORT -d $DB -U $PGUSER -X -q"

RUN_ID="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="$RESULTS_DIR/cardinality/$RUN_ID"
mkdir -p "$OUT_DIR"
PER_Q="$OUT_DIR/per_query.csv"
PER_N="$OUT_DIR/per_node.csv"
SUMMARY="$OUT_DIR/summary.csv"
LOG="$OUT_DIR/log.txt"

pg_ensure_up

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

cfg_gucs() {
    local cfg="$1"
    case "$cfg" in
        pg)        echo "$AQO_OFF";        echo "$PG_NATURAL" ;;
        mcts)      echo "$AQO_OFF";        echo "$PG_NATURAL"; echo "$MCTS_BLOCK" ;;
        pg_aqo)    echo "$AQO_CONTROLLED"; echo "$PG_NATURAL" ;;
        mcts_aqo)  echo "$AQO_CONTROLLED"; echo "$PG_NATURAL"; echo "$MCTS_BLOCK" ;;
        *)         echo "Unknown config: $cfg" >&2; return 1 ;;
    esac
    echo "SET statement_timeout = ${STATEMENT_TIMEOUT_MS};"
}

# Get n_rels via a cheap MCTS probe
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

# Run EXPLAIN (ANALYZE, VERBOSE, BUFFERS) for one query, parse:
#  - per-node (est_rows, actual_rows) → q-error
#  - top-level cost
#  - actual exec time from "Execution Time:" line
# Appends per-node rows to PER_N and emits one summary line.
analyze_one() {
    local qf="$1" cfg="$2" iter="$3" qname="$4" nrels="$5"
    local raw
    raw=$(
        {
            cfg_gucs "$cfg"
            echo "EXPLAIN (ANALYZE, VERBOSE, BUFFERS)"
            sed 's/;[[:space:]]*$//' "$qf"
            echo ";"
        } | "$INSTDIR/psql" -p "$PGPORT" -d "$DB" -U "$PGUSER" -X -f /dev/stdin 2>&1
    )

    # Top-level cost from first cost= line
    local top_cost
    top_cost=$(echo "$raw" | awk 'match($0, /cost=[0-9.]+\.\.[0-9.]+/) {
        c = substr($0, RSTART+5, RLENGTH-5); split(c, a, /\.\./); print a[2]; exit
    }')
    # Execution time
    local exec_ms
    exec_ms=$(echo "$raw" | awk '/Execution Time: / {gsub(",",""); print $3; exit}')
    [[ -z "$top_cost" ]] && top_cost="NA"
    [[ -z "$exec_ms"  ]] && exec_ms="NA"

    # Parse per-node estimates.  Robust to:
    #   - InitPlan/SubPlan/Result lines without proper rows=
    #   - never-executed branches (loops=0 → actual missing or zero)
    #   - nodes where prediction is unavailable: PG falls back to a sentinel
    #     ("rows=1" default), which gives meaningless q-error; we still log
    #     them but mark as suspicious and exclude from aggregates.
    #
    # For each kept node we write: query, n_rels, config, iter, node_kind,
    # relation, est_rows, actual_rows, qerror (or NA).
    echo "$raw" | awk -v cfg="$cfg" -v iter="$iter" -v q="$qname" -v nr="$nrels" -v out="$PER_N" '
        function emit(kind, est, act, qerr) {
            gsub(",", " ", kind)
            printf "%s,%s,%s,%s,\"%s\",,%s,%s,%s\n",
                q, nr, cfg, iter, kind,
                (est == "NA" ? "NA" : sprintf("%d", est)),
                (act == "NA" ? "NA" : sprintf("%d", act)),
                (qerr == "NA" ? "NA" : sprintf("%.4f", qerr)) >> out
        }
        # Plan-node line has: cost=A..B rows=R width=W ...  (no "actual" yet
        # = EXPLAIN without ANALYZE — skip).  With ANALYZE, both present.
        match($0, /cost=[0-9.]+\.\.[0-9.]+ rows=[0-9]+/) {
            cost_seg = substr($0, RSTART, RLENGTH)
            est = "NA"
            if (match(cost_seg, /rows=[0-9]+/))
                est = substr(cost_seg, RSTART+5, RLENGTH-5) + 0

            # actual part may be absent on "(never executed)" lines
            act = "NA"; loops = 0; never_executed = 0
            if (match($0, /never executed/)) {
                never_executed = 1
            } else if (match($0, /\(actual [^)]*rows=[0-9]+[^)]*loops=[0-9]+/)) {
                seg = substr($0, RSTART, RLENGTH)
                if (match(seg, /rows=[0-9]+/))
                    raw_rows = substr(seg, RSTART+5, RLENGTH-5) + 0
                if (match(seg, /loops=[0-9]+/))
                    loops = substr(seg, RSTART+6, RLENGTH-6) + 0
                if (loops > 0)
                    act = raw_rows * loops
            }

            # Node-kind label: strip indent and "->"
            kind = $0
            sub(/^[[:space:]]*->\s*/, "", kind)
            sub(/^[[:space:]]+/, "", kind)
            sub(/  \(cost.*/, "", kind)

            # Cases:
            #  - never_executed:   record as NA, exclude from aggregates
            #  - act == NA:         malformed line, skip entirely
            #  - est = 0 OR act = 0 with the other > 0: bounded by minimum 1
            #  - est == act == 0:   not useful, skip
            if (never_executed) {
                emit(kind, est, "NA", "NA"); next
            }
            if (act == "NA" || est == "NA") next
            if (est == 0 && act == 0) next

            mn = (est < act ? est : act); if (mn < 1) mn = 1
            mx = (est > act ? est : act); if (mx < 1) mx = 1
            qerr = mx / mn

            emit(kind, est, act, qerr)

            n_nodes++
            sumlog += log(qerr)
            if (qerr > max_qerr) max_qerr = qerr
        }
        END {
            if (n_nodes == 0) { print "0 NA NA"; exit }
            gm = exp(sumlog / n_nodes)
            printf "%d %.4f %.4f\n", n_nodes, max_qerr, gm
        }
    ' >> /tmp/cardinality_summary.$$

    read -r n_nodes max_qe geo_qe < /tmp/cardinality_summary.$$
    rm -f /tmp/cardinality_summary.$$

    [[ -z "$n_nodes" ]] && n_nodes="0"
    [[ -z "$max_qe"  ]] && max_qe="NA"
    [[ -z "$geo_qe"  ]] && geo_qe="NA"

    echo "$qname,$nrels,$cfg,$iter,$n_nodes,$max_qe,$geo_qe,$exec_ms,$top_cost" >> "$PER_Q"
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

echo "query,n_rels,config,iter,n_nodes,max_qerror,geomean_qerror,exec_ms,top_cost" > "$PER_Q"
echo "query,n_rels,config,iter,node_kind,relation,est_rows,actual_rows,qerror" > "$PER_N"

# Cache n_rels
declare -a Q_NAMES Q_NRELS
echo "[$(date +%H:%M:%S)] resolving n_rels for $total queries..." | tee -a "$LOG"
for qf in "${queries[@]}"; do
    name="$(basename "$qf" .sql)"
    nr=$(n_rels_for "$qf"); [[ -z "$nr" ]] && nr=0
    Q_NAMES+=("$name"); Q_NRELS+=("$nr")
done

for cfg in $CONFIGS; do
    t0=$(date +%s)
    printf "[%s] === %s ===\n" "$(date +%H:%M:%S)" "$cfg" | tee -a "$LOG"
    for idx in "${!queries[@]}"; do
        qf="${queries[$idx]}"
        for i in $(seq 1 "$ITERS_LOCAL"); do
            analyze_one "$qf" "$cfg" "$i" "${Q_NAMES[$idx]}" "${Q_NRELS[$idx]}" \
                2>/dev/null || true
        done
    done
    t1=$(date +%s)
    printf "  done in %ds\n" "$((t1-t0))" | tee -a "$LOG"
done

# ---- per-config summary -------------------------------------------------
echo "config,n_queries,geomean_max_qerror,median_max_qerror,geomean_geomean_qerror,geomean_exec_ms,total_s" > "$SUMMARY"

awk -F, -v out="$SUMMARY" '
    NR==1 { next }
    $6 == "NA" || $8 == "NA" { next }
    {
        cfg = $3
        mq = $6 + 0; gq = $7 + 0; ms = $8 + 0
        if (mq <= 0 || ms <= 0) next
        n[cfg]++
        slog_mq[cfg] += log(mq)
        slog_gq[cfg] += log(gq)
        slog_ms[cfg] += log(ms)
        tot_ms[cfg] += ms
        list_mq[cfg, n[cfg]] = mq
    }
    END {
        for (cfg in n) {
            cnt = n[cfg]
            # median of max_qerror
            for (i=1; i<=cnt; i++) arr[i] = list_mq[cfg, i]
            for (i=2; i<=cnt; i++) {
                v = arr[i]; j = i-1
                while (j>=1 && arr[j] > v) { arr[j+1] = arr[j]; j-- }
                arr[j+1] = v
            }
            med = (cnt % 2) ? arr[(cnt+1)/2] : (arr[cnt/2] + arr[cnt/2+1]) / 2
            printf "%s,%d,%.4f,%.4f,%.4f,%.4f,%.2f\n",
                cfg, cnt,
                exp(slog_mq[cfg]/cnt), med,
                exp(slog_gq[cfg]/cnt),
                exp(slog_ms[cfg]/cnt),
                tot_ms[cfg]/1000.0 >> out
        }
    }
' "$PER_Q"

{
    echo ""
    echo "=== Summary (cardinality q-error vs exec time, by method) ==="
    column -s, -t "$SUMMARY"
    echo ""
    echo "Files:"
    echo "  per_query.csv -> $PER_Q"
    echo "  per_node.csv  -> $PER_N"
    echo "  summary.csv   -> $SUMMARY"
    echo "  log.txt       -> $LOG"
    echo ""
    echo "Interpretation:"
    echo "  max_qerror             -- worst-node prediction error in the chosen plan"
    echo "  geomean_geomean_qerror -- typical error per node, geomean over queries"
    echo "  geomean_exec_ms        -- actual exec time"
    echo "  If 'mcts' has higher max_qerror but similar/lower geomean_exec_ms than 'pg',"
    echo "  then MCTS picks plans more robust to cardinality misestimation."
    echo "  If '*_aqo' has lower max_qerror than '*' but exec time doesn't drop,"
    echo "  AQO is fixing predictions but plans aren't different enough to matter."
} | tee -a "$LOG"

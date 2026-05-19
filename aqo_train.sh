#!/bin/bash
# Train AQO on the JOB benchmark over N iterations (default 30).
#
# Workflow:
#   1. Optionally reset AQO state (aqo_reset()) for a fresh start.
#   2. For each iteration in 1..N:
#        - Run all queries from $QUERY_FILES under aqo.mode='learn'.
#        - Record per-query exec time (\timing).
#   3. Emit a wide CSV with one row per query and one column per iter,
#      plus a summary CSV with the geomean and # learned-queries per iter.
#
# AQO learns from the previous execution: iter 1 plans with PG's stock
# cardinality estimates and feeds back the observed row counts; iter 2
# uses the corrected estimates, and so on.  The learning curve usually
# converges within 5-10 iterations on JOB.
#
# Prerequisites:
#   - shared_preload_libraries = 'aqo' in postgresql.conf
#   - CREATE EXTENSION aqo (in the target database)
#   - PG built with the AQO core hooks patch (see contrib/aqo/aqo_master.patch)
#
# Usage:
#   ./aqo_train.sh [database] [iters] [--mode=learn|forced|intelligent]
#                  [--no-reset] [--with-mcts] [--queries=path]
#                  [--statement-timeout=ms]
#
# Defaults: database=imdb, iters=30, mode=learn, reset state, no MCTS.
#
# Outputs (RESULTS_DIR/aqo_train/<run-id>/):
#   per_query.csv    -- query, n_iter1_ms, n_iter2_ms, ..., n_iterN_ms
#   summary.csv      -- iter, geomean_ms, median_ms, total_s, n_queries,
#                       n_aqo_queries_known
#   log.txt          -- per-iter status messages

set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

# ---- arg parsing --------------------------------------------------------
DB="imdb"
ITERS_LOCAL=30
MODE="learn"
DO_RESET=1
WITH_MCTS=0
QUERIES_DIR="$QUERY_FILES"
STMT_TIMEOUT="${STATEMENT_TIMEOUT_MS:-600000}"

POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --mode=*)              MODE="${arg#--mode=}" ;;
        --no-reset)            DO_RESET=0 ;;
        --with-mcts)           WITH_MCTS=1 ;;
        --queries=*)           QUERIES_DIR="${arg#--queries=}" ;;
        --statement-timeout=*) STMT_TIMEOUT="${arg#--statement-timeout=}" ;;
        --*)                   echo "Unknown flag: $arg" >&2; exit 2 ;;
        *)                     POSITIONAL+=("$arg") ;;
    esac
done
[[ ${#POSITIONAL[@]} -ge 1 ]] && DB="${POSITIONAL[0]}"
[[ ${#POSITIONAL[@]} -ge 2 ]] && ITERS_LOCAL="${POSITIONAL[1]}"

case "$MODE" in
    learn|forced|intelligent) ;;
    *) echo "mode must be learn|forced|intelligent, got '$MODE'" >&2; exit 2 ;;
esac

export PGDATABASE="$DB"
PSQL="$INSTDIR/psql -p $PGPORT -d $DB -U $PGUSER -X -q"

# ---- output paths -------------------------------------------------------
RUN_ID="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="$RESULTS_DIR/aqo_train/$RUN_ID"
mkdir -p "$OUT_DIR"
PER_Q="$OUT_DIR/per_query.csv"
SUMMARY="$OUT_DIR/summary.csv"
LOG="$OUT_DIR/log.txt"

# ---- preflight ----------------------------------------------------------
pg_ensure_up

# Verify AQO is present + extension installed.
have_aqo=$($PSQL -tA -c "SELECT 1 FROM pg_extension WHERE extname='aqo'" 2>/dev/null || echo "")
if [[ -z "$have_aqo" ]]; then
    echo "FATAL: aqo extension not installed in database $DB" >&2
    echo "Hint: run 'CREATE EXTENSION aqo;' (and ensure shared_preload_libraries=aqo)" >&2
    exit 1
fi

queries=( "$QUERIES_DIR"/*.sql )
total_queries=${#queries[@]}
if [[ "$total_queries" -eq 0 ]]; then
    echo "FATAL: no queries found in $QUERIES_DIR" >&2; exit 1
fi

# ---- header dump --------------------------------------------------------
{
    echo "RUN_ID=$RUN_ID"
    echo "DB=$DB  ITERS=$ITERS_LOCAL  MODE=$MODE  WITH_MCTS=$WITH_MCTS  RESET=$DO_RESET"
    echo "QUERIES_DIR=$QUERIES_DIR  count=$total_queries"
    echo "STMT_TIMEOUT_MS=$STMT_TIMEOUT"
    echo "Output: $OUT_DIR"
} | tee "$LOG"

# Reset AQO state (clean training slate).
if [[ "$DO_RESET" -eq 1 ]]; then
    echo "Resetting AQO state via aqo_reset()..." | tee -a "$LOG"
    $PSQL -c "SELECT count(*) FROM aqo_reset();" 2>&1 | tee -a "$LOG" || true
fi

# CSV header for per-query: query,iter1_ms,iter2_ms,...,iterN_ms
{
    printf "query"
    for i in $(seq 1 "$ITERS_LOCAL"); do printf ",iter%d_ms" "$i"; done
    printf "\n"
} > "$PER_Q"

echo "iter,geomean_ms,median_ms,total_s,n_queries,n_aqo_queries_known,avg_qerror_with_aqo,max_qerror_with_aqo,avg_qerror_without_aqo" > "$SUMMARY"

# Read AQO cardinality-error stats from aqo_query_stat.
# Returns: avg_with_aqo max_with_aqo avg_without_aqo  (space-separated, NA if empty)
read_qerror() {
    $PSQL -tA -F' ' -c "
        SELECT
            COALESCE(round(avg(cw)::numeric, 4)::text, 'NA'),
            COALESCE(round(max(cw)::numeric, 4)::text, 'NA'),
            COALESCE(round(avg(co)::numeric, 4)::text, 'NA')
        FROM (
            SELECT
                CASE WHEN cardinality(cardinality_error_with_aqo) > 0
                     THEN cardinality_error_with_aqo[array_upper(cardinality_error_with_aqo, 1)]
                     ELSE NULL END AS cw,
                CASE WHEN cardinality(cardinality_error_without_aqo) > 0
                     THEN cardinality_error_without_aqo[array_upper(cardinality_error_without_aqo, 1)]
                     ELSE NULL END AS co
            FROM aqo_query_stat
        ) s
    " 2>/dev/null || echo "NA NA NA"
}

# ---- per-iteration helpers ---------------------------------------------

# emit the GUC block applied at the start of each query session
gucs_block() {
    cat <<EOF
LOAD 'aqo';
SET aqo.mode = '$MODE';
SET aqo.force_collect_stat = on;
SET aqo.show_details = on;
SET aqo.show_hash = on;
SET statement_timeout = ${STMT_TIMEOUT};
EOF
    if [[ "$WITH_MCTS" -eq 1 ]]; then
        # MCTS substrate: matches job_compare_methods.sh `mcts` config.
        # min_relations=2 => MCTS runs on EVERY query so AQO sees the full
        # set of MCTS-shaped Plan nodes during training.
        cat <<'EOF'
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
    fi
}

# run one query once, echo elapsed ms; empty string on failure / timeout
# (the caller maps empty → "NA").  awk prints exactly ONE line on a match
# and prints nothing otherwise — no spurious second NA line.
exec_one_ms() {
    local qf="$1"
    "$INSTDIR/psql" -p "$PGPORT" -d "$DB" -U "$PGUSER" -X -f /dev/stdin 2>&1 <<EOF \
      | awk '/^Time: / {print $2; exit}'
$(gucs_block)
\timing on
$(sed 's/;[[:space:]]*$//' "$qf");
EOF
}

# geomean of a list of numbers on stdin (NA / empty / non-positive ignored)
geomean() {
    awk '
        BEGIN { n = 0; logsum = 0 }
        /^NA$/ || NF == 0 { next }
        ($1 + 0) > 0 { logsum += log($1); n++ }
        END { if (n > 0) printf "%.4f\n", exp(logsum/n); else print "NA" }'
}

# median of a list of numbers on stdin (NA ignored)
median() {
    awk '
        BEGIN { n = 0 }
        /^NA$/ || NF == 0 { next }
        ($1 + 0) > 0 { vals[++n] = $1 }
        END {
            if (n == 0) { print "NA"; exit }
            asort(vals)
            if (n % 2) printf "%.4f\n", vals[(n+1)/2]
            else       printf "%.4f\n", (vals[n/2] + vals[n/2+1]) / 2
        }'
}

# ---- training loop ------------------------------------------------------
# Build arrays of per-query times across iters.  Bash 3.2 compat: use
# parallel index arrays keyed by query basename.
declare -a QNAMES
for qf in "${queries[@]}"; do QNAMES+=("$(basename "$qf" .sql)"); done

# Each iter writes its column to a temp file; we paste them at the end.
ITER_FILES=()
for iter in $(seq 1 "$ITERS_LOCAL"); do
    iter_file=$(mktemp /tmp/aqo_iter_XXXXXX)
    ITER_FILES+=("$iter_file")
    iter_t_start=$(date +%s)
    printf "[%s] iter=%d/%d ...\n" "$(date +%H:%M:%S)" "$iter" "$ITERS_LOCAL" | tee -a "$LOG"
    : > "$iter_file"
    for qf in "${queries[@]}"; do
        ms=$(exec_one_ms "$qf")
        [[ -z "$ms" ]] && ms="NA"
        echo "$ms" >> "$iter_file"
    done
    iter_t_end=$(date +%s)

    geo=$(cat "$iter_file" | geomean)
    med=$(cat "$iter_file" | median)
    tot=$(awk 'BEGIN{s=0} /^NA$/||NF==0{next} {s+=$1} END {printf "%.3f", s/1000.0}' "$iter_file")
    # number of queries AQO has learned so far (rows in aqo_queries)
    n_known=$($PSQL -tA -c "SELECT count(*) FROM aqo_queries" 2>/dev/null || echo "NA")
    # cardinality q-error (latest sample in aqo_query_stat per query, averaged)
    read avg_qe_w max_qe_w avg_qe_wo <<<"$(read_qerror)"
    avg_qe_w="${avg_qe_w:-NA}"; max_qe_w="${max_qe_w:-NA}"; avg_qe_wo="${avg_qe_wo:-NA}"

    echo "$iter,$geo,$med,$tot,$total_queries,$n_known,$avg_qe_w,$max_qe_w,$avg_qe_wo" >> "$SUMMARY"
    printf "  geomean=%s ms  median=%s ms  total=%s s  learned=%s  qerror_avg=%s(was %s)  qerror_max=%s  (%ds)\n" \
        "$geo" "$med" "$tot" "$n_known" "$avg_qe_w" "$avg_qe_wo" "$max_qe_w" "$((iter_t_end - iter_t_start))" | tee -a "$LOG"
done

# ---- paste columns into per_query.csv ----------------------------------
# Each iter wrote 113 lines of ms; paste them side-by-side as columns.
{
    printf "query"
    for i in $(seq 1 "$ITERS_LOCAL"); do printf ",iter%d_ms" "$i"; done
    printf "\n"
    paste <(printf "%s\n" "${QNAMES[@]}") "${ITER_FILES[@]}" | tr '\t' ','
} > "$PER_Q" || echo "WARN: per_query.csv assembly failed; iter files left in /tmp/aqo_iter_*"

# Cleanup only on success
if [[ -s "$PER_Q" ]]; then
    rm -f "${ITER_FILES[@]}"
else
    echo "Keeping iter files (paste failed): ${ITER_FILES[@]}" >&2
fi

# ---- final summary ------------------------------------------------------
{
    echo ""
    echo "=== AQO training done ==="
    echo "  per_query.csv -> $PER_Q"
    echo "  summary.csv   -> $SUMMARY"
    echo "  log.txt       -> $LOG"
    echo ""
    echo "Convergence (geomean ms and avg q-error per iter):"
    awk -F, < "$SUMMARY" '
        NR>1 { printf "  iter %3d: geo=%-10s ms  total=%-7s s  learned=%-4s  qerror_avg=%-10s\n",
                      $1, $2, $4, $6, $7 }'
    echo ""
    echo "Q-error trend (avg cardinality-error in latest sample, with AQO):"
    awk -F, < "$SUMMARY" 'NR>1 && $7 != "NA" { printf "  iter %3d: %s\n", $1, $7 }'
} | tee -a "$LOG"

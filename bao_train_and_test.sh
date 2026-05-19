#!/bin/bash
# Train Bao online on JOB queries (rewards=on), then a clean test pass.
# Bao retrains its Tree-CNN model every 25 queries (its built-in sliding window).
# Writes per-query timings to min_job/results/bao_job.csv.

set -uo pipefail

INSTDIR=/Users/alena/my_postgres9/my/inst/bin
PORT=5499
DB=imdb
QUERIES_DIR=/Users/alena/source/queries
OUT_CSV=/Users/alena/my_postgres9/min_job/results/bao_job.csv
LOG=/tmp/bao_psql.log
EPOCHS=${EPOCHS:-2}
PHASE_TEST_ITERS=${PHASE_TEST_ITERS:-1}

mkdir -p "$(dirname "$OUT_CSV")"
: > "$LOG"

run_query_with_bao() {
    local qf="$1"
    {
        echo "LOAD 'pg_bao';"
        echo "SET max_parallel_workers_per_gather = 0;"
        echo "SET enable_bao = on;"
        echo "SET enable_bao_rewards = on;"
        echo "SET bao_host = '127.0.0.1';"
        echo "SET bao_port = 9381;"
        echo "SET statement_timeout = 600000;"
        echo "\\timing on"
        sed 's/;[[:space:]]*$//' "$qf"
        echo ";"
    } | "$INSTDIR/psql" -p "$PORT" -d "$DB" -U "$(whoami)" -X -q -f - 2>>"$LOG" \
        | awk '/^Time: / { print $2; exit }'
}

echo "=== TRAINING: $EPOCHS epoch(s) over 113 JOB queries ==="
for epoch in $(seq 1 "$EPOCHS"); do
    i=0
    for qf in "$QUERIES_DIR"/*.sql; do
        i=$((i + 1))
        name=$(basename "$qf" .sql)
        ms=$(run_query_with_bao "$qf")
        printf "train epoch=%d  [%3d/113] %-6s  %s ms\n" "$epoch" "$i" "$name" "${ms:-NA}"
    done
done

echo "=== TEST: $PHASE_TEST_ITERS iter per query ==="
echo "query,iter,exec_ms" > "$OUT_CSV"
for iter in $(seq 1 "$PHASE_TEST_ITERS"); do
    i=0
    for qf in "$QUERIES_DIR"/*.sql; do
        i=$((i + 1))
        name=$(basename "$qf" .sql)
        ms=$(run_query_with_bao "$qf")
        printf "test iter=%d  [%3d/113] %-6s  %s ms\n" "$iter" "$i" "$name" "${ms:-NA}"
        echo "$name,$iter,${ms:-NA}" >> "$OUT_CSV"
    done
done

echo "Done. Results: $OUT_CSV"

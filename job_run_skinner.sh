#!/bin/bash
# Run JOB through SkinnerDB (Trummer et al., SIGMOD 2019).
#
# SkinnerDB is a stand-alone Java DBMS — it does NOT use PostgreSQL.
# Repo: https://github.com/cornelldbgroup/skinnerdb
#
# Setup (one-time):
#   git clone https://github.com/cornelldbgroup/skinnerdb ~/SkinnerDB
#   cd ~/SkinnerDB && mvn package
#   # Load IMDb into SkinnerDB's local store (custom loader):
#   java -jar target/skinnerdb-*.jar --load /Users/alena/source/csv
#   # SkinnerDB has no port; queries go via the CLI or REST harness.
#
# This script runs each JOB query through SkinnerDB's CLI and parses its
# self-reported timing (SkinnerDB does not support pg_hint_plan or PG's \timing).

set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

SKINNER_HOME="${SKINNER_HOME:-$HOME/SkinnerDB}"
SKINNER_JAR="${SKINNER_JAR:-$SKINNER_HOME/target/skinnerdb-1.0-SNAPSHOT-jar-with-dependencies.jar}"
SKINNER_DB="${SKINNER_DB:-$SKINNER_HOME/db/imdb}"
ITERS="${1:-$ITERS}"
METHOD="skinner"

mkdir -p "$PLANS_DIR/$METHOD" "$RESULTS_DIR" "$LOG_DIR"
OUT_CSV="$RESULTS_DIR/${METHOD}_job.csv"
csv_header > "$OUT_CSV"

if [ ! -f "$SKINNER_JAR" ]; then
    echo "ERROR: $SKINNER_JAR not found. Build SkinnerDB with 'mvn package' first." >&2
    exit 1
fi

skinner_run_once() {
    local qf="$1"
    # SkinnerDB reads SQL from stdin; reports "Query took XXX ms"
    {
        echo "SET TIMEOUT ${STATEMENT_TIMEOUT_MS};"
        cat "$qf"
        echo "QUIT;"
    } | java -jar "$SKINNER_JAR" --db "$SKINNER_DB" 2>/dev/null \
        | awk '/Query took/ { print $3; exit }'
}

skinner_save_explain() {
    local qf="$1" name plan_file
    name="$(basename "$qf" .sql)"
    plan_file="$PLANS_DIR/$METHOD/${name}.plan"
    # SkinnerDB's EXPLAIN equivalent
    {
        echo "EXPLAIN"
        cat "$qf"
        echo "QUIT;"
    } | java -jar "$SKINNER_JAR" --db "$SKINNER_DB" > "$plan_file" 2>&1
}

queries=("$QUERY_FILES"/*.sql)
total=${#queries[@]}
for idx in "${!queries[@]}"; do
    qf="${queries[$idx]}"
    name="$(basename "$qf" .sql)"
    n=$((idx + 1))
    echo "[$n/$total] $name"

    skinner_save_explain "$qf"
    for i in $(seq 1 "$ITERS"); do
        ms=$(skinner_run_once "$qf")
        echo "$name,$i,${ms:-NA}" >> "$OUT_CSV"
    done
done

echo "Plans -> $PLANS_DIR/$METHOD"
echo "Times -> $OUT_CSV"

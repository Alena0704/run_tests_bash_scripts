#!/bin/bash
# Compare planning + execution time of vanilla PostgreSQL and the SAIO
# join-order search extension on JOB queries that have *more than 11*
# base relations in their FROM clause.
#
# Two configs are exercised:
#   pg     : default planner (geqo=on, geqo_threshold=12 — so n_rels>11 ⇒ GEQO).
#   saio   : LOAD 'saio'; SET saio = on;
#
# For each (cfg, query, iter):
#   * EXPLAIN (ANALYZE, TIMING ON) is executed.
#   * "Planning Time" and "Execution Time" are extracted from the output.
#
# Outputs (under $RESULTS_DIR/compare_saio/<run-id>/):
#   per_query.csv : query,n_rels,config,iter,planning_ms,exec_ms,top_cost
#   summary.csv   : per-config / per-query medians and pg-vs-saio ratios
#   plans/<cfg>/<q>.plan : EXPLAIN of first iter for inspection
#   log.txt       : run log
#
# Usage: ./job_run_saio_vs_pg.sh [database] [iters] [min_rels]
#   defaults: imdb, 3 iters, min_rels=12 (i.e. relations > 11)

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
SUMMARY="$OUT_DIR/summary.csv"
LOG="$OUT_DIR/log.txt"

pg_ensure_up

# ---- per-config GUC blocks ---------------------------------------------
PG_BLOCK=$(cat <<'EOF'
SET geqo = on;
SET geqo_threshold = 12;
SET from_collapse_limit = 100;
SET join_collapse_limit = 100;
EOF
)

SAIO_BLOCK=$(cat <<'EOF'
LOAD 'saio';
SET saio = on;
SET geqo = off;                 -- saio takes over the hook
SET from_collapse_limit = 100;
SET join_collapse_limit = 100;
EOF
)

cfg_gucs() {
    local cfg="$1"
    case "$cfg" in
        pg)   echo "$PG_BLOCK" ;;
        saio) echo "$SAIO_BLOCK" ;;
        *)    echo "Unknown config: $cfg" >&2; return 1 ;;
    esac
    echo "SET statement_timeout = ${STATEMENT_TIMEOUT_MS};"
}

# Count base relations in the FROM clause of a JOB query (parse-only — does
# not require touching the server).  JOB queries write "FROM t1 AS a, t2 AS
# b, ..." on one or several lines, terminated by WHERE.  We collapse the
# FROM region into a single line and count commas + 1.
n_rels_for() {
    local qf="$1"
    awk '
        BEGIN { in_from = 0; from_buf = "" }
        /^[[:space:]]*FROM([[:space:]]|$)/ { in_from = 1 }
        in_from {
            sub(/^[[:space:]]*FROM[[:space:]]+/, "")
            if (match($0, /^[[:space:]]*WHERE([[:space:]]|$)/)) {
                in_from = 0
                exit
            }
            from_buf = from_buf " " $0
        }
        END {
            # split off WHERE if it appeared on a FROM line
            sub(/[[:space:]]+WHERE[[:space:]].*/, "", from_buf)
            n = split(from_buf, _, ",")
            print n
        }
    ' "$qf"
}

# Run query once for a given config.  Echoes "<top_cost> <planning_ms> <exec_ms>".
# Any missing field becomes "NA".  EXPLAIN (ANALYZE) gives us both numbers.
run_once() {
    local qf="$1" cfg="$2"
    local body
    body=$(sed 's/;[[:space:]]*$//' "$qf")
    local raw
    raw=$(
        {
            cfg_gucs "$cfg"
            echo "EXPLAIN (ANALYZE, TIMING ON, BUFFERS OFF)"
            echo "$body"
            echo ";"
        } | "$INSTDIR/psql" -p "$PGPORT" -d "$DB" -U "$PGUSER" -X -f /dev/stdin 2>&1
    )

    local top planning exec
    top=$(echo "$raw" | awk 'match($0, /cost=[0-9.]+\.\.[0-9.]+/) {
        c = substr($0, RSTART+5, RLENGTH-5); split(c, a, /\.\./); print a[2]; exit
    }')
    planning=$(echo "$raw" | awk '/Planning Time:/ { print $3; exit }')
    exec=$(echo "$raw" | awk '/Execution Time:/ { print $3; exit }')
    [[ -z "$top" ]]      && top="NA"
    [[ -z "$planning" ]] && planning="NA"
    [[ -z "$exec" ]]     && exec="NA"

    # Save the first EXPLAIN per (cfg, query) for inspection.
    local qname plan_dir plan_file
    qname="$(basename "$qf" .sql)"
    plan_dir="$OUT_DIR/plans/$cfg"
    plan_file="$plan_dir/${qname}.plan"
    if [[ ! -f "$plan_file" ]]; then
        mkdir -p "$plan_dir"
        echo "$raw" | awk '
            /QUERY PLAN/ {keep=1}
            keep {
                print
                if (/\([0-9]+ rows?\)/) { keep=0; exit }
            }
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

# Pre-compute n_rels and filter.
declare -a SEL_QF SEL_NAME SEL_NRELS
for qf in "${queries[@]}"; do
    name="$(basename "$qf" .sql)"
    nr=$(n_rels_for "$qf")
    [[ -z "$nr" || "$nr" -lt "$MIN_RELS" ]] && continue
    SEL_QF+=("$qf"); SEL_NAME+=("$name"); SEL_NRELS+=("$nr")
done
sel_total=${#SEL_QF[@]}
echo "Selected $sel_total queries with n_rels >= $MIN_RELS" | tee -a "$LOG"
if (( sel_total == 0 )); then
    echo "No queries match the relation filter." | tee -a "$LOG"
    exit 0
fi

echo "query,n_rels,config,iter,planning_ms,exec_ms,top_cost" > "$PER_Q"

for cfg in pg saio; do
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

# ---- summary -----------------------------------------------------------
# For each (query, config) take the median planning_ms and exec_ms.
# Emit a wide CSV: query, n_rels, pg_plan, saio_plan, plan_ratio,
#                          pg_exec, saio_exec, exec_ratio.
awk -F, '
    function med(arr, n,    a, i) {
        for (i = 1; i <= n; i++) a[i] = arr[i]
        # simple insertion sort
        for (i = 2; i <= n; i++) {
            v = a[i]; j = i - 1
            while (j >= 1 && a[j] > v) { a[j+1] = a[j]; j-- }
            a[j+1] = v
        }
        if (n % 2) return a[(n+1)/2]
        return (a[n/2] + a[n/2+1]) / 2.0
    }
    NR == 1 { next }
    {
        q = $1; nr = $2; cfg = $3; p = $5; e = $6
        nrels[q] = nr
        if (p != "NA") { kP = q "|" cfg; cntP[kP]++; arrP[kP, cntP[kP]] = p+0 }
        if (e != "NA") { kE = q "|" cfg; cntE[kE]++; arrE[kE, cntE[kE]] = e+0 }
        seen[q] = 1
    }
    END {
        print "query,n_rels,pg_plan_ms,saio_plan_ms,plan_ratio,pg_exec_ms,saio_exec_ms,exec_ratio,saio_total_speedup"
        for (q in seen) {
            split("", aP); split("", aS); split("", aPe); split("", aSe)
            nP = cntP[q "|pg"];   for (i=1;i<=nP;i++) aP[i]  = arrP[q "|pg",  i]
            nS = cntP[q "|saio"]; for (i=1;i<=nS;i++) aS[i]  = arrP[q "|saio",i]
            nPe = cntE[q "|pg"];   for (i=1;i<=nPe;i++) aPe[i] = arrE[q "|pg",  i]
            nSe = cntE[q "|saio"]; for (i=1;i<=nSe;i++) aSe[i] = arrE[q "|saio",i]
            pgP   = (nP  > 0) ? med(aP,  nP)  : -1
            saioP = (nS  > 0) ? med(aS,  nS)  : -1
            pgE   = (nPe > 0) ? med(aPe, nPe) : -1
            saioE = (nSe > 0) ? med(aSe, nSe) : -1
            pr  = (pgP > 0)             ? saioP / pgP            : -1
            er  = (pgE > 0)             ? saioE / pgE            : -1
            tot = (pgP > 0 && pgE > 0)  ? (saioP + saioE) / (pgP + pgE) : -1
            printf "%s,%s,%s,%s,%s,%s,%s,%s,%s\n", \
                q, nrels[q], \
                (pgP<0?"NA":pgP), (saioP<0?"NA":saioP), (pr<0?"NA":pr), \
                (pgE<0?"NA":pgE), (saioE<0?"NA":saioE), (er<0?"NA":er), \
                (tot<0?"NA":tot)
        }
    }
' "$PER_Q" | (read -r hdr; echo "$hdr"; sort) > "$SUMMARY"

echo "---" | tee -a "$LOG"
echo "Per-query CSV:  $PER_Q"  | tee -a "$LOG"
echo "Summary CSV:    $SUMMARY" | tee -a "$LOG"
echo "Plans:          $OUT_DIR/plans/{pg,saio}/" | tee -a "$LOG"

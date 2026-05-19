#!/bin/bash
# Bootstrap AQO for the training script:
#   1. Build & install contrib/aqo (assumes PG was already built with
#      the aqo_master.patch core hooks applied)
#   2. Add 'aqo' to shared_preload_libraries in postgresql.conf
#   3. Restart PG
#   4. CREATE EXTENSION aqo in the target database
#
# Usage: ./aqo_setup.sh [database]
#        DB defaults to 'imdb' (or $PGDATABASE).
#
# Idempotent: re-running is safe.

set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

DB="${1:-${PGDATABASE:-imdb}}"

# Resolve AQO source dir.  Common layouts (PG_BASE comes from lib.sh):
#   $PG_BASE/contrib/aqo  (preferred — inside the PG source tree)
#   $HOME/contrib/aqo
#   $HOME/aqo
# Also honour an explicit AQO_DIR env var.
AQO_DIR_CANDIDATES=()
[[ -n "${AQO_DIR:-}" ]] && AQO_DIR_CANDIDATES+=("$AQO_DIR")
AQO_DIR_CANDIDATES+=(
    "$PG_BASE/contrib/aqo"
    "$(dirname "$INSTDIR")/../contrib/aqo"
    "$HOME/my_postgres10/contrib/aqo"
    "$HOME/my_postgres9/contrib/aqo"
    "$HOME/contrib/aqo"
    "$HOME/aqo"
)

AQO_DIR=""
for cand in "${AQO_DIR_CANDIDATES[@]}"; do
    if [[ -f "$cand/Makefile" && -f "$cand/aqo.c" ]]; then
        AQO_DIR="$(cd "$cand" && pwd)"
        break
    fi
done

if [[ -z "$AQO_DIR" ]]; then
    echo "FATAL: AQO source not found.  Set AQO_DIR env or symlink it into"
    echo "       contrib/aqo of your PG source tree."
    exit 1
fi

PG_CONFIG="$INSTDIR/pg_config"
[[ -x "$PG_CONFIG" ]] || { echo "FATAL: pg_config not at $PG_CONFIG"; exit 1; }

echo "==> AQO_DIR    = $AQO_DIR"
echo "==> PG_CONFIG  = $PG_CONFIG"
echo "==> PGDATA     = $PGDATA"
echo "==> DATABASE   = $DB"
echo ""

# 1. Build & install AQO
echo "==> Building AQO..."
(
    cd "$AQO_DIR"
    make PG_CONFIG="$PG_CONFIG" clean >/dev/null 2>&1 || true
    make PG_CONFIG="$PG_CONFIG"
    make PG_CONFIG="$PG_CONFIG" install
)
echo ""

# 2. Add 'aqo' to shared_preload_libraries (idempotent)
PGCONF="$PGDATA/postgresql.conf"
if [[ ! -f "$PGCONF" ]]; then
    echo "FATAL: postgresql.conf not found at $PGCONF"; exit 1
fi

current_spl=$(grep -E "^shared_preload_libraries" "$PGCONF" | tail -1 || true)
if echo "$current_spl" | grep -q "aqo"; then
    echo "==> shared_preload_libraries already contains 'aqo' (skip):"
    echo "    $current_spl"
else
    backup="$PGCONF.bak.$(date +%s)"
    cp "$PGCONF" "$backup"
    if [[ -n "$current_spl" ]]; then
        new_line=$(echo "$current_spl" | sed -E "s/^(shared_preload_libraries\s*=\s*['\"])([^'\"]*)(['\"].*)$/\1\2,aqo\3/" | sed "s/,,/,/" | sed "s/'\\,/'/")
        awk -v new="$new_line" '
            /^shared_preload_libraries[[:space:]]*=/ && !done { print new; done=1; next }
            { print }
        ' "$backup" > "$PGCONF"
        echo "==> Edited shared_preload_libraries:"
        echo "    BEFORE: $current_spl"
        echo "    AFTER:  $new_line"
    else
        echo "shared_preload_libraries = 'aqo'" >> "$PGCONF"
        echo "==> Appended: shared_preload_libraries = 'aqo'"
    fi
    echo "    (backup at $backup)"
fi
echo ""

# 2a. Raise AQO hash-table limits (defaults are too small for big workloads)
#     - aqo.fs_max_items   (default 10000)   feature spaces
#     - aqo.fss_max_items  (default 100000)  feature subspaces
#     - aqo.dsm_size_max   (default 100 MB)  DSM cap
#     Override via env: AQO_FS_MAX_ITEMS / AQO_FSS_MAX_ITEMS / AQO_DSM_SIZE_MAX
AQO_FS_MAX_ITEMS="${AQO_FS_MAX_ITEMS:-100000}"     # 10x default
AQO_FSS_MAX_ITEMS="${AQO_FSS_MAX_ITEMS:-1000000}"  # 10x default
AQO_DSM_SIZE_MAX="${AQO_DSM_SIZE_MAX:-1024}"       # 10x default (MB)

set_pg_param() {
    local k="$1" v="$2"
    local cur
    cur=$(grep -E "^[[:space:]]*$k[[:space:]]*=" "$PGCONF" | tail -1 || true)
    if [[ -z "$cur" ]]; then
        echo "$k = $v" >> "$PGCONF"
        echo "==> appended $k = $v"
    else
        # idempotent: only rewrite if value differs
        awk -v k="$k" -v v="$v" -v done=0 '
            $0 ~ "^[[:space:]]*"k"[[:space:]]*=" && !done {
                print k " = " v
                done=1; next
            }
            { print }
        ' "$PGCONF" > "$PGCONF.tmp" && mv "$PGCONF.tmp" "$PGCONF"
        echo "==> set $k = $v   (was: $cur)"
    fi
}

set_pg_param aqo.fs_max_items   "$AQO_FS_MAX_ITEMS"
set_pg_param aqo.fss_max_items  "$AQO_FSS_MAX_ITEMS"
set_pg_param aqo.dsm_size_max   "$AQO_DSM_SIZE_MAX"
echo ""

# 3. Restart PG (preload libs require restart, not reload)
echo "==> Restarting PG ..."
if "$INSTDIR/pg_ctl" status -D "$PGDATA" >/dev/null 2>&1; then
    "$INSTDIR/pg_ctl" -D "$PGDATA" -w restart -l "$BENCH_ROOT/logfile.log"
else
    "$INSTDIR/pg_ctl" -w -D "$PGDATA" -l "$BENCH_ROOT/logfile.log" start
fi
echo ""

# 4. Create the extension
echo "==> CREATE EXTENSION aqo (in database $DB)..."
"$INSTDIR/psql" -p "$PGPORT" -d "$DB" -U "$PGUSER" -X -c \
    "CREATE EXTENSION IF NOT EXISTS aqo; SELECT extname, extversion FROM pg_extension WHERE extname='aqo';"
echo ""

echo "==> Done.  You can now run:  ./aqo_train.sh $DB 30"

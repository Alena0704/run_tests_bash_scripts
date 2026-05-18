# min_job — JOB benchmark runner for PostgreSQL and learned optimizers

A minimal set of bash scripts to run the [Join Order Benchmark (JOB)](https://github.com/gregrahn/join-order-benchmark) against:

- vanilla PostgreSQL (current `my_postgres10` build);
- **Bao** (learned planner-hook on a separate PG fork);
- **Neo** (neural optimizer, hints via `pg_hint_plan`);
- **Balsa** (successor to Neo by the same authors);
- **SkinnerDB** (standalone Java DBMS, no PostgreSQL);
- **MCTS-Extreme** (this repo's `contrib/mcts_extreme`);
- **AQO** (this repo's `contrib/aqo` — adaptive cardinality learning).

Each base runner does the same three things:
1. Reads queries from `$QUERY_FILES` (default [source/queries/](source/queries/)).
2. Saves the `EXPLAIN` plan to `plans/<method>/<query>.plan`.
3. Runs each query `ITERS` times and writes timings to `results/<method>_job.csv`.

After a run, [collect.sh](collect.sh) aggregates all `results/*_job.csv` into a single wide table `results/job_aggregate.csv` (median / p95 / min / max / n per query and method).

---

## Directory layout

| File / dir | Purpose |
|---|---|
| [lib.sh](lib.sh) | Shared variables (`PG_BASE`, `INSTDIR`, `PGDATA`, `PGPORT`, `QUERY_DIR`, `ITERS`, …) and helpers (`pg_ensure_up`, `run_query_once`, `save_plain_explain`, `csv_header`). Every other script does `source ./lib.sh`. |
| [job_create.sh](job_create.sh) | Creates the `imdb` DB, applies `schema.sql`, loads CSVs via `copy.sql`, creates FK indexes, runs `VACUUM ANALYZE`. |
| [job_run.sh](job_run.sh) | Runs against vanilla PG (method `plain_pg`). |
| [job_run_bao.sh](job_run_bao.sh) | Runs through Bao (port 5500, separate PG build, requires `bao_server` running). |
| [job_run_neo.sh](job_run_neo.sh) | Runs through Neo (port 5501, requires `pg_hint_plan` and pre-generated hints). |
| [job_run_balsa.sh](job_run_balsa.sh) | Runs through Balsa (port 5502, requires `pg_hint_plan` and hints). |
| [job_run_skinner.sh](job_run_skinner.sh) | Runs through SkinnerDB (Java jar, no PG). |
| [job_run_mcts_approbation.sh](job_run_mcts_approbation.sh) | Approbation sweep for MCTS along the `reward_mode × luby × rollout` axes, on the production-best substrate. |
| [job_run_mcts_ablation.sh](job_run_mcts_ablation.sh) | **Ablation**: start from production-best, turn ONE feature off at a time, measure the cost of removing each (gate, top_k, depth, kernels, luby, …). |
| [job_compare_methods.sh](job_compare_methods.sh) | Head-to-head comparison: `pg / mcts / pg_aqo / mcts_aqo` over JOB; AQO in `controlled` mode for stable cardinality estimates. |
| [job_cardinality_analysis.sh](job_cardinality_analysis.sh) | Per-node q-error analysis via `EXPLAIN (ANALYZE, VERBOSE, BUFFERS)` for the same configs. Phase B of the cardinality study. |
| [job_dump_plans.sh](job_dump_plans.sh) | Standalone `EXPLAIN` dumper — saves plans per `(config, query)` and a side-by-side digest. |
| [job_greedy_mcts.sh](job_greedy_mcts.sh) | Coordinate-descent (greedy) tuner over MCTS GUCs. Supports env-var pinning for multi-pass runs. |
| [aqo_setup.sh](aqo_setup.sh) | Builds & installs AQO, adds it to `shared_preload_libraries`, raises hash-table limits (`fs_max_items`, `fss_max_items`, `dsm_size_max`), restarts PG, runs `CREATE EXTENSION aqo`. |
| [aqo_train.sh](aqo_train.sh) | Trains AQO over N iterations on the JOB workload, with optional `--with-mcts` to train on MCTS-shaped plans, `--no-reset` to keep prior state. Tracks per-iter geomean exec time, learned-query count, and AQO q-error from `aqo_query_stat`. |
| [make_compare_plots.py](make_compare_plots.py) | Reads the latest `job_compare_methods.sh` run and produces `plots/slide37_worst_best_ratio.png`, `plots/e2e_scatter_all.png`, `plots/e2e_per_query_ratio_sorted.png`. |
| [collect.sh](collect.sh) | Folds `results/*_job.csv` into `results/job_aggregate.csv`. |
| [source/](source/) | Fork of [join-order-benchmark](https://github.com/gregrahn/join-order-benchmark): `schema.sql`, `copy.sql`, `fkindexes.sql`, IMDb CSV data (`source/csv/`), 113 queries (`source/queries/`). |
| `plans/<method>/` | (created on run) plain-text `EXPLAIN` plans. |
| `results/<method>_job.csv` | (created on run) `query,iter,exec_ms`. |
| `logs/` | (created on run) cluster logs. |

---

## Environment variables (from [lib.sh](lib.sh))

Override with `export` before invoking the script.

| Variable | Default | Meaning |
|---|---|---|
| `PG_BASE` | `$HOME/my_postgres10` | Single point of customization. All other PG paths derive from this. |
| `PG_DATA_NAME` | `vacuum_stats9` | Subdir name under `$PG_BASE` for `PGDATA`. |
| `INSTDIR` | `$PG_BASE/my/inst/bin` | PG bin directory. |
| `PGDATA` | `$PG_BASE/$PG_DATA_NAME` | Cluster data dir. |
| `PGPORT` | `5499` | Vanilla PG port. |
| `PGUSER` | `$(whoami)` | |
| `PGDATABASE` | `postgres` | Used before `imdb` is created. |
| `QUERY_DIR` | `$HOME/source` | Root of the JOB fork (`schema.sql`, `csv/`, `queries/` live here). |
| `QUERY_FILES` | `$QUERY_DIR/queries` | Directory with `*.sql`. |
| `BENCH_ROOT` | `$HOME/min_job` | Where to write `plans/`, `results/`, `logs/`. |
| `ITERS` | `5` | Reruns per query. |
| `STATEMENT_TIMEOUT_MS` | `600000` | 10 minutes per query. |

Each learned optimizer brings its own `*_PORT`, `*_PGDATA`, `*_INSTDIR`, `*_HINTS_DIR` — see the header of the matching `job_run_*.sh`.

---

## End-to-end run

```bash
# 0. Bring up the cluster and confirm it listens on 5499
#    (lib.sh::pg_ensure_up does this automatically).

# 1. Create the imdb DB from CSVs (source — source/)
export QUERY_DIR=$HOME/min_job/source
./job_create.sh imdb

# 2. Baseline run against vanilla PG
./job_run.sh imdb 5      # 5 iters per query -> results/plain_pg_job.csv

# 3. (Optional) AQO setup + training
./aqo_setup.sh imdb              # extension + raised hash limits + restart
./aqo_train.sh imdb 30           # 30 iters; AQO learns from DP/GEQO plans
./aqo_train.sh imdb 30 \         # additional pass: AQO also learns
              --with-mcts \      #   from MCTS-shaped plans
              --no-reset         #   preserves prior learning

# 4. Each learned optimizer (see prerequisites below)
./job_run_bao.sh     imdb 5
./job_run_neo.sh     imdb 5
./job_run_balsa.sh   imdb 5
./job_run_skinner.sh        5

# 5. Head-to-head: pg vs mcts, with and without AQO (4 configs × 113 queries × ITERS)
./job_compare_methods.sh imdb 5

# 6. Build plots from the latest compare run
python3 make_compare_plots.py
# -> plots/slide37_worst_best_ratio.png
# -> plots/e2e_scatter_all.png
# -> plots/e2e_per_query_ratio_sorted.png

# 7. Aggregate everything
./collect.sh             # -> results/job_aggregate.csv
```

---

## MCTS-Extreme + AQO workflow

This repo's `contrib/mcts_extreme` adds an MCTS-based join-search planner; `contrib/aqo` learns cardinality predictions from past executions. They compose: MCTS provides the join order, AQO provides the row estimates that drive cost-based pruning inside MCTS.

The typical pipeline:

```bash
# A. Build & install AQO; raise hash-table limits in postgresql.conf;
#    restart PG; CREATE EXTENSION aqo.
./aqo_setup.sh imdb

# B. Train AQO over N iters (mode='learn' by default).
./aqo_train.sh imdb 30                      # AQO learns from PG-DP/GEQO plans
./aqo_train.sh imdb 30 --with-mcts --no-reset  # AQO also learns from MCTS plans
# Outputs: results/aqo_train/<run-id>/{summary.csv,per_query.csv,log.txt}

# C. Compare planning methods at AQO-converged cardinalities.
./job_compare_methods.sh imdb 5
# Six possible configs (default: 4):
#   pg          PG default join search.  No AQO.
#   mcts        MCTS-extreme on ALL queries.  No AQO.
#   pg_aqo      PG + AQO controlled (uses learned cardinalities).
#   mcts_aqo    MCTS + AQO.   ★ flagship.
#   dp_only     diagnostic: force DP for all n_rels.
#   geqo_only   diagnostic: force GEQO for all n_rels.

# D. Per-node cardinality q-error analysis on the same configs.
./job_cardinality_analysis.sh imdb 1   # uses EXPLAIN (ANALYZE, VERBOSE)

# E. Ablation: cost of removing each MCTS feature from production-best.
./job_run_mcts_ablation.sh imdb 5
# Variants: pg, best, no_gate, k0_bushy, k_heur, k_bandit, with_topk5,
#           low_depth, low_budget, no_luby, reward_avg

# F. Plots.
python3 make_compare_plots.py
```

`job_compare_methods.sh` saves per-query plans alongside its CSV — output layout:

```
$RESULTS_DIR/compare/<run-id>/
├── per_query.csv      (query,n_rels,config,iter,exec_ms,top_cost)
├── summary.csv        (per-config geomean / median / wins-vs-pg / losses-vs-pg / geo_ratio_vs_pg)
├── log.txt
└── plans/
    ├── pg/<query>.plan
    ├── mcts/<query>.plan
    ├── pg_aqo/<query>.plan
    └── mcts_aqo/<query>.plan
```

For visual per-query comparison, use `job_dump_plans.sh` to produce a side-by-side digest:

```bash
./job_dump_plans.sh imdb 0   # 0 = plain EXPLAIN (fast).  1 = EXPLAIN ANALYZE (slow).
# -> $PLANS_DIR/<config>/<query>.plan
# -> $PLANS_DIR/diff/<query>.txt   -- aligned blocks of all configs
```

---

## Where to get the external repositories

All four learned optimizers below are external projects — **not vendored here**. The `job_run_*.sh` scripts assume you cloned them into `$HOME` and built them. CPU-only PyTorch is sufficient for the ML methods (no CUDA needed); training on CPU takes hours.

### Bao — [BaoForPostgreSQL](https://github.com/learnedsystems/BaoForPostgreSQL)

```bash
git clone https://github.com/learnedsystems/BaoForPostgreSQL ~/BaoForPostgreSQL
cd ~/BaoForPostgreSQL/pg_extension && make USE_PGXS=1 install
initdb -D ~/bao_pgdata
pg_ctl -D ~/bao_pgdata -o "-p 5500" start
psql -p 5500 postgres -c "CREATE EXTENSION pg_bao"
pip install --index-url https://download.pytorch.org/whl/cpu torch
pip install -r ~/BaoForPostgreSQL/bao_server/requirements.txt
export CUDA_VISIBLE_DEVICES=""
cd ~/BaoForPostgreSQL/bao_server && python main.py   # listens on :9381
```

Then re-run `job_create.sh` against port 5500 to load IMDb into the Bao cluster. Bao ships its own PG fork (planner modifications), so `pg_bao` cannot be loaded into a vanilla PG. Marcus et al., SIGMOD 2021.

[job_run_bao.sh](job_run_bao.sh) checks that `bao_server` is listening on `http://localhost:9381`; otherwise `pg_bao` silently falls back to the default planner, and timings would reflect PG rather than Bao.

### Neo — [KostasMparmparousis/Neo](https://github.com/KostasMparmparousis/Neo)

The original Marcus et al. (VLDB 2019) code was never released, so we use a community re-implementation. From 2022 onwards Neo has effectively been superseded by Balsa — if you pick one, pick Balsa.

```bash
git clone https://github.com/KostasMparmparousis/Neo ~/neo
# Build PG14 with pg_hint_plan:
git clone https://github.com/ossc-db/pg_hint_plan ~/pg_hint_plan
cd ~/pg_hint_plan && make PG_CONFIG=~/neo_pg/inst/bin/pg_config install
initdb -D ~/neo_pgdata
pg_ctl -D ~/neo_pgdata -o "-p 5501" start
echo "shared_preload_libraries = 'pg_hint_plan'" >> ~/neo_pgdata/postgresql.conf
pg_ctl -D ~/neo_pgdata restart
pip install --index-url https://download.pytorch.org/whl/cpu torch
pip install -r ~/neo/requirements.txt
export CUDA_VISIBLE_DEVICES=""
# Train Neo on the JOB train-split, then generate hints:
#   ~/neo/hints/<query>.hint   <- pg_hint_plan string per query
```

[job_run_neo.sh](job_run_neo.sh) reads the hint from `$NEO_HINTS_DIR/<query>.hint`, loads `pg_hint_plan`, prepends the hint to the SQL, and measures.

### Balsa — [balsa-project/balsa](https://github.com/balsa-project/balsa)

Yang et al., SIGMOD 2022. Successor to Neo, trains without expert demonstrations.

```bash
git clone https://github.com/balsa-project/balsa ~/balsa
cd ~/balsa
./scripts/build_pg.sh    # builds PG14 with pg_hint_plan and Balsa's patch -> ~/balsa/inst/
./scripts/init_db.sh     # cluster on port 5502
pip install --index-url https://download.pytorch.org/whl/cpu torch
pip install -r ~/balsa/requirements.txt
export CUDA_VISIBLE_DEVICES=""
python -m balsa.train --workload=job --device=cpu
# Balsa writes per-query hints into ~/balsa/hints/job/<query>.hint
```

[job_run_balsa.sh](job_run_balsa.sh) applies the hint and times via `pg_hint_plan`, exactly like Neo.

### SkinnerDB — [cornelldbgroup/skinnerdb](https://github.com/cornelldbgroup/skinnerdb)

Trummer et al., SIGMOD 2019. Standalone Java DBMS — **no PostgreSQL involved**.

```bash
git clone https://github.com/cornelldbgroup/skinnerdb ~/SkinnerDB
cd ~/SkinnerDB && mvn package
# Load IMDb into SkinnerDB's bundled storage:
java -jar target/skinnerdb-1.0-SNAPSHOT-jar-with-dependencies.jar \
     --load $HOME/min_job/source/csv
```

[job_run_skinner.sh](job_run_skinner.sh) pipes SQL into the jar via stdin and parses the `Query took XXX ms` line. Neither `\timing` nor `pg_hint_plan` apply here.

---

## Notes

- All `job_run_*.sh` write CSVs in the same `query,iter,exec_ms` format, so [collect.sh](collect.sh) picks up any new method automatically — just drop a file into `results/<method>_job.csv`.
- Bao is timed as plain wallclock (`\timing`) — that's total cost (planning + execution); Bao injects hints via `planner_hook`. Neo and Balsa are timed against pre-generated hints, so inference time is not part of `exec_ms`.
- The IMDb deployment has only been tested in C-locale (see [source/README.md](source/README.md)).
- AQO requires the core hooks patch from [contrib/aqo/aqo_master.patch](../contrib/aqo/aqo_master.patch) — without it, `CREATE EXTENSION aqo` will segfault on `pg_extension` lookups. The patch is committed on this branch (`add-adaptive-kernel`); rebuild PG after applying it.
- MCTS-Extreme's production-best config (`fixed K=1, min_relations=13, depth=8, top_k=0, expl=1.0, budget=100, phases=5`) is documented in `min_job/adaptive_kernels/PARAM_STUDY.md`. The comparison and ablation scripts use `min_relations=2` so MCTS runs on every query — for a head-to-head with DP/GEQO across the full workload.

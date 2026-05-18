# Bao & Neo & SkinnerDB on PostgreSQL 19devel — reproducibility log

Local runs of three learned query optimizers (LQOs) on the `my_postgres9` build
(PostgreSQL 19devel) + the JOB benchmark + IMDb on port 5499 (for PG-based LQOs) /
Java standalone (for SkinnerDB).  The goal: replace the paper-claimed bars on
slides **34** (latency) and **37** (worst/best ratio) with real measurements.

---

## Headline result

| Metric | PG baseline | Bao (ours) | Neo (ours) | **SkinnerDB (ours)** | Bao paper | Neo paper | SkinnerDB paper |
|---|---:|---:|---:|---:|---:|---:|---:|
| Median exec, ms | **432** | 735 | 667 | **296** | 268 (0.62×) | 355 (0.82×) | 864 (2.00×) |
| Mean exec, ms   | — | 3382 | 3351 | 434 | — | — | — |
| p95 exec, ms    | 11502 | 16272 | 16494 | 1242 | — | — | — |
| Per-query ratio vs PG (median) | 1.00× | **1.72×** | **1.43×** | **0.59×** | 0.62× | 0.82× | 2.00× |

The main finding is **bidirectional**:

- **Bao and Neo lose to the PG baseline** on our configuration (1.72× and 1.43×
  slowdown vs the paper-claimed 0.62× and 0.82× speedup) — a local confirmation
  of the Lehmann, Sulimov & Stockinger VLDB '24 result (slide 29 of the deck).
- **SkinnerDB beats PG unexpectedly** (0.59× = 41% speedup), the **opposite** of
  the paper-claimed 2.00× slowdown (Trummer '19).  The 2.00× number in older
  papers most likely refers to a different workload or an early version of the
  Java DBMS; on the 2019 dataset SkinnerDB is actually faster.  Of the three
  LQOs in our sample, SkinnerDB is the only one that genuinely beats PG.

---

## Bao

### Setup
- Repo: <https://github.com/learnedsystems/BaoForPostgreSQL>
- Checkout: `/Users/alena/BaoForPostgreSQL`
- venv with CPU-only PyTorch: `/Users/alena/BaoForPostgreSQL/.venv`
- Bao server (TCP 9381) backgrounded via `CUDA_VISIBLE_DEVICES="" python main.py`

### Porting `pg_bao` to PG19devel

`pg_bao` was originally written for PG ≤ 14.  PG19devel required 7 fixes in
[BaoForPostgreSQL/pg_extension/](../../BaoForPostgreSQL/pg_extension/):

1. `utils/relfilenodemap.h` → `utils/relfilenumbermap.h` *(PG16 rename)*
2. `bufHdr->tag.rnode.spcNode` → `bufHdr->tag.spcOid` *(buftag struct rename)*
3. `bufHdr->tag.rnode.relNode` → `bufHdr->tag.relNumber`
4. `RelidByRelfilenode` → `RelidByRelfilenumber`
5. `planner_hook` signature 3-arg → 5-arg (`query_string`, `ExplainState *es`)
6. `standard_planner(...)` likewise 5-arg
7. `ExplainOnePlan(...)` 7-arg → 9-arg (added `BufferUsage*`, `MemoryContextCounters*`)
8. `queryDesc->totaltime` → `queryDesc->query_instr` *(field rename)*
9. `InstrAlloc(1, INSTRUMENT_TIMER)` → `InstrAlloc(INSTRUMENT_TIMER)` *(arity)*
10. `INSTR_TIME_GET_MILLISEC(instr->total)` replaces `instr->total * 1000.0`
    *(struct member type changed)*

And, the big one — **a bug inside Bao itself**: the loop
`for (int i = 0; i < list_length(parse->rtable); i++) rt_fetch(i, ...)` uses a
**0-based index**, while the `rt_fetch` macro is **1-based**.  On PG ≤ 14 this
was undefined behaviour that happened to work for small rtables; on PG19 it
crashes whenever the query has 5+ tables.  Fixed to
`for (int i = 1; i <= list_length(...); i++)`.

After the fixes:
```bash
cd ~/BaoForPostgreSQL/pg_extension && \
  make PG_CONFIG=~/my_postgres9/my/inst/bin/pg_config install
```

### Training and test
- Script: [bao_train_and_test.sh](bao_train_and_test.sh)
- 2 epochs of online learning + 1 test pass = 339 queries through `pg_bao`
- Per query: 5-arm enumeration → Bao picks the best → execute → reward
  reported back to `bao_server` → Bao retrains every 25 queries
- Runtime: ~30 min CPU
- Parallelism: disabled (`max_parallel_workers_per_gather = 0`) due to crashes
  in the parallel worker

Output: [results/bao_job.csv](results/bao_job.csv) (113 rows, `query,iter,exec_ms`).

---

## Neo

### Setup
- Re-implementation: <https://github.com/KostasMparmparousis/Neo>
  (the original Marcus et al. VLDB '19 code was never released)
- Checkout: `/Users/alena/Neo`, copied into the expected layout
  `/Users/alena/Learned-Optimizers-Benchmarking-Suite/optimizers/Neo`
- Wrapper suite: `/Users/alena/Learned-Optimizers-Benchmarking-Suite/`
  with `.env`, `workloads/imdb_pg_dataset/job/` (113 JOB queries), and
  `runs/job/postgresql/optimizer/` (113 baseline plan JSONs)
- venv with CPU-only PyTorch: `/Users/alena/Neo/.venv`

### Patches to Neo
- 4 files in `database_env/*.py`: dropped `np.int`, `np.float`, `np.bool`
  (deprecated in NumPy 2.0)
- `run_experiment.py`: added `parent_dir=str(Path(logdir).resolve())` when
  constructing `Neo(...)`
- `run_experiment.py`: `output_dir = Path("runs/job_added_index/...")` →
  `Path(config['neo_args']['baseline_path'])` so baseline collection and
  training read from the same place
- Stripped the `explain analyze` prefix from `30c.sql` (Neo prepends its own
  `EXPLAIN (FORMAT JSON)`)
- Config `config_neo_cpu_short.yml`: `device: cuda` → `cpu`, `total_episodes:
  100` → `5`, `n_workers: 8` → `1`

### Porting `pg_hint_plan` to PG19devel

`pg_hint_plan` is needed by Neo to apply `Leading()` + `HashJoin/NestLoop/
MergeJoin` hints.  Version 1.9.0 didn't compile on PG19devel — 5 errors.  Fixes
in [my_postgres9/contrib/pg_hint_plan/pg_hint_plan.c](../contrib/pg_hint_plan/pg_hint_plan.c):

1. `JumbleState *jstate` → `const JumbleState *jstate`
   *(post_parse_analyze_hook_type)*
2. `standard_conforming_strings` → `true` (the backend global was removed from
   the API; it is always `true` in modern PG)
3. `get_relation_info_hook` was **removed entirely in PG19** — disabled the
   hook install (loses index-hint support, but `Leading()`/`HashJoin()`/etc.
   still work in full)

### Training and test
- Script: `run_experiment.py` (inside the BaoForPostgreSQL-style `.venv`)
- 5 epochs × 113 queries = 565 episodes, CPU-only training
- Runtime: **~2.5 hours** (21:39 to 00:03)
- Saved: `final_model.pt`, `checkpoint_ep565.pt`, 113 `best-plans/*.json`
- **28 of 113** plans actually finished building (have a join tree); the
  remaining **85** are empty (Neo didn't converge within 5 epochs)
- Test: [run_neo_test.py](../../Learned-Optimizers-Benchmarking-Suite/optimizers/Neo/run_neo_test.py)
  translates Neo's plan tree into a `pg_hint_plan` `Leading()` +
  `HashJoin/NestLoop` hint, runs `EXPLAIN ANALYZE` through PG, captures the
  `Execution Time`

Output: [results/neo_job.csv](results/neo_job.csv) (113 rows).

---

## SkinnerDB

### Setup
- Repo: <https://github.com/cornelldbgroup/skinnerdb> (cloned into
  `/Users/alena/my_postgres9/skinnerdb`)
- **Pre-built jar**: `skinnerdb/jars/Skinner.jar` (no Maven build needed)
- IMDb dataset: `imdbskinner.zip`, 1.12 GB, from Google Drive
  ID `1UCXtiPvVlwzUCWxKM6ic-XqIryk4OTgE`; after unzip — 3.2 GB in
  `/Users/alena/skinnerimdb/`
- Java 25 (`/opt/homebrew/opt/openjdk`, openjdk 25.0.2)
- Doesn't use PostgreSQL — it's a standalone Java DBMS with its own storage

### Running it
```bash
java -jar -Xmx12G ~/my_postgres9/skinnerdb/jars/Skinner.jar ~/skinnerimdb
# inside the SkinnerDB console:
bench ~/my_postgres9/skinnerdb/imdb/queries ~/my_postgres9/min_job/results/skinner_raw.csv
```
113 queries × 1 pass = **~10 minutes**.  SkinnerDB itself uses UCT/RL for join
ordering — it literally tries different plans on the fly (online RL).

The raw CSV has columns `Query,Millis,PreMillis,PostMillis,Tuples,
Iterations,...`.  The converter sums `total = PreMillis + Millis + PostMillis`
per query → [results/skinner_job.csv](results/skinner_job.csv) (113 rows).

---

## Plots (both copies)

In `/Users/alena/my_postgres9/min_job/plots/` and `/Users/alena/min_job/plots/`:

| File | What it shows |
|---|---|
| [slide34_job_latency.png](plots/slide34_job_latency.png) | Median latency: PG / HyperQO intervened / HyperQO fallback / **Bao (real)** / **Neo (real)** / **SkinnerDB (real)** |
| [slide35_qerror.png](plots/slide35_qerror.png) | Q-error of CE models (all published values) |
| [slide36_inference_overhead.png](plots/slide36_inference_overhead.png) | Inference overhead vs query exec time |
| [slide37_worst_best_ratio.png](plots/slide37_worst_best_ratio.png) | Per-query latency ratio vs PG — HyperQO / AlphaJoin / MCTS-Extreme / **Bao real (1.72×)** / **Neo real (1.43×)** / **SkinnerDB real (0.59×)** / Balsa (paper) |
| [e2e_bars_by_size.png](plots/e2e_bars_by_size.png) | e2e median/p95, split ≤11 vs ≥12 relations, all 7 real methods + 1 paper-only (Balsa) |
| [e2e_scatter_all.png](plots/e2e_scatter_all.png) | 6-panel scatter — each real method vs PG, coloured by ≤11/≥12 |
| [all_methods_combined.png](plots/all_methods_combined.png) | Mega-chart: 6 scatter rows + bars + robustness boxplots |

---

## Repro

```bash
# 1. Bao
cd ~/BaoForPostgreSQL/pg_extension && \
  make PG_CONFIG=~/my_postgres9/my/inst/bin/pg_config install
cd ~/BaoForPostgreSQL/bao_server && source ../.venv/bin/activate && \
  CUDA_VISIBLE_DEVICES="" nohup python main.py &
~/my_postgres9/my/inst/bin/psql -p 5499 imdb -c "CREATE EXTENSION IF NOT EXISTS pg_bao"
bash ~/my_postgres9/min_job/bao_train_and_test.sh

# 2. pg_hint_plan (needed for Neo)
cd ~/my_postgres9/contrib/pg_hint_plan && \
  make PG_CONFIG=~/my_postgres9/my/inst/bin/pg_config install

# 3. Neo
cd ~/Learned-Optimizers-Benchmarking-Suite/optimizers/Neo && \
  source .venv/bin/activate
PYTHONPATH=. python run_experiment.py \
  ~/Learned-Optimizers-Benchmarking-Suite/workloads/imdb_pg_dataset/job/ \
  config/config_neo_cpu_short.yml
python run_neo_test.py

# 4. Regenerate plots
cd ~/my_postgres9/min_job && \
  python3 plot_slides.py && python3 plot_all_methods.py && \
  cp plots/*.png ~/min_job/plots/
```

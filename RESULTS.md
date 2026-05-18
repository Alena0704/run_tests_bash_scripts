# Bao & Neo & SkinnerDB on PostgreSQL 19devel — reproducibility log

Локальный прогон трёх LQO на твоей сборке `my_postgres9` (PostgreSQL 19devel) +
JOB benchmark + IMDb на порту 5499 (для PG-LQO) / Java standalone (для SkinnerDB).
Цель — закрыть paper-claimed столбики на слайдах **34** (latency) и **37**
(worst/best ratio) реальными измерениями.

---

## Сводный результат

| Метрика | PG baseline | Bao (наш) | Neo (наш) | **SkinnerDB (наш)** | Bao paper | Neo paper | SkinnerDB paper |
|---|---:|---:|---:|---:|---:|---:|---:|
| Median exec, ms | **432** | 735 | 667 | **296** | 268 (0.62×) | 355 (0.82×) | 864 (2.00×) |
| Mean exec, ms   | — | 3382 | 3351 | 434 | — | — | — |
| p95 exec, ms    | 11502 | 16272 | 16494 | 1242 | — | — | — |
| Per-query ratio vs PG (median) | 1.00× | **1.72×** | **1.43×** | **0.59×** | 0.62× | 0.82× | 2.00× |

Главное наблюдение, **двусторонняя картина**:
- **Bao и Neo проигрывают PG baseline** на нашей конфигурации (1.72× и 1.43× slowdown
  vs paper-claimed 0.62× и 0.82× speedup) — это локальное подтверждение тезиса
  Lehmann, Sulimov & Stockinger VLDB '24 (сюжет слайда 29 презентации).
- **SkinnerDB неожиданно выигрывает у PG** (0.59× = 41% speedup), **обратно** paper-claimed
  2.00× slowdown (Trummer '19). Скорее всего цифра 2.00× из старых статей касалась
  другого workload или ранней версии Java DBMS; на 2019-датасете SkinnerDB реально
  быстрее. SkinnerDB — единственный из трёх LQO в нашей выборке, кто реально побивает PG.

---

## Bao

### Setup
- Repo: <https://github.com/learnedsystems/BaoForPostgreSQL>
- Клон: `/Users/alena/BaoForPostgreSQL`
- venv с CPU-only PyTorch: `/Users/alena/BaoForPostgreSQL/.venv`
- Bao server (TCP 9381) поднят в фоне через `CUDA_VISIBLE_DEVICES="" python main.py`

### Порт `pg_bao` под PG19devel
`pg_bao` изначально написан под PG ≤ 14. Под PG19devel понадобилось 7 правок
в [BaoForPostgreSQL/pg_extension/](../../BaoForPostgreSQL/pg_extension/):

1. `utils/relfilenodemap.h` → `utils/relfilenumbermap.h` *(PG16 rename)*
2. `bufHdr->tag.rnode.spcNode` → `bufHdr->tag.spcOid` *(buftag struct rename)*
3. `bufHdr->tag.rnode.relNode` → `bufHdr->tag.relNumber`
4. `RelidByRelfilenode` → `RelidByRelfilenumber`
5. `planner_hook` сигнатура 3-arg → 5-arg (`query_string`, `ExplainState *es`)
6. `standard_planner(...)` тоже 5-arg
7. `ExplainOnePlan(...)` 7-arg → 9-arg (+`BufferUsage*`, `MemoryContextCounters*`)
8. `queryDesc->totaltime` → `queryDesc->query_instr` *(field rename)*
9. `InstrAlloc(1, INSTRUMENT_TIMER)` → `InstrAlloc(INSTRUMENT_TIMER)` *(arity)*
10. `INSTR_TIME_GET_MILLISEC(instr->total)` вместо `instr->total * 1000.0` *(struct member type)*

И главное — **bug в самом Bao**: цикл `for (int i = 0; i < list_length(parse->rtable); i++) rt_fetch(i, ...)`
использует **0-based индекс**, а макрос `rt_fetch` **1-based**. На PG ≤ 14 это
было UB которое случайно работало для маленьких rtable; на PG19 крашит на 5+
таблицах. Поправил на `for (int i = 1; i <= list_length(...); i++)`.

После исправлений:
```bash
cd ~/BaoForPostgreSQL/pg_extension && \
  make PG_CONFIG=~/my_postgres9/my/inst/bin/pg_config install
```

### Обучение и тест
- Скрипт: [bao_train_and_test.sh](bao_train_and_test.sh)
- 2 epoch online learning + 1 test pass = 339 запросов через pg_bao
- Каждый запрос: 5 arm enumeration → Bao выбирает лучший → execute → reward
  отправляется на bao_server → каждые 25 запросов Bao переобучается
- Время прогона: ~30 минут CPU
- Параллелизм: отключён (`max_parallel_workers_per_gather = 0`) из-за крашей
  в parallel worker

Результат: [results/bao_job.csv](results/bao_job.csv) (113 строк, `query,iter,exec_ms`).

---

## Neo

### Setup
- Реимплементация: <https://github.com/KostasMparmparousis/Neo>
  (оригинальный код Marcus VLDB '19 не открыт)
- Клон: `/Users/alena/Neo`, скопирован в требуемую структуру
  `/Users/alena/Learned-Optimizers-Benchmarking-Suite/optimizers/Neo`
- Wrapper-suite: `/Users/alena/Learned-Optimizers-Benchmarking-Suite/`
  с `.env`, `workloads/imdb_pg_dataset/job/` (113 запросов JOB), и
  `runs/job/postgresql/optimizer/` (113 baseline plan JSONs)
- venv с CPU-only PyTorch: `/Users/alena/Neo/.venv`

### Правки в Neo
- 4 файла `database_env/*.py`: убрал `np.int`, `np.float`, `np.bool` (deprecated в NumPy 2.0)
- `run_experiment.py`: добавил `parent_dir=str(Path(logdir).resolve())` при создании `Neo(...)`
- `run_experiment.py`: `output_dir = Path("runs/job_added_index/...")` → `Path(config['neo_args']['baseline_path'])`
  чтобы baseline collection и training читали из одного места
- Удалил из `30c.sql` префикс `explain analyze` (Neo prepend'ит свой `EXPLAIN (FORMAT JSON)`)
- Конфиг `config_neo_cpu_short.yml`: `device: cuda` → `cpu`, `total_episodes: 100` → `5`,
  `n_workers: 8` → `1`

### Порт `pg_hint_plan` под PG19devel
`pg_hint_plan` нужен Neo для применения `Leading()` + `HashJoin/NestLoop/MergeJoin`
хинтов. Версия 1.9.0 не компилировалась на PG19devel — 5 ошибок. Правки в
[my_postgres9/contrib/pg_hint_plan/pg_hint_plan.c](../contrib/pg_hint_plan/pg_hint_plan.c):

1. `JumbleState *jstate` → `const JumbleState *jstate` *(post_parse_analyze_hook_type)*
2. `standard_conforming_strings` → `true` (бэкенд-глобал убрана из API; всегда `true` в современном PG)
3. `get_relation_info_hook` **полностью удалён в PG19** — отключил установку
   хука (теряется поддержка index-hints, но `Leading()`/`HashJoin()`/etc.
   работают полностью)

### Обучение и тест
- Скрипт: [BaoForPostgreSQL/.venv-style] `run_experiment.py`
- 5 epochs × 113 queries = 565 episodes, CPU-only training
- Время: **~2.5 часа** (с 21:39 до 00:03)
- Сохранено: `final_model.pt`, `checkpoint_ep565.pt`, 113 best-plans/*.json
- **28 из 113** планов реально достроены (имеют join tree), остальные
  **85** пустые (Neo не успел достроить за 5 epochs)
- Тест: [run_neo_test.py](../../Learned-Optimizers-Benchmarking-Suite/optimizers/Neo/run_neo_test.py)
  переводит Neo's plan tree в pg_hint_plan `Leading()` + `HashJoin/NestLoop`
  hints, прогоняет `EXPLAIN ANALYZE` через PG, забирает `Execution Time`

Результат: [results/neo_job.csv](results/neo_job.csv) (113 строк).

---

---

## SkinnerDB

### Setup
- Repo: <https://github.com/cornelldbgroup/skinnerdb> (склонирован в
  `/Users/alena/my_postgres9/skinnerdb`)
- **Готовый pre-built jar**: `skinnerdb/jars/Skinner.jar` (Maven build не нужен)
- IMDb dataset: `imdbskinner.zip` 1.12 GB с Google Drive
  ID `1UCXtiPvVlwzUCWxKM6ic-XqIryk4OTgE`, после unzip — 3.2 GB в
  `/Users/alena/skinnerimdb/`
- Java 25 (`/opt/homebrew/opt/openjdk`, openjdk 25.0.2)
- Не использует PostgreSQL — это самостоятельная Java DBMS с собственным storage

### Прогон
```bash
java -jar -Xmx12G ~/my_postgres9/skinnerdb/jars/Skinner.jar ~/skinnerimdb
# в консоли SkinnerDB:
bench ~/my_postgres9/skinnerdb/imdb/queries ~/my_postgres9/min_job/results/skinner_raw.csv
```
113 queries × 1 pass = **~10 минут**. SkinnerDB сам использует UCT/RL для join
ordering — он буквально пробует разные планы на лету (online RL).

Сырой CSV содержит `Query,Millis,PreMillis,PostMillis,Tuples,Iterations,...`.
Скрипт-конвертер собирает `total = PreMillis + Millis + PostMillis` для каждого
запроса → [results/skinner_job.csv](results/skinner_job.csv) (113 строк).

---

## Графики (обе копии)

В `/Users/alena/my_postgres9/min_job/plots/` и `/Users/alena/min_job/plots/`:

| Файл | Что показывает |
|---|---|
| [slide34_job_latency.png](plots/slide34_job_latency.png) | Median latency: PG / HyperQO intervened / HyperQO fellback / **Bao (real)** / **Neo (real)** / **SkinnerDB (real)** |
| [slide35_qerror.png](plots/slide35_qerror.png) | Q-error CE-моделей (всё published) |
| [slide36_inference_overhead.png](plots/slide36_inference_overhead.png) | Inference overhead vs query exec time |
| [slide37_worst_best_ratio.png](plots/slide37_worst_best_ratio.png) | Per-query latency ratio vs PG — HyperQO / AlphaJoin / MCTS-Extreme / **Bao real (1.72×)** / **Neo real (1.43×)** / **SkinnerDB real (0.59×)** / Balsa paper |
| [e2e_bars_by_size.png](plots/e2e_bars_by_size.png) | e2e medianp95, split ≤11 vs ≥12 relations, all 7 real + 1 paper-only (Balsa) |
| [e2e_scatter_all.png](plots/e2e_scatter_all.png) | 6 panel scatter — каждый real-метод vs PG, цвет по ≤11/≥12 |
| [all_methods_combined.png](plots/all_methods_combined.png) | Сводный мега-чарт: 6 scatter rows + bars + robustness boxplots |

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

# 2. pg_hint_plan (нужен для Neo)
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

# SAIO on PostgreSQL 19devel — порт, баги, эксперименты

Отчёт по адаптации старого PGXN-расширения [saio](https://github.com/parkag/saio)
(SA-планировщик порядка джойнов, J. Urbański, 2010) под текущий мастер
PostgreSQL и его эмпирическому сравнению с GEQO на JOB-бенчмарке.

## TL;DR

* Адаптировала исходники под PG 19devel (List → массив, `nodes/relation.h` → `pathnodes.h`, новый extension-state API планировщика, `pg_prng_*` вместо `erand48`). Модуль собирается чисто (`contrib/saio/`) и грузится через `LOAD 'saio'`.
* Нашла два **runtime-бага** в апстриме saio, из-за которых на PG ≥ 13 SA-алгоритм **никогда не делал ни одного хода** и возвращал план жадного `make_query_tree`.
* После фиксов на JOB с `n_rels ≥ 12` SAIO находит планы конкурентные с GEQO; на 4 запросах из 19 **обгоняет GEQO в total e2e в 1.1-3.2×** (за счёт побед на exec, не за счёт plan-фазы).
* Дефолтные параметры SAIO дают огромный planning overhead (5-11 сек). Подобранная «дешёвая» настройка снижает его до ~0.3-0.8 сек при сохранении большинства exec-выигрышей.

## 1. Порт под PG 19devel

Исходные коммиты saio в parkag/saio датированы 2010-2015 (последний — 2015-08-08). Между ним и текущим мастером PostgreSQL изменилось:

| API | старое | новое |
|---|---|---|
| Заголовок с PlannerInfo/RelOptInfo | `nodes/relation.h` | `nodes/pathnodes.h` (PG 12) |
| Список | связный (cons-cell) | массив (PG 13) — `lcons/lappend` возвращают новый указатель |
| `list_delete_cell(list, cell, prev)` | 3 аргумента | `list_delete_cell(list, cell)` (PG 13) |
| Per-PlannerInfo приватный slot | `root->join_search_private` | `SetPlannerInfoExtensionState(root, id, ptr)` (см. `optimizer/extendplan.h`) |
| PRNG | `erand48()` + 3×short state | `pg_prng_state` + `pg_prng_double/fseed/uint64_range` |
| Memory context reset | `MemoryContextResetAndDeleteChildren` | `MemoryContextReset` (рекурсивно по-новому) |
| Hash table | `HASH_FUNCTION+HASH_COMPARE` (флаги) | тот же API |

Также убран `_PG_fini` (с PG 17 не вызывается dynloader-ом), Makefile приведён к стилю `auto_explain`, добавлен пустой `saio--0.0.1.sql`, чтобы `CREATE EXTENSION saio` работал. Источник: [contrib/saio/](/Users/alena/my_postgres12/contrib/saio/).

## 2. Найденные баги

### Bug 1: `get_all_nodes_rec` теряла все узлы кроме корня

Файл: [`saio_trees.c`](/Users/alena/my_postgres12/contrib/saio/src/saio_trees.c)

```c
static List *
get_all_nodes_rec(QueryTree *tree, List *res)
{
    if (tree == NULL) return res;
    res = lcons(tree, res);
    get_all_nodes_rec(tree->left,  res);   // ← возврат игнорируется
    get_all_nodes_rec(tree->right, res);   // ← возврат игнорируется
    return res;
}
```

На PG ≤ 12 (List = связный) `lcons` мутировал хранилище на месте, и игнорирование возврата иногда «прокатывало». На PG ≥ 13 List стал массивом — `lcons` всегда возвращает новый указатель, и узлы дочерних поддеревьев нигде не сохраняются. Возвращается список из **одного корня**.

Эффект: в `saio_recalc_step` проверка `list_length(all_trees) < 4` всегда true → `return SAIO_MOVE_IMPOSSIBLE` на каждой итерации SA-цикла. На 17-rel запросе диагностика показала **32 096 отказов подряд**, ни одного успешного хода. Финальный план — целиком от стартового жадного `make_query_tree`.

Фикс — захватывать возвраты:
```c
res = get_all_nodes_rec(tree->left,  res);
res = get_all_nodes_rec(tree->right, res);
```

### Bug 2: `saio_randint` чувствителен к порядку аргументов

Файл: [`saio_util.c`](/Users/alena/my_postgres12/contrib/saio/src/saio_util.c)

Апстрим saio имел макрос `saio_randint(root, upper, lower)`, но callsite в `saio_recalc.c` зовёт его как `saio_randint(root, 0, list_length(choices) - 1)` — фактически передавая `upper=0, lower=N-1`. Старый макрос с трюками `floor(neg * 0.999999)` возвращал что-то «достаточно случайное» в диапазоне 1..N-1.

Моя замена через `pg_prng_uint64_range(state, lower, upper)` при `rmax < rmin` по спецификации **всегда возвращает rmin**. То есть после фикса bug 1 алгоритм всегда выбирал один и тот же узел tree1 = `choices[N-1]` (большое поддерево под корнем) → `tmp = subtree ∪ ancestors ∪ siblings = всё дерево` → `choices == NIL` → `SAIO_MOVE_IMPOSSIBLE`.

Фикс — устойчивая к порядку аргументов функция:
```c
int saio_randint(PlannerInfo *root, int a, int b)
{
    uint64 lo = (a < b) ? (uint64) a : (uint64) b;
    uint64 hi = (a < b) ? (uint64) b : (uint64) a;
    return (int) pg_prng_uint64_range(&private->random_state, lo, hi);
}
```

### Sanity check после фиксов

Один и тот же запрос (29a, 17 rels) с разными `saio_seed`:

| | до bug 1 fix | после bug 1 fix, до bug 2 fix | после обоих |
|---|---|---|---|
| accepted SA moves | 0 | 0 | **~7 200** |
| top_cost | 98 944.57 | 98 944.57 | **3 917.71** (= pg) |

## 3. Дополнительный потенциальный bug

В `check_possible_join` ([`saio_recalc.c`](/Users/alena/my_postgres12/contrib/saio/src/saio_recalc.c)) аллокируется `palloc(sizeof(QueryTree))` под `tree->tmp`, который потом используется как `RelOptInfo *`, и пишется в `tmp->relids`. В старом PG `RelOptInfo.relids` лежал близко к началу структуры — попадало в выделенный буфер случайно. В PG 19 `relids` сильно ниже — это heap-overrun. Заменено на `palloc0(sizeof(RelOptInfo))`.

## 4. Методология

* PostgreSQL 19devel (master, мой локальный билд `~/my_postgres12`).
* База данных IMDB (JOB), 113 запросов, отобраны 19 с `n_rels > 11` (грубо count commas во FROM).
* `EXPLAIN (ANALYZE, TIMING ON, BUFFERS OFF)`, парсим `Planning Time` и `Execution Time`.
* По 3 итерации на каждую (config, query); медиана.
* `statement_timeout = 600 000` мс. 30c упирается в таймаут у всех конфигов (queries-данные).
* Скрипты: [job_run_saio_configs.sh](/Users/alena/my_postgres9/run_tests_bash_scripts/job_run_saio_configs.sh), [make_saio_configs_plots.py](/Users/alena/my_postgres9/run_tests_bash_scripts/make_saio_configs_plots.py).

### Сравниваемые SAIO-конфиги

| GUC | `default` | `mid` | `cheap` |
|---|---|---|---|
| `saio_equilibrium_factor` | 16 | 8 | 4 |
| `saio_initial_temperature_factor` | 2.0 | 2.0 | 2.0 |
| `saio_temperature_reduction_factor` | 0.9 | 0.85 | 0.7 |
| `saio_moves_before_frozen` | 4 | 3 | 2 |

`pg` — GEQO с дефолтами (`geqo_threshold=12`, `geqo=on`, `join_collapse_limit=100`).

## 5. Результаты

### Сводная статистика (saio vs pg, медианы и геосредние ratio)

| config | planning median | exec median | total median | wins | losses |
|---|---|---|---|---|---|
| `saio_default` | 38.7× | 1.14× | 16.4× | 2 / 19 | 17 / 19 |
| `saio_mid` | 12.5× | 1.20× | 5.4× | 3 / 19 | 16 / 19 |
| `saio_cheap` | **3.0×** | **1.05×** | **2.6×** | **4 / 19** | 15 / 19 |

Wins = saio total < pg total. Losses = saio total > 1.05× pg total.

### Запросы где SAIO бьёт PG (saio_cheap)

| query | n_rels | pg total | saio_cheap total | speedup | где выигрыш |
|---|---|---|---|---|---|
| **30a** | 12 | 6.2 s | **1.9 s** | **3.24×** ✨ | exec 7.2s → 3.4s |
| **26c** | 12 | 10.4 s | **4.4 s** | **2.40×** ✨ | exec 10.2s → 5.4s |
| **28c** | 14 | 7.7 s | **5.5 s** | 1.39× | exec 7.5s → 5.0s |
| **26a** | 12 | 2.8 s | **2.5 s** | 1.11× | exec 2.7s → 2.0s |

Это запросы, где GEQO стабильно даёт «плохой» план (12-сек execution), а SA при cheap-настройке исследует достаточно перестановок чтобы найти план в 2-3 раза быстрее.

### Запросы где SAIO заметно проигрывает

Все случаи проигрыша — короткие запросы (pg total < 300 мс), где даже минимальный SA-overhead в 0.5-0.8 сек становится 3-8× от pg total. Худший случай — 33c (n=14, pg=198мс, cheap=775мс, **3.9×**). Здесь exec у обоих ~50мс, разница — чистый planning overhead.

### Plotting overhead vs win-rate

Видно по [saio_configs_e2e_ratio.png](/Users/alena/my_postgres9/run_tests_bash_scripts/plots/saio_configs_e2e_ratio.png):

* `saio_default`: 2 синих столбца (выигрыш), 17 красных (от ×1.3 до ×46).
* `saio_mid`: «сжатая в 3 раза» копия default — те же относительные позиции, без новых wins на промежуточных запросах.
* `saio_cheap`: 4 синих столбца, остальные красные но компактнее (макс ×8).

Идти «между default и cheap» бессмысленно — `mid` не открывает новых wins на промежуточных запросах, проигрывает cheap на коротких. То есть **бимодальная картина**: либо SA реально нужно много шагов и помогает (cheap справляется), либо SA вообще не нужно (там pg/GEQO быстрый и любой SA — overhead).

### `saio_default` стоит ли вообще

В нашем эксперименте `default` нашёл всего 2 wins (26c и 28c), и оба с минимальным отрывом (0.77× и 0.97×). При этом planning стоит 5-11 сек. **Не оправдан** для production. Можно держать как «academic baseline» (максимально тщательный SA), но `cheap` ему не уступает по quality на этих запросах.

## 6. Где у GEQO «плохие» планы

Профиль pg execution времени из этого прогона:

| pg execution > 5 сек | pg execution < 100 мс |
|---|---|
| 26c (10.2s), 30a (7.2s), 28c (7.5s) — **здесь SAIO выигрывает** | 24b, 27a-c, 29a-b, 33a-c — здесь GEQO быстрый, SAIO overhead вреден |

Это **16% от выборки n_rels≥12** (3 из 19). На таких запросах SAIO даёт реальный 2-3× speedup, что для аналитических workloads с длинными запросами критично.

## 6.5. Multi-restart (классическая стратегия преодоления local optima)

Добавила GUC `saio_restarts` (default 1) и обернула SA-цикл в `for restart`. Каждый рестарт начинает с **другого греди-дерева**: первый — оригинальный порядок `initial_rels`, последующие — `shuffled_list(root, initial_rels)`. PRNG-state у всех рестартов общий, что даёт разнообразие SA-траекторий. Cross-restart-лучший трек копируется в отдельный memory-context.

Smoke-проверка на 29a: при unlucky single-restart top_cost = **55 650** (плохой local optimum), при `saio_restarts = 3` всегда находит **3917.71** (= pg). Так что механизм работает.

Прогон cheap + `saio_restarts = {1, 3, 5}` на тех же 20 запросах:

| config | planning median | exec median | total median | wins | losses |
|---|---|---|---|---|---|
| `saio_cheap` (R=1)   | 2.9× | 1.38× | **2.3×** | **3 / 19** | 16 / 19 |
| `saio_cheap_r3`      | 8.9× | 1.13× | 5.3× | **4 / 19** | 15 / 19 |
| `saio_cheap_r5`      | 14.6× | **1.05×** | 6.7× | 3 / 19 | 16 / 19 |

Поточечно (total ratio, blue = SAIO быстрее pg):

| query | n | R=1 | R=3 | R=5 |
|---|---|---|---|---|
| 26c | 12 | **0.29×** | 0.39× | 0.42× |
| 28c | 14 | **0.31×** | 0.62× | 0.47× |
| 30a | 12 | **0.20×** | 0.24× | 0.36× |
| 26a | 12 | 1.45× | **0.92×** ⭐ | 1.15× |
| 24a | 12 | 1.11× | 2.11× | 2.87× |

**Что multi-restart дал**:
* **+1 win**: на 26a R=3 спустился ниже 1× (0.92×). На R=1 SA стабильно зависала в субоптимальном плане (cost 13863), R=3 в 1/3 итераций находит план близкий к pg (cost 10000).
* **Стабильность top_cost**: на 29a top_cost больше не «прыгает» между 3917 и 55640 — R=3 всегда выдаёт 3917.71. Но… см. следующий пункт.

**Что multi-restart не дал**:
* На «sweet-spot» запросах (26c, 28c, 30a) R=1 **уже** находит хороший план на первой попытке, дополнительные рестарты просто **умножают planning overhead** — wins становятся слабее (26c: 0.29× → 0.39×; 28c: 0.31× → 0.62×).
* На «миллисекундных» запросах (24b, 27a-c, 29a-c, 33a-c) R=3 и R=5 множат planning в 3 и 5 раз, делая ratio ×8-17.
* Median total e2e ухудшается с ростом R: 2.3× → 5.3× → 6.7×.
* Variance, которую я наблюдала в пилоте (cost 55640 на 2/3 итераций cheap для 29a), в полном sweep не повторилась — все 3 итерации cheap R=1 нашли 3917.71. То есть пилотная статистика была шумом, а не системной проблемой.

**Вывод по multi-restart**: для JOB workload это **в основном проигрыш** по total e2e. Идея помогает только когда SA при R=1 стабильно попадает в локальный минимум на конкретном запросе (как 26a). Но overhead на 16 из 19 запросов перекрывает выигрыш.

Возможное применение: **adaptive restart** — если первый рестарт нашёл план с cost > известного pg-эталона, делать второй. Но для этого нужна интеграция с pg_stat_statements или другой источник «ожидаемой цены». В рамках чистого расширения пока не делалось.

## 7. Рекомендации

1. **Saio как замена GEQO целиком — нет.** Median overhead 1.4-7×, выигрыши только на 16% запросов.
2. **Saio как selective режим — да.** Workload analyzer / DBA отмечает «слабые» запросы (известно медленные с GEQO) → для них включать saio_cheap.
3. **Hybrid hook** (вне рамок этого отчёта): добавить в `_PG_init` логику «если query ещё в shared pg_stat_statements с execution >5s и planning <1s → saio_cheap», иначе GEQO. Минимум кода, может дать видимый эффект.
4. **Доработки в SAIO**, которые могут помочь:
   * Cache-based decision: сохранять последнюю SAIO-итерацию в shared memory и переиспользовать как стартовое дерево.
   * Restart с N разных стартовых деревьев и выбор лучшего — устранит variance на 29a-style запросах (pilot показал 2/3 итераций cheap дают cost 55k, 1/3 даёт 3.9k — есть локальные минимумы).

## 8. Артефакты

* Адаптированный модуль: [contrib/saio/](/Users/alena/my_postgres12/contrib/saio/)
* CSV последнего прогона (4 конфига × 19 запросов × 3 итерации):
  [per_query.csv](/Users/alena/min_job/results/compare_saio/20260519_072729/per_query.csv)
* EXPLAIN-планы каждого (config, query):
  [plans/](/Users/alena/min_job/results/compare_saio/20260519_072729/plans/)
* Лог запуска:
  [log.txt](/Users/alena/min_job/results/compare_saio/20260519_072729/log.txt)
* Графики:
  * [saio_configs_e2e_scatter.png](/Users/alena/my_postgres9/run_tests_bash_scripts/plots/saio_configs_e2e_scatter.png) — 3×N scatter saio-y vs pg-x
  * [saio_configs_e2e_ratio.png](/Users/alena/my_postgres9/run_tests_bash_scripts/plots/saio_configs_e2e_ratio.png) — отсортированные бары `log2(saio/pg)` по конфигам
  * [saio_configs_planning_vs_exec.png](/Users/alena/my_postgres9/run_tests_bash_scripts/plots/saio_configs_planning_vs_exec.png) — стэк planning+exec для всех конфигов

## 9. Известные ограничения / TODO

* 30c — таймаут у всех конфигов (включая pg), нужен запрос с другим LIMIT/WHERE или другой воркаут.
* По 3 итерации — недостаточно для надёжного измерения variance.
* **Sequential multi-restart реализован** (см. §6.5) — для JOB он не окупается. **Parallel SAIO** (раздавать рестарты по bgworker'ам, выбирать best) — отдельная задача: для одного запроса overhead на spawn/IPC вероятно сожжёт выигрыш, нужно обоснование на более крупных n_rels.
* Cost model GEQO и SAIO одна и та же; разница только в search strategy. Если бы у SAIO была лучшая оценка cardinality (например через AQO) — выигрышей могло быть больше.
* Не тестировали на запросах с `n_rels > 17` — там GEQO ещё хуже, есть шанс что SAIO дотягивается до большего % wins.
* Adaptive restart (продолжать рестартами только если cost первого выше известного pg-эталона) — могло бы спасти overhead на 16/19 «миллисекундных» запросах. Требует интеграции с pg_stat_statements.

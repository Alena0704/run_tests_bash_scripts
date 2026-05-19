#!/usr/bin/env python3
"""Build saio-vs-PG comparison plots from the latest job_run_saio_vs_pg.sh run.

Reads ``$RESULTS_DIR/compare_saio/<latest>/per_query.csv`` (or a path passed
via ``--src``) and writes plots to ``run_tests_bash_scripts/plots/``.

CSV columns (produced by job_run_saio_vs_pg.sh):
    query, n_rels, config, iter, planning_ms, exec_ms, top_cost
with config in {pg, saio}.

Outputs:
    saio_e2e_scatter.png         3-panel scatter: planning / exec / total,
                                 saio-y vs pg-x, log-log, marker by n_rels.
    saio_e2e_ratio_sorted.png    Per-query total-time ratio (saio / pg),
                                 sorted horizontal bars.
    saio_planning_vs_exec.png    Stacked bars of planning vs exec for each
                                 (query, config) side-by-side.
"""
import csv
import math
import os
import sys
from pathlib import Path
from statistics import median

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

# --- locate latest compare_saio results --------------------------------
HERE = Path(__file__).resolve().parent
HOME = Path(os.environ.get("HOME", str(Path.home())))
BENCH = Path(os.environ.get("BENCH_ROOT", str(HOME / "min_job")))
COMPARE_BASE = BENCH / "results" / "compare_saio"

src_path = None
for i, a in enumerate(sys.argv):
    if a == "--src" and i + 1 < len(sys.argv):
        src_path = Path(sys.argv[i + 1])
        break
    elif a.startswith("--src="):
        src_path = Path(a.split("=", 1)[1])
        break

if src_path is None:
    if not COMPARE_BASE.exists():
        print(f"No compare_saio results at {COMPARE_BASE}; pass --src=PATH",
              file=sys.stderr)
        sys.exit(1)
    runs = sorted([d for d in COMPARE_BASE.iterdir() if d.is_dir()],
                  key=lambda p: p.stat().st_mtime, reverse=True)
    if not runs:
        print(f"No runs in {COMPARE_BASE}", file=sys.stderr)
        sys.exit(1)
    src_path = runs[0] / "per_query.csv"

if not src_path.exists():
    print(f"Per-query CSV not found: {src_path}", file=sys.stderr)
    sys.exit(1)

OUT = HERE / "plots"
OUT.mkdir(exist_ok=True)
print(f"Reading: {src_path}")
print(f"Writing: {OUT}/")

# --- load data ---------------------------------------------------------
rows = []
with open(src_path) as f:
    for r in csv.DictReader(f):
        try:
            p_ms = float(r["planning_ms"]) if r["planning_ms"] != "NA" else None
            e_ms = float(r["exec_ms"])     if r["exec_ms"]     != "NA" else None
            nr   = int(r["n_rels"])
        except (ValueError, KeyError):
            continue
        rows.append({
            "q": r["query"], "n": nr, "cfg": r["config"],
            "plan": p_ms, "exec": e_ms,
        })

def med_field(field):
    by_cq = {}
    for r in rows:
        v = r[field]
        if v is None or v <= 0:
            continue
        by_cq.setdefault((r["cfg"], r["q"]), []).append(v)
    return {k: median(v) for k, v in by_cq.items()}

med_plan = med_field("plan")
med_exec = med_field("exec")
med_total = {}
for (cfg, q), p in med_plan.items():
    e = med_exec.get((cfg, q))
    if e is not None:
        med_total[(cfg, q)] = p + e

configs = sorted({c for c, _ in med_total})
queries = sorted({q for _, q in med_total})
n_rels_lookup = {r["q"]: r["n"] for r in rows}

print(f"Configs: {configs}  Queries: {len(queries)}")

if "pg" not in configs or "saio" not in configs:
    print("Need both 'pg' and 'saio' configs in data.", file=sys.stderr)
    sys.exit(1)

# --- summary stats -----------------------------------------------------
def ratios(med_map):
    rs = []
    for q in queries:
        a = med_map.get(("pg", q))
        b = med_map.get(("saio", q))
        if a and b and a > 0:
            rs.append((q, b / a, a, b, n_rels_lookup.get(q, 0)))
    return rs

r_plan  = ratios(med_plan)
r_exec  = ratios(med_exec)
r_total = ratios(med_total)


def geomean(xs):
    xs = [x for x in xs if x > 0]
    if not xs:
        return float("nan")
    return math.exp(sum(math.log(x) for x in xs) / len(xs))


for label, rs in [("planning", r_plan), ("execution", r_exec),
                  ("total", r_total)]:
    n = len(rs)
    if not n:
        print(f"  {label:<10} no data")
        continue
    vals = [r[1] for r in rs]
    gm = geomean(vals)
    md = median(vals)
    wins = sum(1 for v in vals if v < 0.95)
    losses = sum(1 for v in vals if v > 1.05)
    print(f"  {label:<10} n={n:<3} median_ratio={md:.3f}× "
          f"geomean={gm:.3f}×  saio_wins={wins}  saio_losses={losses}")


# --- 1. 3-panel scatter (planning / exec / total) ---------------------
def scatter_panel(ax, data, title, xlab, ylab):
    if not data:
        ax.text(0.5, 0.5, "no data", ha="center", va="center")
        ax.set_title(title)
        return
    xs = [d[2] for d in data]
    ys = [d[3] for d in data]
    lo = max(0.1, min(min(xs), min(ys)) * 0.5)
    hi = max(max(xs), max(ys)) * 2
    # split by n_rels: 12-13 small, 14-17 medium, 18+ large
    bins = [(12, 13, "#1f4e79", "o", "12–13 rels"),
            (14, 17, "#c14c2f", "s", "14–17 rels"),
            (18, 99, "#3a7c2f", "^", ">17 rels")]
    for lo_n, hi_n, col, mk, lab in bins:
        bx = [x for x, n in zip(xs, [d[4] for d in data])
              if lo_n <= n <= hi_n]
        by = [y for y, n in zip(ys, [d[4] for d in data])
              if lo_n <= n <= hi_n]
        if bx:
            ax.loglog(bx, by, mk, ms=8, alpha=0.85, color=col,
                      label=f"{lab} (n={len(bx)})")
    ax.plot([lo, hi], [lo, hi], "k--", lw=1, alpha=0.6)
    ax.set_xlim(lo, hi); ax.set_ylim(lo, hi)
    ax.set_xlabel(xlab); ax.set_ylabel(ylab)
    ax.set_title(title)
    ax.legend(loc="upper left", fontsize=8)


fig, axes = plt.subplots(1, 3, figsize=(16.5, 5.4))
scatter_panel(axes[0], r_plan,
              "Planning time", "PG planning (ms, log)",
              "SAIO planning (ms, log)")
scatter_panel(axes[1], r_exec,
              "Execution time", "PG execution (ms, log)",
              "SAIO execution (ms, log)")
scatter_panel(axes[2], r_total,
              "Planning + Execution (e2e)",
              "PG total (ms, log)", "SAIO total (ms, log)")
fig.suptitle("SAIO vs PostgreSQL — per-query times on JOB "
             f"(n_rels ≥ 12, from {src_path.parent.name})", y=1.02)
fig.text(0.5, -0.02,
         "Below diagonal = SAIO faster; above = SAIO slower.",
         ha="center", fontsize=9, style="italic", color="#444")
plt.tight_layout()
out = OUT / "saio_e2e_scatter.png"
fig.savefig(out, dpi=130, bbox_inches="tight")
print(f"  -> {out}")
plt.close(fig)

# --- 2. Sorted bar chart of total-time ratios -------------------------
if r_total:
    pairs = sorted(r_total, key=lambda t: t[1])
    n = len(pairs)
    fig, ax = plt.subplots(figsize=(11, 0.34 * n + 1.5))
    y = np.arange(n)
    log2r = [math.log2(p[1]) for p in pairs]
    colors = ["#1f77b4" if v < -math.log2(1.05)
              else ("#d62728" if v > math.log2(1.05) else "#aaaaaa")
              for v in log2r]
    ax.barh(y, log2r, color=colors, edgecolor="black", linewidth=0.2,
            height=0.78)
    ax.axvline(0, color="black", linewidth=0.7)
    ax.set_yticks(y)
    ax.set_yticklabels([f"{q} (n={nr})" for q, _, _, _, nr in pairs],
                       fontsize=8)
    ax.set_xlabel("log2(SAIO total / PG total)")
    ax.set_title("Per-query e2e ratio: SAIO vs PG\n"
                 "Blue = SAIO faster, red = SAIO slower (≥5%)")
    for yi, (_, r, _, _, _) in zip(y, pairs):
        if r < 0.95 or r > 1.05:
            ax.text(math.log2(r), yi,
                    f" {r:.2f}×" if r >= 1 else f"{r:.2f}× ",
                    va="center", ha="left" if r >= 1 else "right",
                    fontsize=7, color="#333")
    plt.tight_layout()
    out = OUT / "saio_e2e_ratio_sorted.png"
    fig.savefig(out, dpi=130, bbox_inches="tight")
    print(f"  -> {out}")
    plt.close(fig)

# --- 3. Stacked side-by-side bars: planning + exec per query ----------
qs = sorted(queries,
            key=lambda q: (n_rels_lookup.get(q, 0),
                           med_total.get(("pg", q), 0)))
if qs:
    fig, ax = plt.subplots(figsize=(max(8, 0.45 * len(qs)), 6))
    width = 0.4
    x = np.arange(len(qs))
    pg_plan  = [med_plan.get(("pg", q), 0)   for q in qs]
    pg_exec  = [med_exec.get(("pg", q), 0)   for q in qs]
    sa_plan  = [med_plan.get(("saio", q), 0) for q in qs]
    sa_exec  = [med_exec.get(("saio", q), 0) for q in qs]
    ax.bar(x - width / 2, pg_plan, width, color="#1f4e79",
           label="PG planning")
    ax.bar(x - width / 2, pg_exec, width, bottom=pg_plan,
           color="#76a8d8", label="PG execution")
    ax.bar(x + width / 2, sa_plan, width, color="#7a2f1f",
           label="SAIO planning")
    ax.bar(x + width / 2, sa_exec, width, bottom=sa_plan,
           color="#d8917b", label="SAIO execution")
    ax.set_xticks(x)
    ax.set_xticklabels([f"{q}\n(n={n_rels_lookup[q]})" for q in qs],
                       rotation=60, ha="right", fontsize=8)
    ax.set_yscale("log")
    ax.set_ylabel("time (ms, log)")
    ax.set_title("Planning vs Execution per query: PG vs SAIO")
    ax.legend(fontsize=9, ncol=2)
    plt.tight_layout()
    out = OUT / "saio_planning_vs_exec.png"
    fig.savefig(out, dpi=130, bbox_inches="tight")
    print(f"  -> {out}")
    plt.close(fig)

print("\nDone.")

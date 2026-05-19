#!/usr/bin/env python3
"""Build comparison plots from the latest job_compare_methods.sh run.

Reads $RESULTS_DIR/compare/<latest>/per_query.csv (or a path passed via --src)
and writes plots to run_tests_bash_scripts/plots/.

Outputs:
  slide37_worst_best_ratio.png  -- boxplot of per-query (method/pg) ratios
  e2e_scatter_all.png           -- per-query exec scatter, method-y vs pg-x
  e2e_per_query_ratio_sorted.png -- horizontal bars sorted by ratio
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

# --- locate latest compare results --------------------------------------
HERE = Path(__file__).resolve().parent
HOME = Path(os.environ.get("HOME", str(Path.home())))
DEFAULT_BENCH = HOME / "min_job"
BENCH = Path(os.environ.get("BENCH_ROOT", str(DEFAULT_BENCH)))
COMPARE_BASE = BENCH / "results" / "compare"

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
        print(f"No compare results at {COMPARE_BASE}; pass --src=PATH", file=sys.stderr)
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

# --- load data ----------------------------------------------------------
# CSV columns: query, n_rels, config, iter, exec_ms, top_cost
rows = []
with open(src_path) as f:
    for r in csv.DictReader(f):
        try:
            ms = float(r["exec_ms"])
            nr = int(r["n_rels"])
        except (ValueError, KeyError):
            continue
        if ms <= 0:
            continue
        rows.append({"q": r["query"], "n": nr, "cfg": r["config"], "ms": ms})

# per (cfg, q) median exec time
by_cq = {}
for r in rows:
    key = (r["cfg"], r["q"])
    by_cq.setdefault(key, []).append(r["ms"])
med = {k: median(v) for k, v in by_cq.items()}

configs = sorted({c for c, _ in med})
queries = sorted({q for _, q in med})

if "pg" not in configs:
    print(f"WARNING: 'pg' config not in data; configs found: {configs}", file=sys.stderr)
    print("Cannot compute ratios vs pg.  Plotting medians only.", file=sys.stderr)
    pg_med = {}
else:
    pg_med = {q: med[("pg", q)] for q in queries if ("pg", q) in med}

# ratios per config (excluding pg itself)
ratios_per_cfg = {}
for c in configs:
    rs = []
    for q in queries:
        if (c, q) not in med:
            continue
        if q not in pg_med:
            continue
        if pg_med[q] <= 0:
            continue
        rs.append(med[(c, q)] / pg_med[q])
    ratios_per_cfg[c] = rs

print(f"\nConfigs in data: {configs}")
for c in configs:
    n = len(ratios_per_cfg.get(c, []))
    if n:
        med_r = median(ratios_per_cfg[c])
        gm_r = math.exp(sum(math.log(x) for x in ratios_per_cfg[c]) / n)
        print(f"  {c:<12} n={n:<3} median_ratio={med_r:.3f}× geomean_ratio={gm_r:.3f}×")
    else:
        print(f"  {c:<12} n=0 (no comparable queries)")

# Order: pg first, then others by ascending median ratio
order = []
if "pg" in configs:
    order.append("pg")
non_pg = [c for c in configs if c != "pg"]
non_pg_sorted = sorted(non_pg,
                       key=lambda c: median(ratios_per_cfg[c]) if ratios_per_cfg[c] else 99)
order += non_pg_sorted

# --- 1. slide37: per-query latency ratio vs PG (boxplot) ----------------
fig, ax = plt.subplots(figsize=(11, 5.5))
positions = np.arange(len(order))
box_data = []
labels = []
for c in order:
    if c == "pg":
        # PG vs PG = 1.0 by construction; skip from boxplot but draw line.
        continue
    rs = ratios_per_cfg.get(c, [])
    if not rs:
        continue
    box_data.append(rs)
    labels.append(c)

if not box_data:
    print("WARNING: nothing to plot for slide37", file=sys.stderr)
else:
    positions = np.arange(len(labels))
    bp = ax.boxplot(box_data, positions=positions, widths=0.55, patch_artist=True,
                    boxprops=dict(facecolor="#1f4e79", alpha=0.75, edgecolor="black"),
                    medianprops=dict(color="white", lw=2),
                    whiskerprops=dict(color="black"),
                    flierprops=dict(marker="o", ms=3, mfc="#d62728",
                                    mec="#d62728", alpha=0.5))
    # Median labels above each box
    for i, c in enumerate(labels):
        rs = ratios_per_cfg[c]
        med_r = median(rs)
        gm = math.exp(sum(math.log(x) for x in rs) / len(rs))
        ax.text(i, med_r * 1.15, f"med={med_r:.2f}×",
                ha="center", fontsize=9, color="#1f4e79")
        ax.text(i, med_r * 0.85, f"geo={gm:.2f}×",
                ha="center", fontsize=9, color="#444")

    ax.axhline(1.0, color="black", lw=0.8, ls=":", alpha=0.5)
    ax.text(len(labels) - 0.3, 1.05, "1× = no change vs PG",
            fontsize=8, color="#444", ha="right")
    ax.axhline(2.8, color="#a35e00", lw=1, ls="--", alpha=0.6)
    ax.text(len(labels) - 0.3, 2.95, "RPT bound 2.8× (Zhao SIGMOD'25)",
            fontsize=8, color="#a35e00", ha="right")
    ax.axhline(25.0, color="#a00", lw=1, ls="--", alpha=0.6)
    ax.text(len(labels) - 0.3, 26.5, "LQO tail 25× (Lehmann VLDB'24)",
            fontsize=8, color="#a00", ha="right")

    ax.set_yscale("log")
    ax.set_xticks(positions)
    ax.set_xticklabels(labels, fontsize=11)
    ax.set_ylabel("per-query exec-time ratio (method / PG, log scale)")
    ax.set_title("slide37 — per-query latency ratio vs PostgreSQL\n"
                 f"(from {src_path.parent.name})")
    ymax = max(max(rs) for rs in box_data) * 1.5
    ymin = min(min(rs) for rs in box_data) * 0.7
    ax.set_ylim(max(0.05, ymin), max(35, ymax))

    fig.text(0.5, 0.005,
             "Boxes built from per-query medians of ITERS reruns on JOB.  "
             "Box = IQR, whiskers = 1.5×IQR, dots = outliers.",
             ha="center", fontsize=8, style="italic", color="#444")
    plt.tight_layout(rect=[0, 0.04, 1, 0.97])
    out = OUT / "slide37_worst_best_ratio.png"
    fig.savefig(out, dpi=130, bbox_inches="tight")
    print(f"  -> {out}")
plt.close(fig)

# --- 2. e2e scatter: PG-x vs method-y, log-log -------------------------
non_pg_with_data = [c for c in non_pg_sorted if ratios_per_cfg.get(c)]
if non_pg_with_data and pg_med:
    ncols = min(len(non_pg_with_data), 3)
    nrows = (len(non_pg_with_data) + ncols - 1) // ncols
    fig, axes = plt.subplots(nrows, ncols, figsize=(5.4 * ncols, 5.0 * nrows),
                             squeeze=False)
    # global ranges
    all_vals = list(pg_med.values())
    for c in non_pg_with_data:
        for q in queries:
            if (c, q) in med:
                all_vals.append(med[(c, q)])
    lo = max(1.0, min(all_vals) * 0.5)
    hi = max(all_vals) * 2

    n_rels_lookup = {}
    for r in rows:
        n_rels_lookup[r["q"]] = r["n"]
    GEQO_TH = 12

    for i, c in enumerate(non_pg_with_data):
        ax = axes[i // ncols][i % ncols]
        xs_s, ys_s, xs_l, ys_l = [], [], [], []
        for q in queries:
            if q not in pg_med or (c, q) not in med:
                continue
            x, y = pg_med[q], med[(c, q)]
            n = n_rels_lookup.get(q, 0)
            (xs_s if n < GEQO_TH else xs_l).append(x)
            (ys_s if n < GEQO_TH else ys_l).append(y)
        ax.loglog(xs_s, ys_s, "o", ms=6, alpha=0.7, color="#1f4e79",
                  label=f"n < {GEQO_TH} (DP, n={len(xs_s)})")
        ax.loglog(xs_l, ys_l, "s", ms=8, alpha=0.9, color="#c14c2f",
                  label=f"n ≥ {GEQO_TH} (GEQO, n={len(xs_l)})")
        ax.plot([lo, hi], [lo, hi], "k--", lw=1, alpha=0.6)
        ax.set_xlim(lo, hi); ax.set_ylim(lo, hi)
        ax.set_xlabel("PG e2e (ms, log)")
        ax.set_ylabel(f"{c} e2e (ms, log)")
        ax.set_title(f"{c} vs pg")
        ax.legend(loc="upper left", fontsize=8)

    for j in range(len(non_pg_with_data), nrows * ncols):
        axes[j // ncols][j % ncols].axis("off")

    fig.suptitle("Per-query exec-time scatter: each method vs PG  "
                 f"(from {src_path.parent.name})", y=0.995)
    fig.text(0.5, 0.005,
             "Below diagonal = method faster than PG on that query; above = slower.",
             ha="center", fontsize=8, style="italic", color="#444")
    plt.tight_layout(rect=[0, 0.02, 1, 0.97])
    out = OUT / "e2e_scatter_all.png"
    fig.savefig(out, dpi=130, bbox_inches="tight")
    print(f"  -> {out}")
    plt.close(fig)

# --- 3. per-query ratio sorted horizontal bars (for `mcts` specifically) -
target_cfg = "mcts" if "mcts" in non_pg_with_data else (non_pg_with_data[0] if non_pg_with_data else None)
if target_cfg and pg_med:
    pairs = []
    for q in queries:
        if q not in pg_med or (target_cfg, q) not in med:
            continue
        pairs.append((q, med[(target_cfg, q)] / pg_med[q]))
    pairs.sort(key=lambda t: t[1])
    n = len(pairs)
    fig, ax = plt.subplots(figsize=(11, 0.18 * n + 1.5))
    y = np.arange(n)
    log2r = [math.log2(r) for _, r in pairs]
    colors = ["#1f77b4" if r < -math.log2(1.05) else ("#d62728" if r > math.log2(1.05) else "#aaaaaa")
              for r in log2r]
    ax.barh(y, log2r, color=colors, edgecolor="black", linewidth=0.2, height=0.85)
    ax.axvline(0, color="black", linewidth=0.7)
    ax.set_yticks(y)
    ax.set_yticklabels([f"{q}" for q, _ in pairs], fontsize=7)
    ax.set_xlabel("log2(method / PG)")
    ax.set_title(f"Per-query exec-time ratio {target_cfg} vs PG\n"
                 "Blue = MCTS faster, red = MCTS slower (≥5%)")
    for yi, (q, r) in zip(y, pairs):
        if r < 0.95 or r > 1.05:
            ax.text(math.log2(r), yi,
                    f" {r:.2f}×" if r >= 1 else f"{r:.2f}× ",
                    va="center", ha="left" if r >= 1 else "right",
                    fontsize=6.5, color="#333")
    out = OUT / "e2e_per_query_ratio_sorted.png"
    fig.savefig(out, dpi=130, bbox_inches="tight")
    print(f"  -> {out}")
    plt.close(fig)

print("\nDone.")

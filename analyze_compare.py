#!/usr/bin/env python3
"""Analyse compare results and quantify MCTS's dependence on cardinality
accuracy versus PG's.

Reads $RESULTS_DIR/compare/<latest>/per_query.csv (or --src=PATH) and answers:

  1. Does AQO help PG?           (pg_aqo / pg)
  2. Does AQO help MCTS?         (mcts_aqo / mcts)
  3. Who benefits more — PG or MCTS?
       improvement_factor = (pg_aqo/pg) / (mcts_aqo/mcts)
       > 1.0  -> AQO helps MCTS MORE than PG (= MCTS is more cardinality-hungry)
       < 1.0  -> AQO helps PG more

Also writes plots:
  plots/slide37_worst_best_ratio.png   -- boxplot ratios vs pg
  plots/e2e_scatter_all.png            -- pg vs each config scatter
  plots/aqo_improvement.png            -- delta from AQO per method, by n_rels
"""
import csv, math, os, sys
from collections import defaultdict
from pathlib import Path
from statistics import median, mean

HERE = Path(__file__).resolve().parent
HOME = Path(os.environ.get("HOME", str(Path.home())))
BENCH = Path(os.environ.get("BENCH_ROOT", str(HOME / "min_job")))
COMPARE_BASE = BENCH / "results" / "compare"
OUT = HERE / "plots"
OUT.mkdir(exist_ok=True)

# --- locate latest compare results --------------------------------------
src_path = None
for i, a in enumerate(sys.argv):
    if a.startswith("--src="):
        src_path = Path(a.split("=", 1)[1])
    elif a == "--src" and i + 1 < len(sys.argv):
        src_path = Path(sys.argv[i + 1])

if src_path is None:
    runs = sorted([d for d in COMPARE_BASE.iterdir() if d.is_dir()],
                  key=lambda p: p.stat().st_mtime, reverse=True)
    if not runs:
        sys.exit(f"No compare runs in {COMPARE_BASE}")
    src_path = runs[0] / "per_query.csv"

print(f"Source: {src_path}")
if not src_path.exists():
    sys.exit(f"Missing: {src_path}")

# --- load ----------------------------------------------------------------
rows = []
with open(src_path) as f:
    for r in csv.DictReader(f):
        try:
            rows.append({"q": r["query"],
                         "n": int(r["n_rels"]),
                         "cfg": r["config"],
                         "ms": float(r["exec_ms"]) if r["exec_ms"] != "NA" else None})
        except Exception:
            continue

# per (cfg, q) median exec
by_cq = defaultdict(list)
for r in rows:
    if r["ms"] and r["ms"] > 0:
        by_cq[(r["cfg"], r["q"])].append(r["ms"])
med = {k: median(v) for k, v in by_cq.items()}

cfgs = sorted({c for c, _ in med})
qs   = sorted({q for _, q in med})
nrel = {r["q"]: r["n"] for r in rows}

print(f"\nConfigs found: {cfgs}")
print(f"Queries: {len(qs)}")

# Map legacy names -> normalised
ALIAS = {"dp": "pg", "dp_aqo": "pg_aqo"}
def norm(c): return ALIAS.get(c, c)

med_norm = {}
for (c, q), v in med.items():
    med_norm[(norm(c), q)] = v
cfgs_norm = sorted({c for c, _ in med_norm})
print(f"Normalised:    {cfgs_norm}")

# --- helpers -------------------------------------------------------------
def geomean(xs):
    xs = [x for x in xs if x and x > 0]
    return math.exp(sum(math.log(x) for x in xs) / len(xs)) if xs else float("nan")

def ratios(a, b, sub=None):
    """ratios med_norm[(a,q)] / med_norm[(b,q)] over queries (optionally restricted to sub)"""
    out = []
    for q in (sub if sub is not None else qs):
        if (a, q) in med_norm and (b, q) in med_norm:
            x, y = med_norm[(a, q)], med_norm[(b, q)]
            if x > 0 and y > 0:
                out.append(x / y)
    return out

# --- key tables ----------------------------------------------------------
print("\n" + "=" * 72)
print("PER-CONFIG GEOMEAN EXEC TIME (ms)")
print("=" * 72)
for c in cfgs_norm:
    vals = [med_norm[(c, q)] for q in qs if (c, q) in med_norm]
    if vals:
        print(f"  {c:<10}  n={len(vals):<3}  geomean={geomean(vals):.2f} ms  median={median(vals):.2f} ms")

print("\n" + "=" * 72)
print("RATIO vs pg (geomean of per-query ratios; <1 = faster than PG)")
print("=" * 72)
for c in cfgs_norm:
    if c == "pg":
        continue
    rs = ratios(c, "pg")
    if rs:
        gm = geomean(rs)
        md = median(rs)
        wins = sum(1 for r in rs if r < 0.95)
        losses = sum(1 for r in rs if r > 1.05)
        print(f"  {c:<10}  geo={gm:.3f}×  median={md:.3f}×  wins={wins:<3}  losses={losses}")

# --- THE QUESTION: how much does AQO help each method? -----------------
print("\n" + "=" * 72)
print("AQO HELPING EACH METHOD")
print("=" * 72)

def aqo_effect(method):
    """For a given method M, compute geomean of (M_aqo / M) over queries
    where BOTH timings exist."""
    rs = ratios(f"{method}_aqo", method)
    if not rs:
        return None, None, None, None
    gm = geomean(rs)
    md = median(rs)
    wins = sum(1 for r in rs if r < 0.95)
    losses = sum(1 for r in rs if r > 1.05)
    return gm, md, wins, losses

for method in ("pg", "mcts"):
    if all((f"{method}_aqo" in cfgs_norm, method in cfgs_norm)):
        gm, md, w, l = aqo_effect(method)
        if gm is None:
            continue
        impact = (1 - gm) * 100
        print(f"  {method:<5}_aqo / {method:<5} : "
              f"geo={gm:.3f}×  median={md:.3f}×  wins={w}  losses={l}  "
              f"=> AQO {'speeds up' if gm<1 else 'slows down'} {method} by {abs(impact):.1f}%")

print()
gm_pg, *_ = aqo_effect("pg") if all(c in cfgs_norm for c in ["pg", "pg_aqo"]) else (None,)*4
gm_mcts, *_ = aqo_effect("mcts") if all(c in cfgs_norm for c in ["mcts", "mcts_aqo"]) else (None,)*4

if gm_pg is not None and gm_mcts is not None:
    factor = gm_pg / gm_mcts
    print(f"  improvement_factor = (pg_aqo/pg) / (mcts_aqo/mcts) = "
          f"{gm_pg:.3f} / {gm_mcts:.3f} = {factor:.3f}")
    print()
    if factor > 1.05:
        print(f"  >>> MCTS benefits MORE from accurate cardinalities than PG <<<")
        print(f"      (AQO speeds up MCTS by ~{(1-gm_mcts)*100:.1f}% but PG by only ~{(1-gm_pg)*100:.1f}%)")
        print(f"      => MCTS is more cardinality-hungry: it leverages better estimates.")
    elif factor < 0.95:
        print(f"  >>> MCTS benefits LESS from accurate cardinalities than PG <<<")
        print(f"      (AQO speeds up PG by ~{(1-gm_pg)*100:.1f}% but MCTS by only ~{(1-gm_mcts)*100:.1f}%)")
        print(f"      => MCTS already finds good plans without precise estimates.")
    else:
        print(f"  >>> AQO has roughly equal effect on PG and MCTS <<<")
        print(f"      Plan quality of both improves by ~{(1-gm_pg)*100:.1f}% / ~{(1-gm_mcts)*100:.1f}%")

# Decompose by n_rels bucket — small queries (DP territory) vs big (GEQO territory)
print("\n" + "=" * 72)
print("BREAKDOWN BY QUERY SIZE (n_rels)")
print("=" * 72)
buckets = [("small (n<7)", lambda n: n < 7),
           ("med (7-11)", lambda n: 7 <= n <= 11),
           ("big (n>=12)", lambda n: n >= 12)]
for label, pred in buckets:
    sub = [q for q in qs if pred(nrel.get(q, 0))]
    print(f"\n  {label}  (n={len(sub)} queries)")
    for c in cfgs_norm:
        if c == "pg" or "aqo" in c:
            continue
        rs1 = ratios(c, "pg", sub=sub)
        rs2 = ratios(f"{c}_aqo", "pg", sub=sub) if f"{c}_aqo" in cfgs_norm else []
        rs_self = ratios(f"{c}_aqo", c, sub=sub) if f"{c}_aqo" in cfgs_norm else []
        if rs1:
            print(f"    {c}/pg              geo={geomean(rs1):.3f}× (n={len(rs1)})")
        if rs2:
            print(f"    {c}_aqo/pg          geo={geomean(rs2):.3f}× (n={len(rs2)})")
        if rs_self:
            print(f"    {c}_aqo/{c} (AQO help) geo={geomean(rs_self):.3f}× (n={len(rs_self)})")

# --- plots --------------------------------------------------------------
try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import numpy as np

    plt.rcParams.update({"savefig.dpi": 130, "savefig.bbox": "tight"})

    # 1. slide37: ratios vs pg
    non_pg = [c for c in cfgs_norm if c != "pg"]
    non_pg.sort(key=lambda c: median(ratios(c, "pg")) if ratios(c, "pg") else 999)
    box_data, labels = [], []
    for c in non_pg:
        rs = ratios(c, "pg")
        if rs:
            box_data.append(rs); labels.append(c)
    if box_data:
        fig, ax = plt.subplots(figsize=(10, 5.5))
        bp = ax.boxplot(box_data, positions=range(len(labels)), widths=0.55,
                        patch_artist=True,
                        boxprops=dict(facecolor="#1f4e79", alpha=0.75),
                        medianprops=dict(color="white", lw=2),
                        flierprops=dict(marker="o", ms=3, mfc="#d62728",
                                        mec="#d62728", alpha=0.5))
        for i, c in enumerate(labels):
            rs = ratios(c, "pg")
            md = median(rs); gm = geomean(rs)
            ax.text(i, md * 1.18, f"med={md:.2f}×", ha="center", fontsize=9, color="#1f4e79")
            ax.text(i, md * 0.85, f"geo={gm:.2f}×", ha="center", fontsize=9, color="#444")
        ax.axhline(1.0, color="black", lw=0.8, ls=":", alpha=0.5)
        ax.text(len(labels) - 0.3, 1.05, "1× = no change vs PG",
                fontsize=8, color="#444", ha="right")
        ax.set_yscale("log")
        ax.set_xticks(range(len(labels))); ax.set_xticklabels(labels, fontsize=11)
        ax.set_ylabel("per-query exec-time ratio (method / PG, log)")
        ax.set_title(f"Per-query latency ratio vs PG  (from {src_path.parent.name})")
        fig.savefig(OUT / "slide37_worst_best_ratio.png")
        plt.close(fig)
        print(f"\nPlot: {OUT/'slide37_worst_best_ratio.png'}")

    # 2. AQO improvement plot: pg_aqo/pg vs mcts_aqo/mcts per query (scatter)
    if all(c in cfgs_norm for c in ["pg", "pg_aqo", "mcts", "mcts_aqo"]):
        xs, ys, ns = [], [], []
        for q in qs:
            keys = [("pg", q), ("pg_aqo", q), ("mcts", q), ("mcts_aqo", q)]
            if not all(k in med_norm for k in keys):
                continue
            pg, pa = med_norm[("pg", q)], med_norm[("pg_aqo", q)]
            mc, ma = med_norm[("mcts", q)], med_norm[("mcts_aqo", q)]
            xs.append(pa / pg)
            ys.append(ma / mc)
            ns.append(nrel.get(q, 0))
        if xs:
            fig, ax = plt.subplots(figsize=(7, 6.5))
            colors = ["#1f77b4" if n < 12 else "#d62728" for n in ns]
            ax.scatter(xs, ys, s=60, c=colors, alpha=0.65, edgecolor="black", linewidth=0.4)
            lo = min(xs + ys) * 0.7; hi = max(xs + ys) * 1.4
            ax.plot([lo, hi], [lo, hi], "k--", lw=1, alpha=0.5, label="equal effect")
            ax.axvline(1, color="grey", lw=0.5); ax.axhline(1, color="grey", lw=0.5)
            ax.set_xscale("log"); ax.set_yscale("log")
            ax.set_xlim(lo, hi); ax.set_ylim(lo, hi)
            ax.set_xlabel("pg_aqo / pg   (lower = AQO helps PG more)")
            ax.set_ylabel("mcts_aqo / mcts   (lower = AQO helps MCTS more)")
            ax.set_title("AQO benefit per query: does MCTS benefit more than PG?\n"
                         "Below diagonal -> MCTS gains more from accurate cardinality")
            from matplotlib.patches import Patch
            ax.legend(handles=[Patch(color="#1f77b4", label="n<12 (DP terrain)"),
                               Patch(color="#d62728", label="n≥12 (GEQO terrain)")],
                      loc="upper left")
            fig.savefig(OUT / "aqo_improvement.png")
            plt.close(fig)
            print(f"Plot: {OUT/'aqo_improvement.png'}")

    # 3. Scatter PG vs each method
    if non_pg:
        ncols = min(len(non_pg), 3)
        nrows = (len(non_pg) + ncols - 1) // ncols
        fig, axes = plt.subplots(nrows, ncols, figsize=(5 * ncols, 5 * nrows), squeeze=False)
        pg_med = {q: med_norm[("pg", q)] for q in qs if ("pg", q) in med_norm}
        all_vals = list(pg_med.values())
        for c in non_pg:
            all_vals += [med_norm[(c, q)] for q in qs if (c, q) in med_norm]
        lo = max(1.0, min(all_vals) * 0.5); hi = max(all_vals) * 2
        for i, c in enumerate(non_pg):
            ax = axes[i // ncols][i % ncols]
            xs_s = []; ys_s = []; xs_l = []; ys_l = []
            for q in qs:
                if q not in pg_med or (c, q) not in med_norm:
                    continue
                n = nrel.get(q, 0)
                x = pg_med[q]; y = med_norm[(c, q)]
                if n < 12: xs_s.append(x); ys_s.append(y)
                else: xs_l.append(x); ys_l.append(y)
            ax.loglog(xs_s, ys_s, "o", ms=6, alpha=0.7, color="#1f4e79",
                      label=f"n<12 ({len(xs_s)})")
            ax.loglog(xs_l, ys_l, "s", ms=8, alpha=0.85, color="#c14c2f",
                      label=f"n≥12 ({len(xs_l)})")
            ax.plot([lo, hi], [lo, hi], "k--", lw=1, alpha=0.5)
            ax.set_xlim(lo, hi); ax.set_ylim(lo, hi)
            ax.set_xlabel("pg e2e (ms, log)")
            ax.set_ylabel(f"{c} e2e (ms, log)")
            ax.set_title(f"{c} vs pg")
            ax.legend(loc="upper left", fontsize=8)
        for j in range(len(non_pg), nrows * ncols):
            axes[j // ncols][j % ncols].axis("off")
        fig.savefig(OUT / "e2e_scatter_all.png")
        plt.close(fig)
        print(f"Plot: {OUT/'e2e_scatter_all.png'}")
except ImportError:
    print("\nmatplotlib not available — install: pip3 install matplotlib")

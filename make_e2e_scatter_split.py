#!/usr/bin/env python3
"""Per-algorithm e2e scatter plots — one PNG per method.

Reads plot_data/all_methods.csv (wide format: pg + per-method e2e columns) and
writes plots/e2e_scatter_<method>.png for each algorithm, replicating the
styling of the combined plots/e2e_scatter_all.png grid.
"""
import csv
import math
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

COLOR_ORANGE = (252/255, 198/255, 157/255)
COLOR_BLUE = (42/255, 159/255, 255/255)
plt.rcParams.update({
    "font.size": 14,
    "axes.titlesize": 16,
    "axes.labelsize": 16,
    "xtick.labelsize": 14,
    "ytick.labelsize": 14,
    "legend.fontsize": 14,
    "figure.titlesize": 16,
})

HERE = Path(__file__).resolve().parent
SRC = HERE / "plot_data" / "all_methods.csv"
OUT = HERE / "plots"
OUT.mkdir(exist_ok=True)

METHODS = [
    ("hq",      "HyperQO"),
    ("alpha",   "Alphajoin"),
    ("bao",     "Bao"),
    ("neo",     "Neo"),
    ("skinner", "SkinnerDB"),
    ("mcts",    "MCTS-Extreme (best config)"),
]
GEQO_TH = 12

if not SRC.exists():
    print(f"missing source CSV: {SRC}", file=sys.stderr)
    sys.exit(1)

rows = []
with open(SRC) as f:
    for r in csv.DictReader(f):
        try:
            n = int(r["n_rel"])
            pg = float(r["pg_e2e_ms"])
        except (ValueError, KeyError):
            continue
        if pg <= 0:
            continue
        rec = {"q": r["query"], "n": n, "pg": pg}
        for key, _ in METHODS:
            v = r.get(f"{key}_e2e_ms", "")
            try:
                fv = float(v)
                rec[key] = fv if fv > 0 else None
            except ValueError:
                rec[key] = None
        rows.append(rec)

if not rows:
    print("no usable rows", file=sys.stderr)
    sys.exit(1)

all_pg = [r["pg"] for r in rows]
all_method_vals = [r[k] for r in rows for k, _ in METHODS if r.get(k) is not None]
lo = max(1.0, min(all_pg + all_method_vals) * 0.5)
hi = max(all_pg + all_method_vals) * 2

for key, label in METHODS:
    xs_s, ys_s, xs_l, ys_l = [], [], [], []
    for r in rows:
        y = r.get(key)
        if y is None:
            continue
        x = r["pg"]
        (xs_s if r["n"] < GEQO_TH else xs_l).append(x)
        (ys_s if r["n"] < GEQO_TH else ys_l).append(y)

    if not (xs_s or xs_l):
        print(f"  skip {key}: no data")
        continue

    fig, ax = plt.subplots(figsize=(6.0, 5.6))
    ax.loglog(xs_s, ys_s, "o", ms=6, alpha=0.8, color=COLOR_BLUE,
              label=f"n < {GEQO_TH} (DP, n={len(xs_s)})")
    ax.loglog(xs_l, ys_l, "s", ms=8, alpha=0.9, color=COLOR_ORANGE,
              label=f"n ≥ {GEQO_TH} (GEQO, n={len(xs_l)})")
    ax.plot([lo, hi], [lo, hi], "k--", lw=1, alpha=0.6)
    ax.set_xlim(lo, hi); ax.set_ylim(lo, hi)
    ax.set_xlabel("PG e2e (ms, log)")
    ax.set_ylabel(f"{label} e2e (ms, log)")
    ax.set_title(f"{label} vs PG")
    ax.legend(loc="upper left", fontsize=14)
    fig.text(0.5, 0.005,
             "Below diagonal = method faster than PG; above = slower.",
             ha="center", fontsize=14, style="italic", color="#444")
    plt.tight_layout(rect=[0, 0.03, 1, 0.97])
    out = OUT / f"e2e_scatter_{key}.png"
    fig.savefig(out, dpi=130, bbox_inches="tight")
    plt.close(fig)
    print(f"  -> {out}")

print("Done.")

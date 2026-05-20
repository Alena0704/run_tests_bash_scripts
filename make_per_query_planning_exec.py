#!/usr/bin/env python3
"""Per-query planning-vs-execution plots: one PNG per JOB query.

Reads $RESULTS_DIR/compare_saio/<latest>/per_query.csv (or --src=PATH) and
writes one stacked-bar plot per query to plots/per_query/<query>.png.

Each plot shows one stacked bar per config (PG + every non-pg config in
the run, e.g. saio / saio_cheap / saio_cheap_r3) with planning_ms (bottom)
and exec_ms (top), on a log y-axis.

By default only queries with n_rels >= MIN_N are emitted (default 12,
matching saio_planning_vs_exec.png).  Pass --min-n=0 to plot all queries,
or --queries=10a,11b,... to restrict.
"""
import csv
import os
import sys
from pathlib import Path
from statistics import median

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

COLOR_ORANGE = (252/255, 198/255, 157/255)
COLOR_BLUE = (42/255, 159/255, 255/255)


def _shade(base, factor):
    return tuple(c * (1 - factor) for c in base)


def _lighten(base, factor):
    return tuple(c + (1 - c) * factor for c in base)


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
HOME = Path(os.environ.get("HOME", str(Path.home())))
BENCH = Path(os.environ.get("BENCH_ROOT", str(HOME / "min_job")))
COMPARE_BASE = BENCH / "results" / "compare_saio"

src_path = None
min_n = 12
restrict = None
for i, a in enumerate(sys.argv):
    if a == "--src" and i + 1 < len(sys.argv):
        src_path = Path(sys.argv[i + 1])
    elif a.startswith("--src="):
        src_path = Path(a.split("=", 1)[1])
    elif a.startswith("--min-n="):
        min_n = int(a.split("=", 1)[1])
    elif a.startswith("--queries="):
        restrict = set(a.split("=", 1)[1].split(","))

if src_path is None:
    runs = sorted([d for d in COMPARE_BASE.iterdir() if d.is_dir()],
                  key=lambda p: p.stat().st_mtime, reverse=True)
    if not runs:
        print(f"No runs in {COMPARE_BASE}", file=sys.stderr)
        sys.exit(1)
    src_path = runs[0] / "per_query.csv"

if not src_path.exists():
    print(f"per-query CSV not found: {src_path}", file=sys.stderr)
    sys.exit(1)

OUT = HERE / "plots" / "per_query"
OUT.mkdir(parents=True, exist_ok=True)
print(f"Reading: {src_path}")
print(f"Writing: {OUT}/   (min_n={min_n})")

rows = []
with open(src_path) as f:
    for r in csv.DictReader(f):
        try:
            p = float(r["planning_ms"]) if r["planning_ms"] != "NA" else None
            e = float(r["exec_ms"])     if r["exec_ms"]     != "NA" else None
            n = int(r["n_rels"])
        except (ValueError, KeyError):
            continue
        rows.append({"q": r["query"], "n": n, "cfg": r["config"],
                     "plan": p, "exec": e})

def med_for(field, q, cfg):
    vs = [r[field] for r in rows
          if r["q"] == q and r["cfg"] == cfg
          and r[field] is not None and r[field] > 0]
    return median(vs) if vs else 0.0

queries = sorted({r["q"] for r in rows})
n_rels_lookup = {r["q"]: r["n"] for r in rows}
configs = sorted({r["cfg"] for r in rows})
if "pg" not in configs:
    print(f"need pg config; got {configs}", file=sys.stderr)
    sys.exit(1)
non_pg = [c for c in configs if c != "pg"]
if not non_pg:
    print("no non-pg config to compare against", file=sys.stderr)
    sys.exit(1)
ordered_cfgs = ["pg"] + non_pg
print(f"Configs: {ordered_cfgs}")

# colour palette for each (cfg, role) — dark = planning, light = execution
# PG: blue · other configs: shades of orange.
PALETTE = [
    (COLOR_BLUE,                       _lighten(COLOR_BLUE, 0.5)),   # pg
    (_shade(COLOR_ORANGE, 0.35),       COLOR_ORANGE),                 # saio / first non-pg
    (_shade(COLOR_ORANGE, 0.55),       _lighten(COLOR_ORANGE, 0.25)),
    (_shade(COLOR_ORANGE, 0.20),       _lighten(COLOR_ORANGE, 0.45)),
    (_shade(COLOR_ORANGE, 0.70),       _lighten(COLOR_ORANGE, 0.10)),
]

queries = [q for q in queries if n_rels_lookup.get(q, 0) >= min_n]
if restrict is not None:
    queries = [q for q in queries if q in restrict]

if not queries:
    print("no queries to plot after filtering", file=sys.stderr)
    sys.exit(0)

count = 0
for q in queries:
    vals = []
    for cfg in ordered_cfgs:
        p = med_for("plan", q, cfg)
        e = med_for("exec", q, cfg)
        vals.append((p, e))
    if not any(p + e for p, e in vals):
        continue

    fig, ax = plt.subplots(figsize=(max(4.0, 1.2 * len(ordered_cfgs) + 2),
                                    4.6))
    x = np.arange(len(ordered_cfgs))
    width = 0.6
    plan_vals = [v[0] for v in vals]
    exec_vals = [v[1] for v in vals]
    plan_colors = [PALETTE[i % len(PALETTE)][0]
                   for i in range(len(ordered_cfgs))]
    exec_colors = [PALETTE[i % len(PALETTE)][1]
                   for i in range(len(ordered_cfgs))]
    ax.bar(x, plan_vals, width, color=plan_colors)
    ax.bar(x, exec_vals, width, bottom=plan_vals, color=exec_colors)

    pg_total = sum(vals[0])
    for xi, (p, e) in zip(x, vals):
        total = p + e
        if total > 0:
            ax.text(xi, total * 1.05, f"{total:,.0f} ms",
                    ha="center", fontsize=14, color="#222")

    ax.set_xticks(x)
    ax.set_xticklabels(ordered_cfgs, fontsize=14, rotation=20, ha="right")
    ax.set_yscale("log")
    ax.set_ylabel("time (ms, log)")
    ymax = max(p + e for p, e in vals) * 3
    ax.set_ylim(1, max(10, ymax))

    sub = []
    if pg_total > 0:
        for cfg, (p, e) in zip(ordered_cfgs[1:], vals[1:]):
            sub.append(f"{cfg}/pg={((p+e)/pg_total):.2f}×")
    ax.set_title(f"{q}  (n_rels={n_rels_lookup[q]})\n" + "  ".join(sub),
                 fontsize=16)

    handles, labels = [], []
    for i, cfg in enumerate(ordered_cfgs):
        dark, light = PALETTE[i % len(PALETTE)]
        handles.append(plt.Rectangle((0, 0), 1, 1, color=dark))
        labels.append(f"{cfg} planning")
        handles.append(plt.Rectangle((0, 0), 1, 1, color=light))
        labels.append(f"{cfg} execution")
    ax.legend(handles, labels, fontsize=14, loc="upper left", ncol=1)
    plt.tight_layout()
    out = OUT / f"{q}.png"
    fig.savefig(out, dpi=120, bbox_inches="tight")
    plt.close(fig)
    count += 1

print(f"Wrote {count} per-query plots to {OUT}/")

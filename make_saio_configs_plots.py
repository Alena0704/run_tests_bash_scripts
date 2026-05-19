#!/usr/bin/env python3
"""SAIO multi-config plots.

Reads ``$RESULTS_DIR/compare_saio/<latest>/per_query.csv`` produced by
``job_run_saio_configs.sh`` and writes plots comparing every non-pg config
against the ``pg`` baseline.

Inputs CSV columns:
    query, n_rels, config, iter, planning_ms, exec_ms, top_cost

Outputs (in ``run_tests_bash_scripts/plots/``):
    saio_configs_e2e_scatter.png   3-panel × N-config scatter: planning,
                                   execution, total, log-log vs pg.
    saio_configs_e2e_ratio.png     Per-query e2e ratio bars per non-pg config.
    saio_configs_planning_vs_exec.png  Stacked side-by-side bars for every
                                   (query, config).
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

HERE = Path(__file__).resolve().parent
HOME = Path(os.environ.get("HOME", str(Path.home())))
BENCH = Path(os.environ.get("BENCH_ROOT", str(HOME / "min_job")))
COMPARE_BASE = BENCH / "results" / "compare_saio"

src_path = None
for i, a in enumerate(sys.argv):
    if a == "--src" and i + 1 < len(sys.argv):
        src_path = Path(sys.argv[i + 1]); break
    elif a.startswith("--src="):
        src_path = Path(a.split("=", 1)[1]); break

if src_path is None:
    if not COMPARE_BASE.exists():
        print(f"No compare_saio results at {COMPARE_BASE}", file=sys.stderr)
        sys.exit(1)
    runs = sorted([d for d in COMPARE_BASE.iterdir() if d.is_dir()],
                  key=lambda p: p.stat().st_mtime, reverse=True)
    src_path = runs[0] / "per_query.csv"

if not src_path.exists():
    print(f"Per-query CSV not found: {src_path}", file=sys.stderr)
    sys.exit(1)

OUT = HERE / "plots"
OUT.mkdir(exist_ok=True)
print(f"Reading: {src_path}")
print(f"Writing: {OUT}/")

# --- load -----------------------------------------------------------------
rows = []
with open(src_path) as f:
    for r in csv.DictReader(f):
        try:
            p_ms = float(r["planning_ms"]) if r["planning_ms"] != "NA" else None
            e_ms = float(r["exec_ms"])     if r["exec_ms"]     != "NA" else None
            nr   = int(r["n_rels"])
        except (ValueError, KeyError):
            continue
        rows.append({"q": r["query"], "n": nr, "cfg": r["config"],
                     "plan": p_ms, "exec": e_ms})

def med_field(field):
    by_cq = {}
    for r in rows:
        v = r[field]
        if v is None or v <= 0:
            continue
        by_cq.setdefault((r["cfg"], r["q"]), []).append(v)
    return {k: median(v) for k, v in by_cq.items()}

med_plan  = med_field("plan")
med_exec  = med_field("exec")
med_total = {k: med_plan[k] + med_exec[k]
             for k in med_plan if k in med_exec}

queries   = sorted({q for _, q in med_total})
configs   = sorted({c for c, _ in med_total})
non_pg    = [c for c in configs if c != "pg"]
n_lookup  = {r["q"]: r["n"] for r in rows}

if "pg" not in configs:
    print("Need 'pg' in data", file=sys.stderr); sys.exit(1)

print(f"Configs: {configs}  Queries: {len(queries)}")


def geomean(xs):
    xs = [x for x in xs if x > 0]
    if not xs: return float("nan")
    return math.exp(sum(math.log(x) for x in xs) / len(xs))


def ratios(med_map, cfg):
    rs = []
    for q in queries:
        a = med_map.get(("pg", q))
        b = med_map.get((cfg, q))
        if a and b and a > 0:
            rs.append((q, b / a, a, b, n_lookup.get(q, 0)))
    return rs


print()
for cfg in non_pg:
    print(f"  === {cfg} vs pg ===")
    for lbl, m in [("planning", med_plan), ("execution", med_exec),
                   ("total",    med_total)]:
        rs = ratios(m, cfg)
        n = len(rs)
        if not n: continue
        vals = [r[1] for r in rs]
        wins   = sum(1 for v in vals if v < 0.95)
        losses = sum(1 for v in vals if v > 1.05)
        print(f"    {lbl:<10} n={n:<2} median={median(vals):.2f}× "
              f"geomean={geomean(vals):.2f}×  wins={wins} losses={losses}")

# --- Plot 1: scatter --------------------------------------------------------
ncols = len(non_pg)
fig, axes = plt.subplots(3, ncols, figsize=(5.4 * ncols, 13.5),
                         squeeze=False)

def scatter_panel(ax, data, title, xlab, ylab):
    if not data:
        ax.text(0.5, 0.5, "no data", ha="center", va="center")
        ax.set_title(title); return
    xs, ys, ns = [d[2] for d in data], [d[3] for d in data], [d[4] for d in data]
    lo = max(0.1, min(min(xs), min(ys)) * 0.5)
    hi = max(max(xs), max(ys)) * 2
    bins = [(2, 7,   "#8a8aa0", "v", "2–7"),
            (8, 11,  "#1f4e79", "o", "8–11"),
            (12, 13, "#c14c2f", "s", "12–13"),
            (14, 17, "#3a7c2f", "D", "14–17"),
            (18, 99, "#7a4a1f", "^", ">17")]
    for lo_n, hi_n, col, mk, lab in bins:
        bx = [x for x, n in zip(xs, ns) if lo_n <= n <= hi_n]
        by = [y for y, n in zip(ys, ns) if lo_n <= n <= hi_n]
        if bx:
            ax.loglog(bx, by, mk, ms=8, alpha=0.85, color=col,
                      label=f"{lab} (n={len(bx)})")
    ax.plot([lo, hi], [lo, hi], "k--", lw=1, alpha=0.6)
    ax.set_xlim(lo, hi); ax.set_ylim(lo, hi)
    ax.set_xlabel(xlab); ax.set_ylabel(ylab); ax.set_title(title)
    ax.legend(loc="upper left", fontsize=8)

for col, cfg in enumerate(non_pg):
    scatter_panel(axes[0, col], ratios(med_plan, cfg),
                  f"Planning · {cfg}",
                  "PG planning (ms, log)", f"{cfg} planning (ms, log)")
    scatter_panel(axes[1, col], ratios(med_exec, cfg),
                  f"Execution · {cfg}",
                  "PG execution (ms, log)", f"{cfg} execution (ms, log)")
    scatter_panel(axes[2, col], ratios(med_total, cfg),
                  f"e2e total · {cfg}",
                  "PG total (ms, log)", f"{cfg} total (ms, log)")

fig.suptitle(f"SAIO configs vs PostgreSQL — JOB n_rels ≥ 12  "
             f"({src_path.parent.name})", y=1.0)
fig.text(0.5, -0.005, "Below diagonal = config faster than PG; above = slower.",
         ha="center", fontsize=9, style="italic", color="#444")
plt.tight_layout()
out = OUT / "saio_configs_e2e_scatter.png"
fig.savefig(out, dpi=130, bbox_inches="tight")
print(f"  -> {out}")
plt.close(fig)

# --- Plot 2: per-query ratio bars per config -------------------------------
fig, axes = plt.subplots(1, len(non_pg), figsize=(7 * len(non_pg), 9),
                         sharey=True, squeeze=False)
for col, cfg in enumerate(non_pg):
    ax = axes[0, col]
    pairs = sorted(ratios(med_total, cfg), key=lambda t: t[1])
    n = len(pairs); y = np.arange(n)
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
    ax.set_xlabel("log2(config total / PG total)")
    ax.set_title(f"{cfg}: e2e ratio per query\nblue=faster, red=slower (≥5%)")
    for yi, (_, r, _, _, _) in zip(y, pairs):
        if r < 0.95 or r > 1.05:
            ax.text(math.log2(r), yi,
                    f" {r:.2f}×" if r >= 1 else f"{r:.2f}× ",
                    va="center", ha="left" if r >= 1 else "right",
                    fontsize=7, color="#333")
plt.tight_layout()
out = OUT / "saio_configs_e2e_ratio.png"
fig.savefig(out, dpi=130, bbox_inches="tight")
print(f"  -> {out}")
plt.close(fig)

# --- Plot 2b: median ratio binned by n_rels --------------------------------
N_BINS = [(2, 7, "n=2-7"), (8, 11, "n=8-11"), (12, 13, "n=12-13"),
          (14, 17, "n=14-17"), (18, 99, "n≥18")]

fig, axes = plt.subplots(1, 3, figsize=(16.5, 5),
                         sharey=True)

def bin_stats(med_map, cfg):
    out = []
    for lo_n, hi_n, lbl in N_BINS:
        rs = [r[1] for r in ratios(med_map, cfg)
              if lo_n <= r[4] <= hi_n]
        if rs:
            out.append((lbl, len(rs), median(rs), geomean(rs)))
        else:
            out.append((lbl, 0, None, None))
    return out

for ax, (label, med_map) in zip(axes,
                                [("planning", med_plan),
                                 ("execution", med_exec),
                                 ("total e2e", med_total)]):
    width = 0.8 / len(non_pg)
    xs = np.arange(len(N_BINS))
    for i, cfg in enumerate(non_pg):
        stats = bin_stats(med_map, cfg)
        offset = (i - (len(non_pg) - 1) / 2.0) * width
        meds = [s[2] if s[2] is not None else 0 for s in stats]
        ns   = [s[1] for s in stats]
        col  = palette.get(cfg, ("#666666", "#aaaaaa"))[0] if False else None
        bars = ax.bar(xs + offset, meds, width, label=cfg, alpha=0.85)
        for x, n, m in zip(xs + offset, ns, meds):
            if m > 0:
                ax.text(x, m * 1.04, f"{m:.1f}×\n(n={n})", ha="center",
                        fontsize=7, color="#222")
    ax.axhline(1.0, color="black", lw=0.7, ls=":", alpha=0.6)
    ax.set_xticks(xs)
    ax.set_xticklabels([b[2] for b in N_BINS], fontsize=9)
    ax.set_yscale("log")
    ax.set_ylabel(f"median {label} ratio vs pg (log)")
    ax.set_title(label)
    ax.legend(fontsize=8, loc="upper left")
fig.suptitle(f"SAIO vs PostgreSQL — median per-query ratios binned by n_rels  "
             f"({src_path.parent.name})", y=1.02)
plt.tight_layout()
out = OUT / "saio_configs_by_nrels.png"
fig.savefig(out, dpi=130, bbox_inches="tight")
print(f"  -> {out}")
plt.close(fig)

# --- Plot 3: planning+exec stacked bars per query and config ---------------
# Only produce for small query sets — at 100+ queries the bars become unreadable.
if len(queries) > 30:
    print(f"  skipping planning_vs_exec stacked bars ({len(queries)} queries — too many)")
    qs = []
else:
    qs = sorted(queries, key=lambda q: (n_lookup[q],
                                        med_total.get(("pg", q), 0)))
if qs:
    n_cfg = len(configs)
    order = ["pg"] + non_pg
    width = 0.8 / n_cfg
    fig, ax = plt.subplots(figsize=(max(10, 0.55 * len(qs) * n_cfg), 6.5))
    x = np.arange(len(qs))
    palette = {
        "pg":             ("#1f4e79", "#76a8d8"),
        "saio_default":   ("#7a2f1f", "#d8917b"),
        "saio_mid":       ("#7a4a1f", "#d8b27b"),
        "saio_cheap":     ("#3a5f1f", "#9bc97b"),
        "saio_cheap_r3":  ("#1f5a5f", "#7bc8d4"),
        "saio_cheap_r5":  ("#5a1f5f", "#c97bd4"),
    }
    for i, cfg in enumerate(order):
        offset = (i - (n_cfg - 1) / 2.0) * width
        plan = [med_plan.get((cfg, q), 0) for q in qs]
        execm = [med_exec.get((cfg, q), 0) for q in qs]
        plan_color, exec_color = palette.get(cfg, ("#555555", "#aaaaaa"))
        ax.bar(x + offset, plan, width, color=plan_color,
               label=f"{cfg} planning")
        ax.bar(x + offset, execm, width, bottom=plan, color=exec_color,
               label=f"{cfg} execution")
    ax.set_xticks(x)
    ax.set_xticklabels([f"{q}\n(n={n_lookup[q]})" for q in qs],
                       rotation=60, ha="right", fontsize=8)
    ax.set_yscale("log")
    ax.set_ylabel("time (ms, log)")
    ax.set_title("Planning + execution per query — all configs")
    ax.legend(fontsize=8, ncol=3)
    plt.tight_layout()
    out = OUT / "saio_configs_planning_vs_exec.png"
    fig.savefig(out, dpi=130, bbox_inches="tight")
    print(f"  -> {out}")
    plt.close(fig)

print("\nDone.")

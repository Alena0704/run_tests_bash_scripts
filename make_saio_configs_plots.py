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
    bins = [(2, 7,   _lighten(COLOR_BLUE, 0.5),  "v", "2–7"),
            (8, 11,  COLOR_BLUE,                  "o", "8–11"),
            (12, 13, COLOR_ORANGE,                "s", "12–13"),
            (14, 17, _shade(COLOR_ORANGE, 0.30),  "D", "14–17"),
            (18, 99, _shade(COLOR_ORANGE, 0.55),  "^", ">17")]
    for lo_n, hi_n, col, mk, lab in bins:
        bx = [x for x, n in zip(xs, ns) if lo_n <= n <= hi_n]
        by = [y for y, n in zip(ys, ns) if lo_n <= n <= hi_n]
        if bx:
            ax.loglog(bx, by, mk, ms=8, alpha=0.9, color=col,
                      label=f"{lab} (n={len(bx)})")
    ax.plot([lo, hi], [lo, hi], "k--", lw=1, alpha=0.6)
    ax.set_xlim(lo, hi); ax.set_ylim(lo, hi)
    ax.set_xlabel(xlab); ax.set_ylabel(ylab); ax.set_title(title)
    ax.legend(loc="upper left", fontsize=14)

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

_min_n = min((n_lookup[q] for q in queries), default=0)
_max_n = max((n_lookup[q] for q in queries), default=0)
fig.suptitle(f"SAIO configs vs PostgreSQL — JOB "
             f"({len(queries)} queries, n_rels {_min_n}–{_max_n})  "
             f"({src_path.parent.name})", y=1.0)
fig.text(0.5, -0.005, "Below diagonal = config faster than PG; above = slower.",
         ha="center", fontsize=14, style="italic", color="#444")
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
    colors = [COLOR_BLUE if v < -math.log2(1.05)
              else (COLOR_ORANGE if v > math.log2(1.05) else "#aaaaaa")
              for v in log2r]
    ax.barh(y, log2r, color=colors, edgecolor="black", linewidth=0.2,
            height=0.78)
    ax.axvline(0, color="black", linewidth=0.7)
    ax.set_yticks(y)
    ax.set_yticklabels([f"{q} (n={nr})" for q, _, _, _, nr in pairs],
                       fontsize=14)
    ax.set_xlabel("log2(config total / PG total)")
    ax.set_title(f"{cfg}: e2e ratio per query\nblue=faster, orange=slower (≥5%)")
    for yi, (_, r, _, _, _) in zip(y, pairs):
        if r < 0.95 or r > 1.05:
            ax.text(math.log2(r), yi,
                    f" {r:.2f}×" if r >= 1 else f"{r:.2f}× ",
                    va="center", ha="left" if r >= 1 else "right",
                    fontsize=14, color="#333")
plt.tight_layout()
out = OUT / "saio_configs_e2e_ratio.png"
fig.savefig(out, dpi=130, bbox_inches="tight")
print(f"  -> {out}")
plt.close(fig)

# --- Plot 2b: absolute planning + execution time binned by n_rels ----------
N_BINS = [(2, 7, "n=2-7"), (8, 11, "n=8-11"), (12, 13, "n=12-13"),
          (14, 17, "n=14-17"), (18, 99, "n≥18")]

# GUC parameter labels for each SAIO config — surfaced in the plot legend
# (and as a subtitle) so the reader doesn't need to dig into the bench script.
CFG_PARAMS = {
    "saio_default":   "eq=16  T=2.0  red=0.9  freeze=4  R=1",
    "saio_mid":       "eq=8   T=2.0  red=0.85 freeze=3  R=1",
    "saio_cheap":     "eq=4   T=2.0  red=0.7  freeze=2  R=1",
    "saio_cheap_r3":  "eq=4   T=2.0  red=0.7  freeze=2  R=3",
    "saio_cheap_r5":  "eq=4   T=2.0  red=0.7  freeze=2  R=5",
    "saio_cheapest":  "eq=2   T=1.0  red=0.5  freeze=2  R=1",
}

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

# Two-panel chart: absolute planning and execution time per n_rels bin,
# with one bar group per config (pg + all SAIO variants).
fig, axes = plt.subplots(1, 2, figsize=(13, 5.4), sharey=True)

def bin_abs(med_map, cfg):
    """Median of the per-query median times for queries inside each n_rels bin."""
    out = []
    for lo_n, hi_n, lbl in N_BINS:
        vals = [med_map[(cfg, q)] for q in queries
                if (cfg, q) in med_map and lo_n <= n_lookup[q] <= hi_n]
        if vals:
            out.append((lbl, len(vals), median(vals)))
        else:
            out.append((lbl, 0, None))
    return out


bar_order = ["pg"] + non_pg
# PG keeps the blue; every SAIO variant is plotted as a different shade of
# the project orange so all bars stay in the two-colour palette.
bar_colors = {
    "pg":             COLOR_BLUE,
    "saio_default":   COLOR_ORANGE,
    "saio_mid":       _shade(COLOR_ORANGE, 0.15),
    "saio_cheap":     _shade(COLOR_ORANGE, 0.30),
    "saio_cheap_r3":  _shade(COLOR_ORANGE, 0.45),
    "saio_cheap_r5":  _shade(COLOR_ORANGE, 0.60),
    "saio_cheapest":  _shade(COLOR_ORANGE, 0.75),
}

for ax, (label, med_map) in zip(axes,
                                [("planning", med_plan),
                                 ("execution", med_exec)]):
    width = 0.8 / len(bar_order)
    xs = np.arange(len(N_BINS))
    for i, cfg in enumerate(bar_order):
        stats = bin_abs(med_map, cfg)
        offset = (i - (len(bar_order) - 1) / 2.0) * width
        meds = [s[2] if s[2] is not None else 0 for s in stats]
        ns   = [s[1] for s in stats]
        legend_label = cfg
        if cfg in CFG_PARAMS:
            legend_label = f"{cfg}  [{CFG_PARAMS[cfg]}]"
        color = bar_colors.get(cfg, "#666666")
        ax.bar(xs + offset, meds, width, label=legend_label, color=color,
               alpha=0.9, edgecolor="black", linewidth=0.3)
        for x, n, m in zip(xs + offset, ns, meds):
            if m and m > 0:
                ax.text(x, m * 1.08, f"{m:.0f}\n(n={n})", ha="center",
                        fontsize=14, color="#222")
    ax.set_xticks(xs)
    ax.set_xticklabels([b[2] for b in N_BINS], fontsize=14)
    ax.set_yscale("log")
    ax.set_ylabel(f"median {label} time (ms, log)")
    ax.set_title(label)
    ax.legend(fontsize=14, loc="upper left")
fig.suptitle(f"SAIO vs PostgreSQL — median per-query planning & execution "
             f"binned by n_rels  ({src_path.parent.name})\n"
             f"params shown as eq=equilibrium_factor  T=initial_temperature_factor  "
             f"red=temperature_reduction_factor  freeze=moves_before_frozen  R=restarts",
             y=1.02, fontsize=16)
plt.tight_layout()
out = OUT / "saio_configs_by_nrels.png"
fig.savefig(out, dpi=130, bbox_inches="tight")
print(f"  -> {out}")
plt.close(fig)

# --- Plot 3: planning+exec stacked bars per query and config ---------------
# For large query sets keep only the top-25 by pg total time — these are the
# queries where the planning/exec split is actually informative.
TOP_K_FOR_STACK = 25
if len(queries) > TOP_K_FOR_STACK:
    by_pg = sorted([q for q in queries if med_total.get(("pg", q)) is not None],
                   key=lambda q: med_total[("pg", q)], reverse=True)[:TOP_K_FOR_STACK]
    qs = sorted(by_pg, key=lambda q: (n_lookup[q],
                                      med_total.get(("pg", q), 0)))
    stack_title = (f"Planning + execution per query — top {len(qs)} "
                   f"queries by pg total time (of {len(queries)})")
else:
    qs = sorted(queries, key=lambda q: (n_lookup[q],
                                        med_total.get(("pg", q), 0)))
    stack_title = "Planning + execution per query — all configs"
if qs:
    # For the stacked planning+exec plot show only pg + the single best SAIO
    # config (lowest median total ratio).  Multiple saio variants on the same
    # x-tick are visually overwhelming.
    def total_med_ratio(cfg):
        rs = [r[1] for r in ratios(med_total, cfg)]
        return median(rs) if rs else float("inf")
    best_saio = min(non_pg, key=total_med_ratio) if non_pg else None
    order = ["pg"] + ([best_saio] if best_saio else [])
    n_cfg = len(order)
    width = 0.8 / n_cfg
    # Width per query group (in inches). Cap height-to-width ratio so the
    # figure stays readable even for the top-25 subset.
    per_q = 0.7
    fig_w = max(14, per_q * len(qs))
    fig_h = max(8, fig_w / 3.5)
    fig, ax = plt.subplots(figsize=(fig_w, fig_h))
    x = np.arange(len(qs))
    # Dark = planning, light = execution.  PG keeps the blue pair, every SAIO
    # variant uses an orange pair (different shades for variants).
    palette = {
        "pg":             (COLOR_BLUE,                 _lighten(COLOR_BLUE, 0.5)),
        "saio_default":   (_shade(COLOR_ORANGE, 0.35), COLOR_ORANGE),
        "saio_mid":       (_shade(COLOR_ORANGE, 0.45), _lighten(COLOR_ORANGE, 0.15)),
        "saio_cheap":     (_shade(COLOR_ORANGE, 0.55), _lighten(COLOR_ORANGE, 0.30)),
        "saio_cheap_r3":  (_shade(COLOR_ORANGE, 0.65), _lighten(COLOR_ORANGE, 0.45)),
        "saio_cheap_r5":  (_shade(COLOR_ORANGE, 0.75), _lighten(COLOR_ORANGE, 0.55)),
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
                       rotation=60, ha="right", fontsize=14)
    ax.set_yscale("log")
    ax.set_ylabel("time (ms, log)")
    title_extra = f" — pg vs {best_saio}" if best_saio else ""
    ax.set_title(stack_title + title_extra)
    ax.legend(fontsize=14, ncol=2)
    plt.tight_layout()
    out = OUT / "saio_configs_planning_vs_exec.png"
    fig.savefig(out, dpi=130, bbox_inches="tight")
    print(f"  -> {out}")
    plt.close(fig)

print("\nDone.")

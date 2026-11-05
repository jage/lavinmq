"""Markdown tables of the Acton attribution matrix from $SCRATCH/matrix/*.txt (run-matrix.sh).
Each cell: median over the runs (min-max), and the change of the median against `fix`.
    python3 -I matrix_tables.py <matrix dir>
"""
import re, statistics, sys
from collections import defaultdict
from pathlib import Path

d = Path(sys.argv[1])
ORDER = ["stock", "fix", "fix-pf", "acton", "acton-nopf", "acton-noinl", "acton+refill8", "acton+bpm4m"]


def num(pat, line):
    m = re.search(pat, line)
    return float(m.group(1)) if m else None


def load(name, key, metrics):
    rows = defaultdict(lambda: defaultdict(list))
    f = d / f"{name}.txt"
    if not f.exists():
        return rows
    for line in f.read_text().splitlines():
        k = key(line)
        for m, pat in metrics.items():
            v = num(pat, line)
            if v is not None:
                rows[k][m].append(v)
    return rows


def cell(vals, base, lower_better=True):
    if not vals:
        return "-"
    med = statistics.median(vals)
    s = f"{med:.1f}" if med < 1000 else f"{med:,.0f}"
    if len(vals) > 1:
        s += f" ({min(vals):.1f}-{max(vals):.1f})" if med < 1000 else f" ({min(vals):,.0f}-{max(vals):,.0f})"
    if base:
        delta = (med / statistics.median(base) - 1) * 100
        s += f" **{delta:+.0f}%**" if abs(delta) >= 0.5 else " ±0%"
    return s


def table(title, rows, groups, metrics, variant_of, group_of, note=""):
    if not rows:
        return
    print(f"\n### {title}\n")
    if note:
        print(note + "\n")
    cols = [(g, m) for g in groups for m in metrics]
    print("| variant | " + " | ".join(f"{g} {m}" if g else m for g, m in cols) + " |")
    print("|---" * (len(cols) + 1) + "|")
    variants = sorted({variant_of(k) for k in rows}, key=lambda v: ORDER.index(v) if v in ORDER else 99)
    for v in variants:
        out = []
        for g, m in cols:
            k = next((k for k in rows if variant_of(k) == v and group_of(k) == g), None)
            kb = next((k for k in rows if variant_of(k) == "fix" and group_of(k) == g), None)
            vals = rows[k][m] if k else []
            base = rows[kb][m] if kb and v != "fix" else None
            out.append(cell(vals, base))
        print(f"| {v} | " + " | ".join(out) + " |")


def mkey(line):
    f = line.split()
    return (f[1], int(num(r"markers\s+(\d+)", line)))


for sc, title in [("M1", "M1 mark: 2M-node lists, no fibers (collect p50 ms, lower is better)"),
                  ("M2", "M2 mark: 2M nodes with pointer-free leaves (collect p50 ms)"),
                  ("M3", "M3 mark: 2M-node lists, 6,500 parked fibers (collect p50 ms)")]:
    rows = load(sc, mkey, {"p50 ms": r"collect p50\s+([\d.]+)"})
    groups = sorted({k[1] for k in rows})
    table(title, rows, [f"m{g}" for g in groups], ["p50 ms"], lambda k: k[0], lambda k: f"m{k[1]}")

rows = load("A1", lambda l: (l.split()[1], int(num(r"threads (\d+)", l))),
            {"ns/step": r"([\d.]+) ns/step", "gcs": r"gcs\s+(\d+)"})
groups = sorted({k[1] for k in rows})
table("A1 allocation: ns per step per thread (an object and a String), lower is better",
      rows, [f"{g} thr" for g in groups], ["ns/step"], lambda k: k[0], lambda k: f"{k[1]} thr")

rows = load("B1", lambda l: (l.split()[2], int(num(r"size\s+(\d+)", l))),
            {"con/s": r"con/s\s+(\d+)", "us/msg": r"([\d.]+) us/msg", "gc ms/s": r"gc ms/s\s+([\d.]+)",
             "pause max": r"max\s+([\d.]+) ms"})
for size in sorted({k[1] for k in rows}):
    sub = {k: v for k, v in rows.items() if k[1] == size}
    table(f"B1 broker at full speed, {size} B messages (consume rate higher is better, rest lower)",
          sub, [""], ["con/s", "us/msg", "gc ms/s", "pause max"], lambda k: k[0], lambda k: "")

for sc, title in [("B2", "B2 broker idle, 20k queues + 2,000 connections, forced GC every 3 s"),
                  ("B3", "B3 broker full load: 20k flapping queues, 200 reconnects/s, 20k msg/s")]:
    rows = load(sc, lambda l: l.split()[2],
                {"pause p50": r"pause p50\s+([\d.]+)", "p99": r"p99\s+([\d.]+)", "max": r"max\s+([\d.]+) ms",
                 "GC ms/min": r"gc ms/min\s+([\d.]+)", "RSS peak MB": r"rss peak (\d+)"})
    table(title, rows, [""], ["pause p50", "p99", "max", "GC ms/min", "RSS peak MB"], lambda k: k, lambda k: "")

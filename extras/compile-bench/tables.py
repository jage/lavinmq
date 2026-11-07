#!/usr/bin/env python3
"""Markdown tables from compile-bench results: median over rounds per variant and workload,
wall time against the phase's baseline variant.  Usage: tables.py <results dir>"""
import re, sys, statistics as st
from collections import defaultdict
from pathlib import Path

BUILD = re.compile(r"^(?P<label>\S+?)(?:-r\d+)?\s+(?P<wl>\S+)\s+rc=(?P<rc>\d+) wall\s+(?P<wall>[\d.]+) s cpu\s+(?P<cpu>[\d.]+) s"
                   r" \| semantic\s+(?P<sem>[\d.]+) codegen\s+(?P<cg>[\d.]+) bc\+obj\s+(?P<obj>[\d.]+) link\s+(?P<link>[\d.]+) macro\s+(?P<macro>[\d.]+) s"
                   r" \| gc\s+(?P<colls>\d+) colls\s+(?P<gc>[\d.]+) s max\s+(?P<max>\d+) ms \| rss (?P<rss>\d+) MB")
RUN = re.compile(r"^RUN (?P<label>\S+?)(?:-r\d+)?\s+(?P<wl>\S+)\s+rc=(?P<rc>\d+) wall\s+(?P<wall>[\d.]+) s cpu\s+(?P<cpu>[\d.]+) s"
                 r" \| (?P<ex>\d+) ex (?P<fail>\d+) fail \d+ err \| gc\s+(?P<colls>\d+) colls\s+(?P<gc>[\d.]+) s max\s+(?P<max>\d+) ms \| rss (?P<rss>\d+) MB")
TP = re.compile(r"^TP (?P<label>\S+?)(?:-r\d+)? pub (?P<pub>\d+) con (?P<con>\d+) cpu (?P<cpu>\d+)%")
BASE = {"env": "base", "libgc-a": "pkg", "libgc-b": "pkg", "relopt": None, "devopt": "default",
        "specs": "stock", "sys": "base", "relopt-flag": "release"}


def load(path, rx, any_rc=False):
    rows = defaultdict(list)
    for line in path.read_text().splitlines():
        m = rx.match(line)
        d = m.groupdict() if m else None
        if d and (any_rc or d.get("rc", "0") == "0"):
            rows[(d["wl"] if "wl" in d else "", d["label"])].append({k: float(v) for k, v in d.items() if k not in ("label", "wl", "rc")})
    return rows


def med(rs, k):
    return st.median(r[k] for r in rs)


def pct(x, b):
    d = (x / b - 1) * 100
    return "±0%" if abs(d) < 0.5 else f"{d:+.0f}%"


def builds(phase, rows):
    base = BASE.get(phase)
    out = [f"### {phase}", "", "| workload | variant | n | wall s | vs base | cpu s | semantic | bc+obj | GC s | GC colls | max pause ms | RSS MB |",
           "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for wl in dict.fromkeys(k[0] for k in rows):
        variants = [k[1] for k in rows if k[0] == wl]
        b = rows.get((wl, base)) if base else None
        if phase == "relopt":  # every workload is its own level; release is the baseline per program
            b = rows.get((wl.split("-")[0] + "-release", variants[0]))
        for v in variants:
            rs = rows[(wl, v)]
            w = med(rs, "wall")
            out.append(f"| {wl} | {v} | {len(rs)} | {w:.1f} | {pct(w, med(b, 'wall')) if b else ''} | {med(rs, 'cpu'):.1f} | "
                       f"{med(rs, 'sem'):.1f} | {med(rs, 'obj'):.1f} | {med(rs, 'gc'):.2f} | {med(rs, 'colls'):.0f} | {med(rs, 'max'):.0f} | {med(rs, 'rss'):.0f} |")
    return out + [""]


def runs(rows, base):
    out = ["### specs: spec binaries run", "", "| spec | variant | n | wall s | vs stock | GC s | GC colls | max pause ms | RSS MB | examples/failed |",
           "|---|---|---|---|---|---|---|---|---|---|"]
    for (wl, v), rs in rows.items():
        b = rows.get((wl, base))
        out.append(f"| {wl} | {v} | {len(rs)} | {med(rs, 'wall'):.1f} | {pct(med(rs, 'wall'), med(b, 'wall')) if b else ''} | "
                   f"{med(rs, 'gc'):.2f} | {med(rs, 'colls'):.0f} | {med(rs, 'max'):.0f} | {med(rs, 'rss'):.0f} | {med(rs, 'ex'):.0f}/{med(rs, 'fail'):.0f} |")
    return out + [""]


def tps(name, rows, base):
    out = [f"### {name}: LavinMQ throughput (2+2 clients, 16 B, 20 s)", "", "| build | n | publish msg/s | vs base | consume msg/s | broker CPU |",
           "|---|---|---|---|---|---|"]
    b = rows.get(("", base))
    for (_, v), rs in rows.items():
        out.append(f"| {v} | {len(rs)} | {med(rs, 'pub'):,.0f} | {pct(med(rs, 'pub'), med(b, 'pub')) if b else ''} | {med(rs, 'con'):,.0f} | {med(rs, 'cpu'):.0f}% |")
    return out + [""]


def main(d):
    d = Path(d)
    out = []
    for phase in ["env", "libgc-a", "libgc-b", "devopt", "sys", "relopt", "relopt-flag"]:
        f = d / phase / f"{phase}.txt"
        if f.exists():
            out += builds(phase, load(f, BUILD))
        tp = d / phase / f"{phase}-tp.txt"
        if tp.exists():
            out += tps(phase, load(tp, TP), "lmq-release" if phase == "relopt" else "release")
    if (d / "specs").exists():
        out += builds("specs", load(d / "specs" / "specs-build.txt", BUILD))
        out += runs(load(d / "specs" / "specs.txt", RUN, any_rc=True), "stock")
    print("\n".join(out))


main(sys.argv[1])

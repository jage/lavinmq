# analyze.py <runs dir> <brokers dir>: per-run and per-variant tables (markdown) for RESULTS.md
import sys, os, re, bisect, statistics, subprocess, collections
runs, brokers = sys.argv[1:3]
VARIANTS = ["main", "main-socket", "digest", "digest-socket", "digest-socket-1k"]
PATHS = ["collect_or_expand", "maybe_gc", "grow_table", "explicit", "other"]

_syms = {}
def symbols(binary):
    if binary not in _syms:
        out = subprocess.run(["nm", "-n", "--defined-only", binary], capture_output=True, text=True).stdout
        s = []
        for l in out.splitlines():
            p = l.split(" ", 2)
            if len(p) == 3 and p[1] in "tTwW": s.append((int(p[0], 16), p[2]))
        _syms[binary] = ([a for a, _ in s], [n for _, n in s])
    return _syms[binary]

def classify(frames):
    for f in frames:
        if f.startswith("GC_collect_or_expand"): return "collect_or_expand"
        if f.startswith("GC_grow_table"): return "grow_table"
        if f.startswith(("GC_gcollect", "GC_try_to_collect_general", "GC_try_to_collect")) and not f.startswith("GC_try_to_collect_inner"): return "explicit"
        if f.startswith(("GC_maybe_gc", "GC_collect_a_little_inner")): return "maybe_gc"
    return "other"

def run_stats(d, v):
    drv = open(f"{d}/driver.log").read()
    t0 = int(re.search(r"measure_start (\d+)", drv).group(1)); t1 = int(re.search(r"measure_end (\d+)", drv).group(1))
    mins = (t1 - t0) / 60e9
    allp = [tuple(map(int, l.split()[:2])) for l in open(f"{d}/gc.pauses")]
    idx = [i for i, (e, _) in enumerate(allp) if t0 <= e <= t1]
    p = sorted(allp[i][1] / 1e6 for i in idx)
    pct = lambda q: p[min(len(p) - 1, int(len(p) * q))] if p else 0
    rss = [int(l.split()[1]) // 1024 for l in open(f"{d}/samples.txt") if len(l.split()) >= 2 and l.split()[1].isdigit()]
    r = dict(gcs=len(p) / mins, p50=pct(.5), p90=pct(.9), max=max(p) if p else 0, gcms=sum(p) / mins,
             rss_peak=max(rss), rss_end=rss[-1], reconnects=int(re.search(r"reconnects (\d+)", drv).group(1)))
    # finalizer registrations per second over the measure window
    rows = []
    for l in open(f"{d}/gc.pauses.finalizers"):
        q = l.split(); rows.append((int(q[0]), dict(x.rsplit("=", 1) for x in q[1:])))
    a = min(rows, key=lambda x: abs(x[0] - t0)); b = min(rows, key=lambda x: abs(x[0] - t1))
    secs = (b[0] - a[0]) / 1e9
    r["fin"] = {k: (int(b[1][k]) - int(a[1].get(k, 0))) / secs for k in b[1] if int(b[1][k]) - int(a[1].get(k, 0)) > 0}
    r["unreg"] = None
    if os.path.exists(f"{d}/gc.pauses.unregs"):
        u = [tuple(map(int, l.split())) for l in open(f"{d}/gc.pauses.unregs")]
        a = min(u, key=lambda x: abs(x[0] - t0)); b = min(u, key=lambda x: abs(x[0] - t1))
        r["unreg"] = (b[1] - a[1]) / ((b[0] - a[0]) / 1e9)
    # trigger paths: trace i belongs to collection i (both recorded in order at GC start)
    binary = f"{brokers}/lavinmq-{'digest-socket' if v == 'digest-socket-1k' else v}"
    addrs, names = symbols(binary)
    base = 0
    for l in open(f"{d}/gc.pauses.maps"):  # PIE: load address of the binary's first mapping
        f = l.split()
        if len(f) >= 6 and os.path.basename(f[5]) == os.path.basename(binary):
            base = int(f[0].split("-")[0], 16) - int(f[2], 16); break
    traces = [l.split()[1:] for l in open(f"{d}/gc.pauses.traces")]
    paths = collections.Counter()
    win = set(idx)
    for i, t in enumerate(traces):
        if i not in win: continue
        frames = []
        for h in t:
            x = int(h, 16) - base; j = bisect.bisect_right(addrs, x) - 1
            frames.append(names[j] if j >= 0 else hex(x))
        paths[classify(frames)] += 1
    r["paths"] = paths
    return r

res = {}
for name in sorted(os.listdir(runs), key=lambda n: (int(n.split("-")[0][1:]), n)):
    rnd, v = name.split("-", 1)
    res[(rnd, v)] = run_stats(f"{runs}/{name}", v)

def fin(r):
    return ", ".join(f"{k} {n:.0f}" for k, n in sorted(r["fin"].items(), key=lambda kv: -kv[1]))
def paths(r):
    n = sum(r["paths"].values()) or 1
    return " / ".join(f"{100 * r['paths'][k] / n:.0f}" for k in PATHS)

print("| run | variant | gcs/min | p50 | p90 | max ms | GC ms/min | RSS peak/end MB | finalizers/s | socket unreg/s | trigger % (C/M/G/E/O) |")
print("|---|---|---|---|---|---|---|---|---|---|---|")
for (rnd, v), r in res.items():
    u = f"{r['unreg']:.0f}" if r["unreg"] is not None else "-"
    print(f"| {rnd} | {v} | {r['gcs']:.1f} | {r['p50']:.0f} | {r['p90']:.0f} | {r['max']:.0f} | {r['gcms']:.0f} | {r['rss_peak']}/{r['rss_end']} | {fin(r)} | {u} | {paths(r)} |")
print()
print("| variant | runs | gcs/min | p50 | p90 | max ms | GC ms/min | RSS peak MB | finalizers/s (total) | socket unreg/s | trigger % (C/M/G/E/O) |")
print("|---|---|---|---|---|---|---|---|---|---|---|")
for v in VARIANTS:
    rs = [r for (_, w), r in res.items() if w == v]
    if not rs: continue
    m = lambda k: statistics.median(r[k] for r in rs)
    u = statistics.median(r["unreg"] for r in rs) if rs[0]["unreg"] is not None else None
    pc = sum((r["paths"] for r in rs), collections.Counter()); tot = sum(pc.values()) or 1
    print(f"| {v} | {len(rs)} | {m('gcs'):.1f} | {m('p50'):.0f} | {m('p90'):.0f} | {m('max'):.0f} | {m('gcms'):.0f} | {m('rss_peak'):.0f} | "
          f"{statistics.median(sum(r['fin'].values()) for r in rs):.0f} | {'-' if u is None else f'{u:.0f}'} | {' / '.join(f'{100 * pc[k] / tot:.0f}' for k in PATHS)} (n={tot}) |")

# Per-run and per-variant tables from r<round>-<variant>/ dirs: python3 -I analyze.py <dir>
import sys, re, os, glob, statistics
root = sys.argv[1]
VARIANTS = ["bundled", "bundled-m1", "global", "global32k"]
def run(d):
    drv = open(f"{d}/driver.log").read()
    t0 = int(re.search(r"measure_start (\d+)", drv).group(1)); t1 = int(re.search(r"measure_end (\d+)", drv).group(1))
    allp = [tuple(map(int, l.split()[:2])) for l in open(f"{d}/gc.pauses") if l.strip()]
    p = sorted(dur / 1e6 for end, dur in allp if t0 <= end <= t1)
    pct = lambda q: p[min(len(p) - 1, int(len(p) * q))]
    mins = (t1 - t0) / 60e9
    end, dur = max(((e, du) for e, du in allp if e <= t1), key=lambda x: x[1])  # whole run incl. connect phase
    big = [(e - t0) / 1e9 for e, du in allp if du > 2 * pct(.5) and e <= t1]
    rss = [int(l.split()[1]) // 1024 for l in open(f"{d}/samples.txt") if len(l.split()) >= 2 and l.split()[1].isdigit()]
    rows = []
    for l in open(f"{d}/gc.pauses.finalizers"):
        f = l.split(); rows.append((int(f[0]), dict(x.rsplit("=", 1) for x in f[1:])))
    a = min(rows, key=lambda x: abs(x[0] - t0)); b = min(rows, key=lambda x: abs(x[0] - t1))
    secs = (b[0] - a[0]) / 1e9
    fin = {k: (int(v) - int(a[1].get(k, 0))) / secs for k, v in b[1].items()}
    fin = ", ".join(f"{k.split('::')[-1]} {r:.0f}" for k, r in sorted(fin.items(), key=lambda x: -x[1]) if r >= 1)
    perf = open(f"{d}/perf.log").read(); m = re.search(r"Average publish rate: (\d+)", perf)
    return dict(gcs=len(p) / mins, p50=pct(.5), p90=pct(.9), max=p[-1], maxall=dur / 1e6, maxat=(end - t0) / 1e9,
                big=big, gcms=sum(p) / mins, rss=max(rss), fin=fin, pub=m.group(1) if m else "-")
res = {}
print("| run | variant | GCs/min | p50 | p90 | max (window) | max (incl. connect) at s | pauses >2x p50 at s | GC ms/min | RSS peak MB | pub/s | finalizers/s |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|")
for d in sorted(glob.glob(f"{root}/r*-*"), key=lambda d: (int(re.search(r"/r(\d+)-", d).group(1)), VARIANTS.index(d.split("-", 1)[1] if False else re.search(r"/r\d+-(.*)$", d).group(1)))):
    rnd, v = re.search(r"/r(\d+)-(.*)$", d).groups()
    r = run(d); res.setdefault(v, []).append(r)
    big = " ".join(f"{t:.0f}" for t in r["big"]) or "-"
    print(f"| {rnd} | {v} | {r['gcs']:.1f} | {r['p50']:.1f} | {r['p90']:.1f} | {r['max']:.1f} | {r['maxall']:.1f} @ {r['maxat']:.0f} | {big} | {r['gcms']:.0f} | {r['rss']} | {r['pub']} | {r['fin']} |")
print()
print("| variant | runs | GCs/min | p50 | p90 | max (window) | max (incl. connect) | GC ms/min | RSS peak MB |")
print("|---|---|---|---|---|---|---|---|---|")
for v in VARIANTS:
    if v not in res: continue
    m = lambda k: statistics.median(r[k] for r in res[v])
    print(f"| {v} | {len(res[v])} | {m('gcs'):.1f} | {m('p50'):.1f} | {m('p90'):.1f} | {m('max'):.1f} | {m('maxall'):.1f} | {m('gcms'):.0f} | {m('rss'):.0f} |")

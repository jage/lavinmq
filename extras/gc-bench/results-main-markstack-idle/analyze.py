# analyze.py <run dir>...: one row per run: collections/min, pause p50/p90/max within the measure
# window, second of the max (from measure_start), GC ms/min, RSS peak/end, the max pause over the
# whole run (including connection setup) with its second, the number of whole-run pauses over
# 2x the window p50 (mark stack growth spikes), the total collection count, and finalizer registrations/s by type.
import sys, re, statistics
def pct(a, q): return a[min(len(a) - 1, int(len(a) * q))] if a else 0
for out in sys.argv[1:]:
    drv = open(f"{out}/driver.log").read()
    t0 = int(re.search(r"measure_start (\d+)", drv).group(1))
    t1 = int(re.search(r"measure_end (\d+)", drv).group(1))
    allp = [tuple(map(int, l.split()[:2])) for l in open(f"{out}/gc.pauses")]
    win = [(e, d / 1e6) for e, d in allp if t0 <= e <= t1]
    p = sorted(d for _, d in win)
    mins = (t1 - t0) / 60e9
    me, mx = max(win, key=lambda x: x[1])
    ae, ax = max(((e, d / 1e6) for e, d in allp), key=lambda x: x[1])
    rss = [int(l.split()[1]) // 1024 for l in open(f"{out}/samples.txt") if len(l.split()) >= 2 and l.split()[1].isdigit()]
    rows = []
    for l in open(f"{out}/gc.pauses.finalizers"):
        f = l.split(); rows.append((int(f[0]), dict(x.rsplit("=", 1) for x in f[1:])))
    a = min(rows, key=lambda x: abs(x[0] - t0)); b = min(rows, key=lambda x: abs(x[0] - t1))
    secs = (b[0] - a[0]) / 1e9
    fin = sorted(((int(v) - int(a[1].get(k, 0))) / secs, k) for k, v in b[1].items())
    fin = ", ".join(f"{k} {r:.2f}" for r, k in reversed(fin) if r > 0) or "-"
    spikes = sum(1 for _, d in allp if d / 1e6 > 2 * pct(p, .5))
    name = out.rstrip("/").split("/")[-1]
    print(f"| {name} | {len(p)/mins:.1f} | {pct(p,.5):.1f} | {pct(p,.9):.1f} | {mx:.1f} | {(me-t0)/1e9:.0f} | "
          f"{sum(p)/mins:.0f} | {max(rss)} / {rss[-1]} | {ax:.1f} @ {(ae-t0)/1e9:.0f} | {spikes} | {len(allp)} | {fin} |")

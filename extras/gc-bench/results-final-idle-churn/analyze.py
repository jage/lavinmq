# analyze.py <variant> <mode> <rundir>: one JSON line per run: collections/min, pause p50/p90/max,
# GC ms/min, RSS peak/end, finalizer registrations/s by type, when the max pause happened
import sys, re, json
v, mode, out = sys.argv[1:4]
drv = open(f"{out}/driver.log").read()
t0 = int(re.search(r"measure_start (\d+)", drv).group(1))
t1 = int(re.search(r"measure_end (\d+)", drv).group(1))
allp = [tuple(map(int, l.split()[:2])) for l in open(f"{out}/gc.pauses")]
p = [(e, d / 1e6) for e, d in allp if t0 <= e <= t1]
ds = sorted(d for _, d in p)
pct = lambda q: ds[min(len(ds) - 1, int(len(ds) * q))] if ds else 0
mins = (t1 - t0) / 60e9
rss = [int(f[1]) // 1024 for f in (l.split() for l in open(f"{out}/samples.txt")) if len(f) >= 2 and f[1].isdigit()]
mx = max(p, key=lambda x: x[1]) if p else (t0, 0)
# overall max incl. startup/setup, to see where the worst pause is
amx = max(allp, key=lambda x: x[1]) if allp else (t0, 0)
fin = {}
rows = []
for l in open(f"{out}/gc.pauses.finalizers"):
    f = l.split(); rows.append((int(f[0]), dict(x.rsplit("=", 1) for x in f[1:])))
if rows:
    a = min(rows, key=lambda x: abs(x[0] - t0)); b = min(rows, key=lambda x: abs(x[0] - t1))
    secs = (b[0] - a[0]) / 1e9
    for k in b[1]:
        n = int(b[1][k]) - int(a[1].get(k, 0))
        if n and secs > 0: fin[k] = round(n / secs, 1)
rec = re.search(r"reconnects (\d+)", drv)
print(json.dumps({"variant": v, "mode": mode, "gcs_min": round(len(p) / mins, 2), "n": len(p),
  "p50": round(pct(.5), 1), "p90": round(pct(.9), 1), "max": round(mx[1], 1),
  "max_at_s": round((mx[0] - t0) / 1e9, 1), "gc_ms_min": round(sum(ds) / mins, 1),
  "all_max": round(amx[1] / 1e6, 1), "all_max_at_s": round((amx[0] - t0) / 1e9, 1),
  "rss_peak": max(rss) if rss else 0, "rss_end": rss[-1] if rss else 0,
  "reconnects": int(rec.group(1)) if rec else 0, "fin_per_s": fin}))

# analyze.py <run dir>...: one JSON line per run with the metrics for RESULTS.md
import sys, re, json, statistics
for out in sys.argv[1:]:
    drv = open(f"{out}/driver.log").read()
    t0 = int(re.search(r"measure_start (\d+)", drv).group(1))
    t1 = int(re.search(r"measure_end (\d+)", drv).group(1))
    rec = int(re.search(r"reconnects (\d+)", drv).group(1))
    allp = [tuple(map(int, l.split()[:4])) for l in open(f"{out}/gc.pauses")]
    p = [(e, d) for e, d, *_ in allp if t0 <= e <= t1]
    pre = [d for e, d, *_ in allp if e < t0]
    durs = sorted(d / 1e6 for _, d in p)
    pct = lambda a, q: a[min(len(a) - 1, int(len(a) * q))] if a else 0
    mins = (t1 - t0) / 60e9
    me, md = max(p, key=lambda x: x[1]) if p else (t0, 0)
    rss = [int(l.split()[1]) // 1024 for l in open(f"{out}/samples.txt") if len(l.split()) >= 2 and l.split()[1].isdigit()]
    rows = []
    for l in open(f"{out}/gc.pauses.finalizers"):
        f = l.split(); rows.append((int(f[0]), dict(x.rsplit("=", 1) for x in f[1:])))
    a = min(rows, key=lambda x: abs(x[0] - t0)); b = min(rows, key=lambda x: abs(x[0] - t1))
    secs = (b[0] - a[0]) / 1e9
    fin = {k: round((int(v) - int(a[1].get(k, 0))) / secs, 1) for k, v in b[1].items() if int(v) - int(a[1].get(k, 0)) > 0}
    perf = open(f"{out}/perf.log").read()
    m = re.search(r"Average publish rate: (\d+)", perf)
    print(json.dumps(dict(run=out.rstrip("/").split("/")[-1], gcs_min=round(len(durs) / mins, 2), n=len(durs),
        p50=round(pct(durs, .5), 1), p90=round(pct(durs, .9), 1), max=round(md / 1e6, 1),
        max_at_s=round((me - t0) / 1e9, 1), pre_n=len(pre), pre_max=round(max(pre) / 1e6, 1) if pre else 0,
        gc_ms_min=round(sum(durs) / mins, 1), rss_peak=max(rss), rss_end=rss[-1], reconnects_s=round(rec / ((t1 - t0) / 1e9), 1),
        fin_s=fin, pub_s=int(m.group(1)) if m else None)))

import re, statistics, glob, os, sys
# tables.py: markdown per-run and per-variant median tables from summary.txt, runs/ and probe.txt
here = os.path.dirname(os.path.abspath(__file__))
VS = ["bundled", "global", "global16k", "global32k"]
pat = re.compile(r"r(\d+) (\w+)\s+\| (\S+)\s+\S+\s+gcs/min\s+([\d.]+) pause p50\s+([\d.]+) p90\s+([\d.]+) max\s+([\d.]+) ms gc ms/min\s+([\d.]+) \| rss start\s+([\d.]+) end\s+([\d.]+) \| smaps rss\s+([\d.]+) pss\s+([\d.]+) anon\s+([\d.]+) MB")
cols = ["gcs/min", "p50", "p90", "max", "GC ms/min", "RSS start", "RSS end", "smaps Rss", "Pss", "Anon"]

def fins(d):
    drv = open(f"{d}/driver.log").read()
    t0 = int(re.search(r"measure_start (\d+)", drv).group(1)); t1 = int(re.search(r"measure_end (\d+)", drv).group(1))
    rows = []
    for l in open(f"{d}/gc.pauses.finalizers"):
        p = l.split(); rows.append((int(p[0]), dict(x.rsplit("=", 1) for x in p[1:])))
    if not rows: return ""
    a = min(rows, key=lambda x: abs(x[0] - t0)); b = min(rows, key=lambda x: abs(x[0] - t1))
    secs = (b[0] - a[0]) / 1e9
    if secs <= 0: return ""
    out = [(k.split("::")[-1], (int(b[1][k]) - int(a[1].get(k, 0))) / secs) for k in b[1]]
    return ", ".join(f"{k} {n:.0f}" for k, n in sorted(out, key=lambda x: -x[1]) if n >= 0.5)

runs = []
for l in open(f"{here}/summary.txt"):
    m = pat.search(l)
    if m:
        r, test, v = int(m.group(1)), m.group(2), m.group(3)
        runs.append((test, r, v, [float(x) for x in m.groups()[3:]], fins(f"{here}/runs/r{r}-{test}-{v}")))
for test in ["idle", "load"]:
    print(f"\n### {test}: per run (pauses ms, RSS MB)\n")
    print("| round | variant | " + " | ".join(cols) + " | finalizers/s |")
    print("|" + "---|" * (len(cols) + 3))
    for t, r, v, x, f in sorted((x for x in runs if x[0] == test), key=lambda x: (x[1], VS.index(x[2]))):
        print(f"| {r} | {v} | " + " | ".join(f"{y:g}" for y in x) + f" | {f} |")
    print(f"\n### {test}: per-variant median\n")
    print("| variant | n | " + " | ".join(cols) + " |")
    print("|" + "---|" * (len(cols) + 2))
    for v in VS:
        xs = [x for t, r, vv, x, f in runs if t == test and vv == v]
        if xs:
            print(f"| {v} | {len(xs)} | " + " | ".join(f"{statistics.median(c):.2f}" for c in zip(*xs)) + " |")
pp = re.compile(r"^\d+ (\S+) rss_init (\d+) rss_alloc (\d+) rss_end (\d+) kB .*collect mean ([\d.]+) ms")
pr = {}
for l in open(f"{here}/probe.txt") if os.path.exists(f"{here}/probe.txt") else []:
    m = pp.match(l)
    if m: pr.setdefault(m.group(1), []).append([int(m.group(i)) for i in (2, 3, 4)] + [float(m.group(5))])
if pr:
    print("\n### probe: median of 10 (RSS kB)\n")
    print("| variant | n | RSS after init | after alloc | after 50 collects | collect mean ms (median) | min-max ms |")
    print("|---|---|---|---|---|---|---|")
    for v in VS:
        xs = pr.get(v, [])
        if xs:
            c = list(zip(*xs))
            print(f"| {v} | {len(xs)} | {statistics.median(c[0]):.0f} | {statistics.median(c[1]):.0f} | {statistics.median(c[2]):.0f} | {statistics.median(c[3]):.2f} | {min(c[3]):.2f}-{max(c[3]):.2f} |")

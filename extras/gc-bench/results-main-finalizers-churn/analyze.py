# analyze.py <run dir> <binary>: one JSON line of metrics for the measurement window
import sys, re, json, bisect, subprocess, statistics, collections
r, binary = sys.argv[1:3]
drv = open(f"{r}/driver.log").read()
t0 = int(re.search(r"measure_start (\d+)", drv).group(1))
t1 = int(re.search(r"measure_end (\d+)", drv).group(1))
rec = int(re.search(r"reconnects (\d+)", drv).group(1))
mins = (t1 - t0) / 60e9
rows = [l.split() for l in open(f"{r}/gc.pauses")]
inwin = [i for i, f in enumerate(rows) if t0 <= int(f[0]) <= t1]
p = sorted(int(rows[i][1]) / 1e6 for i in inwin)
tm = (t0 + t1) // 2
late = [i for i in inwin if int(rows[i][0]) >= tm]
pct = lambda a, q: a[min(len(a) - 1, int(len(a) * q))] if a else 0
# RSS during the window (samples are wall clock, ticks are monotonic: use the last 240 samples' shape)
rss = [int(l.split()[1]) // 1024 for l in open(f"{r}/samples.txt") if len(l.split()) >= 2 and l.split()[1].isdigit()]
# finalizer registrations by type over the window
fr = []
for l in open(f"{r}/gc.pauses.finalizers"):
    f = l.split(); fr.append((int(f[0]), dict(x.rsplit("=", 1) for x in f[1:])))
a = min(fr, key=lambda x: abs(x[0] - t0)); b = min(fr, key=lambda x: abs(x[0] - t1))
fsecs = (b[0] - a[0]) / 1e9
fin = {k: round((int(b[1][k]) - int(a[1].get(k, 0))) / fsecs, 1) for k in b[1] if int(b[1][k]) - int(a[1].get(k, 0)) > 0}
unreg = None
try:
    u = [tuple(map(int, l.split())) for l in open(f"{r}/gc.pauses.unregs")]
    ua = min(u, key=lambda x: abs(x[0] - t0)); ub = min(u, key=lambda x: abs(x[0] - t1))
    unreg = round((ub[1] - ua[1]) / ((ub[0] - ua[0]) / 1e9), 1)
except FileNotFoundError:
    pass
al = [tuple(map(int, l.split())) for l in open(f"{r}/gc.pauses.allocs")]
al = [x for x in al if t0 <= x[0] <= t1]
alloc = (al[-1][1] - al[0][1]) / ((al[-1][0] - al[0][0]) / 1e9) / 1048576 if len(al) > 1 else 0
# trigger path of each collection in the window: innermost known libgc caller of the collection
syms = []
for l in subprocess.run(["nm", "-n", binary], capture_output=True, text=True).stdout.splitlines():
    f = l.split()
    if len(f) == 3 and f[1] in "tTwW": syms.append((int(f[0], 16), f[2]))
addrs = [x for x, _ in syms]
for l in open(f"{r}/gc.pauses.maps"):
    f = l.split()
    if len(f) >= 6 and f[2] == "00000000" and f[5].startswith(binary.rsplit("/", 1)[0]):
        base = int(f[0].split("-")[0], 16); break
def name(x):
    i = bisect.bisect_right(addrs, x - base) - 1
    return syms[i][1] if i >= 0 else "?"
label = {"GC_grow_table": "grow_table", "GC_collect_or_expand": "collect_or_expand", "GC_collect_a_little_inner": "maybe_gc",
         "GC_try_to_collect_general": "explicit"}
traces = [l.split()[1:] for l in open(f"{r}/gc.pauses.traces")]
paths = collections.Counter(); late_paths = collections.Counter()
for i in inwin:
    if i >= len(traces): paths["untraced"] += 1; continue
    names = [name(int(h, 16)) for h in traces[i]]
    hit = next((label[n] for n in names if n in label), "other")
    paths[hit] += 1
    if i in late: late_paths[hit] += 1
print(json.dumps({"run": r.split("/")[-2] + "/" + r.split("/")[-1], "variant": r.split("/")[-1],
    "reconnects_s": round(rec / ((t1 - t0) / 1e9), 1), "gcs_min": round(len(p) / mins, 2),
    "gcs_min_late": round(len(late) / (mins / 2), 2),
    "gc_ms_min_late": round(sum(int(rows[i][1]) / 1e6 for i in late) / (mins / 2), 1), "p50": round(pct(p, .5), 1), "p90": round(pct(p, .9), 1), "max": round(max(p) if p else 0, 1),
    "gc_ms_min": round(sum(p) / mins, 1), "rss_peak": max(rss), "rss_end": rss[-1],
    "rss_med": int(statistics.median(rss[-240:])), "alloc_mb_s": round(alloc, 2),
    "fin": fin, "unreg_s": unreg, "paths": dict(paths), "paths_late": dict(late_paths)}))

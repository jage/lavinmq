# analyze.py <run dir> <binary>: per-minute GC picture from measure_start.
# Prints a table (pre = broker start to measure_start, i.e. queue declares and the 2,000
# connection opens) and a final JSON line. Trigger path as in analyze_window.py: the first known
# libgc caller in each collection's backtrace (G = GC_grow_table, C = GC_collect_or_expand).
import sys, re, json, bisect, subprocess, collections
r, binary = sys.argv[1:3]
drv = open(f"{r}/driver.log").read()
t0 = int(re.search(r"measure_start (\d+)", drv).group(1))
t1 = int(re.search(r"measure_end (\d+)", drv).group(1))
off = float(open(f"{r}/clock.txt").read())  # wall - monotonic, seconds
rows = [list(map(int, l.split()[:2])) for l in open(f"{r}/gc.pauses")]
start = int(open(f"{r}/gc.pauses.allocs").readline().split()[0]) - 10**9  # first allocs line ~1 s after start
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
label = {"GC_grow_table": "G", "GC_collect_or_expand": "C", "GC_collect_a_little_inner": "M", "GC_try_to_collect_general": "E"}
traces = [l.split()[1:] for l in open(f"{r}/gc.pauses.traces")]
def path(i):
    if i >= len(traces): return "U"
    return next((label[n] for n in (name(int(h, 16)) for h in traces[i]) if n in label), "O")
nmin = round((t1 - t0) / 60e9)
bins = collections.OrderedDict((k, {"n": 0, "ms": 0.0, "G": 0, "C": 0, "other": 0, "rss": []}) for k in ["pre"] + list(range(1, nmin + 1)))
def key(t):
    if t < t0: return "pre"
    m = (t - t0) // (60 * 10**9) + 1
    return m if m <= nmin else None
last_g = None
for i, (t, d) in enumerate(rows):
    k = key(t)
    if k is None: continue
    p = path(i); b = bins[k]
    b["n"] += 1; b["ms"] += d / 1e6
    b[p if p in "GC" else "other"] += 1
    if p == "G": last_g = (t - t0) / 60e9
for l in open(f"{r}/samples.txt"):
    f = l.split()
    if len(f) < 2 or not f[1].isdigit(): continue
    k = key(int((float(f[0]) - off) * 1e9))
    if k is not None: bins[k]["rss"].append(int(f[1]) // 1024)
cum = 0.0; out = []
print(f"pre-window: {(t0 - start) / 1e9:.0f} s (queue declares + 2,000 connection opens)")
print("bin   gcs   GC_ms  G  C  oth  cum_ms  rss_max  rss_end")
for k, b in bins.items():
    if k != "pre": cum += b["ms"]
    rss = b["rss"] or [0]
    print(f"{k!s:>4} {b['n']:4d} {b['ms']:7.0f} {b['G']:2d} {b['C']:2d} {b['other']:3d} {cum:7.0f} {max(rss):8d} {rss[-1]:8d}")
    out.append({"bin": k, "n": b["n"], "ms": round(b["ms"], 1), "G": b["G"], "C": b["C"], "other": b["other"],
                "cum_ms": round(cum, 1), "rss_max": max(rss), "rss_end": rss[-1]})
print(f"last grow_table collection at minute {last_g:.2f} after measure_start" if last_g is not None else "no grow_table collections")
print(json.dumps({"run": "/".join(r.rstrip("/").split("/")[-2:]), "pre_s": round((t0 - start) / 1e9, 1),
                  "last_g_min": None if last_g is None else round(last_g, 2), "bins": out}))

# Builds the RESULTS.md tables from the copied run dirs: python3 -I tables.py <results-broker dir>
import sys, os, re, statistics
res = sys.argv[1]

def stats(r):
    d = open(f"{r}/driver.log").read()
    t0 = int(re.search(r"measure_start (\d+)", d).group(1)); t1 = int(re.search(r"measure_end (\d+)", d).group(1))
    rows = [list(map(int, l.split())) for l in open(f"{r}/gc.pauses")]
    rows = [x for x in rows if t0 <= x[0] <= t1 and len(x) == 4]
    p = sorted(x[1] / 1e6 for x in rows)
    mins = (t1 - t0) / 60e9
    med = lambda i: statistics.median(x[i] for x in rows) / 1e6
    pct = lambda q: p[min(len(p) - 1, int(len(p) * q))]
    st = [x[1] / 1e6 for x in rows[3:]]  # after the first 3 collections of the window
    return dict(stmax=max(st) if st else 0, n=len(p), gpm=len(p) / mins, p50=med(1), p99=pct(.99), max=p[-1], mark=med(3), msmin=sum(p) / mins)

def table(kind, keys):
    print("| config | run | GCs | GCs/min | pause p50 | p99 | max | mark p50 | GC ms/min | max after 3rd |")
    print("|---|---|--:|--:|--:|--:|--:|--:|--:|--:|")
    for k in keys:
        for r in (1, 2):
            d = f"{res}/{kind}/{k}-r{r}"
            if not os.path.exists(f"{d}/gc.pauses"):
                print(f"| {k} | {r} | missing | | | | | | |"); continue
            s = stats(d)
            print(f"| {k} | {r} | {s['n']} | {s['gpm']:.1f} | {s['p50']:.1f} | {s['p99']:.1f} | {s['max']:.1f} | {s['mark']:.1f} | {s['msmin']:.0f} | {s['stmax']:.1f} |")

print("## idle\n")
table("idle", [f"{b}-m{m}" for m in ("1", "2", "4", "default") for b in ("bundled", "global", "bigstack")])
print("\n## load\n")
table("load", ["bundled-m1", "global-m4", "global-mdefault", "bigstack-m4"])

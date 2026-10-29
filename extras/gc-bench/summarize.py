import sys, re, statistics
v, mode, out = sys.argv[1:4]
drv = open(f"{out}/driver.log").read()
t0 = int(re.search(r"measure_start (\d+)", drv).group(1))
t1 = int(re.search(r"measure_end (\d+)", drv).group(1))
p = []
for line in open(f"{out}/gc.pauses"):
    end, dur = map(int, line.split()[:2])
    if t0 <= end <= t1:
        p.append(dur / 1e6)
p.sort()
pct = lambda a, q: a[min(len(a) - 1, int(len(a) * q))] if a else 0
mins = (t1 - t0) / 60e9
rss, ticks = [], []
for line in open(f"{out}/samples.txt"):
    f = line.split()
    if len(f) >= 2 and f[1].isdigit(): rss.append(int(f[1]) // 1024)
    if len(f) >= 3: ticks.append(float(f[2]) * 1000)
al = [tuple(map(int, l.split())) for l in open(f"{out}/gc.pauses.allocs")]
al = [a for a in al if t0 <= a[0] <= t1]
alloc_rate = (al[-1][1] - al[0][1]) / ((al[-1][0] - al[0][0]) / 1e9) / 1048576 if len(al) > 1 else 0
perf = open(f"{out}/perf.log").read()
m = re.search(r"Average publish rate: (\d+)", perf)
print(f"{v:5} {mode:6} gcs/min {len(p)/mins:6.1f}  pause p50 {pct(p,.5):6.1f} p99 {pct(p,.99):6.1f} max {max(p) if p else 0:6.1f} ms  gc ms/min {sum(p)/mins:7.1f} | "
      f"stats tick p50 {pct(sorted(ticks),.5):5.1f} max {max(ticks) if ticks else 0:6.1f} ms | rss peak {max(rss)} end {rss[-1]} MB | pub/s {m.group(1) if m else '-'} | alloc {alloc_rate:6.1f} MB/s")

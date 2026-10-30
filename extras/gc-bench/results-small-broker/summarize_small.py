import sys, re
# summarize_small.py <variant> <mode> <run dir>: one line with pauses, GC time and RSS (MB, 1 decimal)
v, mode, out = sys.argv[1:4]
drv = open(f"{out}/driver.log").read()
t0 = int(re.search(r"measure_start (\d+)", drv).group(1))
t1 = int(re.search(r"measure_end (\d+)", drv).group(1))
p = sorted(int(l.split()[1]) / 1e6 for l in open(f"{out}/gc.pauses") if t0 <= int(l.split()[0]) <= t1)
pct = lambda a, q: a[min(len(a) - 1, int(len(a) * q))] if a else 0
mins = (t1 - t0) / 60e9
kb = lambda f: int(open(f"{out}/{f}").read().split()[0])
sm = {m.group(1): int(m.group(2)) for m in re.finditer(r"^(\w+):\s+(\d+) kB", open(f"{out}/smaps_rollup.txt").read(), re.M)}
perf = open(f"{out}/perf.log").read()
m = re.search(r"Average publish rate: (\d+)", perf)
print(f"{v:9} {mode:5} gcs/min {len(p)/mins:5.1f} pause p50 {pct(p,.5):5.2f} p90 {pct(p,.9):5.2f} max {max(p) if p else 0:6.2f} ms "
      f"gc ms/min {sum(p)/mins:6.1f} | rss start {kb('rss_start.txt')/1024:6.1f} end {kb('rss_end.txt')/1024:6.1f} | "
      f"smaps rss {sm['Rss']/1024:6.1f} pss {sm['Pss']/1024:6.1f} anon {sm['Anonymous']/1024:6.1f} MB | pub/s {m.group(1) if m else '-'}")

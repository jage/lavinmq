import sys, re, statistics
r = sys.argv[1]
d = open(f"{r}/driver.log").read()
t0 = int(re.search(r"measure_start (\d+)", d).group(1)); t1 = int(re.search(r"measure_end (\d+)", d).group(1))
rows = [list(map(int, l.split())) for l in open(f"{r}/gc.pauses")]
rows = [x for x in rows if t0 <= x[0] <= t1 and len(x) == 4]
med = lambda i: statistics.median(x[i] for x in rows) / 1e6
print(f"{sys.argv[2]:28} n={len(rows):3}  total p50 {med(1):6.1f} ms  stop-world {med(2):5.1f} ms  mark {med(3):6.1f} ms  other {med(1)-med(2)-med(3):5.1f} ms")

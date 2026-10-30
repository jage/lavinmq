# per_minute.py <run dir>: per steady minute: GC heap (last scrape), max RSS, collections, GC ms,
# max pause, max watchdog lateness, HTTP poll latencies; '!' marks anything over 7 s
import sys

d = sys.argv[1]
ph = {l.split()[0]: l.split()[1:] for l in open(f"{d}/phases.txt")}
t0, t1 = int(ph["steady_start"][0]), int(ph["steady_end"][0])
rows = lambda f: [l.split() for l in open(f"{d}/{f}") if l.strip()]
scr = [(int(r[0]), int(r[3])) for r in rows("scrapes.txt") if len(r) >= 4 and r[3]]
rss = [(int(r[0]), int(r[1])) for r in rows("rss.txt") if len(r) >= 2 and r[1].isdigit()]
gcs = [(int(r[0]), int(r[1])) for r in rows("gc.pauses")]
wd = [(int(r[0]), int(r[1])) for r in rows("gc.pauses.watchdog")]
try:
    polls = [(int(r[0]), int(r[1]), r[2]) for r in rows("polls.txt")]
except OSError:
    polls = []
mark = lambda s: f"{s}!" if s > 7 else str(s)
print("| min | GC heap MB | RSS MB | GCs | GC ms | max pause ms | watchdog max s | polls s (HTTP code) |")
print("|---|---|---|---|---|---|---|---|")
m = 0
while t0 + m * 60e9 < t1:
    a, b = t0 + m * 60e9, min(t1, t0 + (m + 1) * 60e9)
    inm = lambda xs: [x for x in xs if a <= x[0] < b]
    h = [x[1] for x in scr if x[0] < b]
    p = [x[1] / 1e6 for x in inm(gcs)]
    w = max((x[1] / 1e9 for x in inm(wd)), default=0)
    pl = " ".join(f"{mark(round(x[1] / 1000, 1))} ({x[2]})" for x in inm(polls))
    print(f"| {m + 1} | {h[-1] >> 20 if h else ''} | {max((x[1] for x in inm(rss)), default=0) >> 10} | {len(p)} | "
          f"{round(sum(p))} | {round(max(p, default=0))} | {mark(round(w, 2))} | {pl} |")
    m += 1

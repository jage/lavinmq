# summarize_sim.py <variant> <run dir>: storm and steady GC pause and watchdog stats as one JSON line
import json, re, sys

v, d = sys.argv[1], sys.argv[2]
ph = {}
for line in open(f"{d}/phases.txt"):
    k, *rest = line.split()
    ph[k] = rest
t = {k: int(ph[k][0]) for k in ("storm_start", "storm_end", "steady_start", "steady_end") if k in ph}
pauses = [tuple(map(int, l.split())) for l in open(f"{d}/gc.pauses")]  # end_ns dur_ns stop_ns mark_ns
wd = [tuple(map(int, l.split())) for l in open(f"{d}/gc.pauses.watchdog")]  # wakeup_ns lateness_ns


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(len(xs) * p))] if xs else 0


def stretch(late, thr):
    # longest run of consecutive 1 s sleeps that each overran by more than thr: wall time it spans
    best = cur = 0
    for x in late:
        cur = cur + 1e9 + x if x > thr else 0
        best = max(best, cur)
    return round(best / 1e9, 1)


def window(a, b):
    ps = [p[1] / 1e6 for p in pauses if a <= p[0] - p[1] and p[0] <= b]
    late = [w[1] for w in wd if a <= w[0] <= b]
    mins = (b - a) / 60e9
    return {
        "secs": round((b - a) / 1e9, 1),
        "gcs": len(ps), "gcs_per_min": round(len(ps) / mins, 1) if mins else 0,
        "p50": round(pct(ps, 0.5), 1), "p90": round(pct(ps, 0.9), 1), "max": round(max(ps, default=0), 1),
        "gc_total_ms": round(sum(ps)), "gc_ms_per_min": round(sum(ps) / mins) if mins else 0,
        "wd_max_s": round(max(late, default=0) / 1e9, 2), "wd_p99_s": round(pct(late, 0.99) / 1e9, 2),
        "late_1s": stretch(late, 1e9), "late_3s": stretch(late, 3e9), "late_7s": stretch(late, 7e9),
    }


out = {"variant": v, "run": d.rstrip("/").split("/")[-1]}
out["storm"] = window(t["storm_start"], t["storm_end"])
if "steady_end" in t:
    out["steady"] = window(t["steady_start"], t["steady_end"])
drv = []
for i in (0, 1):
    for l in open(f"{d}/driver{i}.log"):
        if l.startswith("storm_end"):
            m = re.search(r"took (\S+)s handshake p50 (\S+)s p99 (\S+)s max (\S+)s timeouts (\d+) errors (.*)", l)
            drv.append(m.groups())
out["storm"]["connect_all_s"] = max(float(x[0]) for x in drv) if drv else None
out["storm"]["hs_p99_s"] = max(float(x[2]) for x in drv) if drv else None
out["storm"]["hs_max_s"] = max(float(x[3]) for x in drv) if drv else None
out["storm"]["timeouts"] = sum(int(x[4]) for x in drv)
out["storm"]["errors"] = [x[5] for x in drv]
log = open(f"{d}/broker.log", errors="replace").read()
out["broker_eof_handshake"] = len(re.findall(r"tried to establish connection", log))
out["mark_stack_overflows"] = len(re.findall(r"Mark stack overflow", log))
full = ph.get("rss_kb_at_full", [])
out["rss_mb_at_full"] = round(int(full[0]) / 1024) if full else None
end = ph.get("heap_bytes_at_end", [])
if end:
    out["heap_mb_at_end"] = round(int(float(end[0])) / 2**20)
    out["conns_at_end"] = int(float(end[2]))
    out["rss_mb_at_end"] = round(int(end[4]) / 1024)
try:
    c = open(f"{d}/census.txt").readline()
    out["census"] = c.strip()
except OSError:
    pass
print(json.dumps(out))

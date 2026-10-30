# tables.py: markdown tables for RESULTS.md from every r*/<variant>/minutes.txt
import json, glob, statistics
V = ["main", "main-socket", "digest", "digest-socket"]
runs = {}
for f in sorted(glob.glob("r*/*/minutes.txt")):
    j = json.loads(open(f).read().strip().splitlines()[-1])
    runs[j["run"]] = j
ids = [r for v in V for r in sorted(runs) if r.split("/")[1] == v]
b = lambda r, k: next(x for x in runs[r]["bins"] if x["bin"] == k)
print("Collections per minute (G = from GC_grow_table in parentheses), pre = broker start to measure_start\n")
print("| minute | " + " | ".join(ids) + " |"); print("|---" * (len(ids) + 1) + "|")
for k in ["pre"] + list(range(1, 21)):
    print(f"| {k} | " + " | ".join(f"{b(r, k)['n']} ({b(r, k)['G']})" for r in ids) + " |")
print("\nPer run\n")
print("| run | pre-window s | last G collection (min) | steady gcs/min (min 10-20) | steady GC ms/min | cum GC ms @5 | @10 | @20 | RSS MB @1 / @10 / @20 |")
print("|---|---|---|---|---|---|---|---|---|")
for r in ids:
    st = [b(r, k) for k in range(10, 21)]
    print(f"| {r} | {runs[r]['pre_s']} | {runs[r]['last_g_min']} | {sum(x['n'] for x in st) / 11:.2f} | {sum(x['ms'] for x in st) / 11:.0f} | "
          f"{b(r, 5)['cum_ms']:.0f} | {b(r, 10)['cum_ms']:.0f} | {b(r, 20)['cum_ms']:.0f} | {b(r, 1)['rss_end']} / {b(r, 10)['rss_end']} / {b(r, 20)['rss_end']} |")
print("\nPer variant (mean over rounds)\n")
print("| variant | runs | min 1 gcs | min 2-9 gcs/min | steady gcs/min (10-20) | cum GC ms @5 | @10 | @20 |")
print("|---|---|---|---|---|---|---|---|")
for v in V:
    rs = [r for r in ids if r.split("/")[1] == v]
    if not rs: continue
    m = lambda f: statistics.mean(f(r) for r in rs)
    print(f"| {v} | {len(rs)} | {m(lambda r: b(r, 1)['n']):.1f} | {m(lambda r: sum(b(r, k)['n'] for k in range(2, 10)) / 8):.2f} | "
          f"{m(lambda r: sum(b(r, k)['n'] for k in range(10, 21)) / 11):.2f} | {m(lambda r: b(r, 5)['cum_ms']):.0f} | {m(lambda r: b(r, 10)['cum_ms']):.0f} | {m(lambda r: b(r, 20)['cum_ms']):.0f} |")

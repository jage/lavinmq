# tables.py <runs.jsonl>: per-run and per-variant median markdown tables
import sys, json, statistics, collections
runs = [json.loads(l) for l in open(sys.argv[1])]
V = ["main", "main-socket", "digest", "digest-socket", "digest-socket-1k"]
fin = lambda d: ", ".join(f"{k} {v:g}" for k, v in sorted(d["fin"].items(), key=lambda x: -x[1]))
paths = lambda p: ", ".join(f"{k} {v}" for k, v in sorted(p.items(), key=lambda x: -x[1]))
print("| run | gcs/min | gcs/min 2nd half | p50 | p90 | max ms | GC ms/min | GC ms/min 2nd half | RSS med / peak MB | alloc MiB/s | finalizer registrations/s | socket unreg/s | trigger (whole window) |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
for d in sorted(runs, key=lambda d: (V.index(d["variant"]), d["run"])):
    print(f"| {d['run']} | {d['gcs_min']:g} | {d['gcs_min_late']:g} | {d['p50']:g} | {d['p90']:g} | {d['max']:g} | {d['gc_ms_min']:g} | {d['gc_ms_min_late']:g} | {d['rss_med']} / {d['rss_peak']} | {d['alloc_mb_s']:g} | {fin(d)} | {d['unreg_s'] if d['unreg_s'] is not None else '-'} | {paths(d['paths'])} |")
print()
print("| variant | runs | gcs/min | gcs/min 2nd half | p50 ms | max ms | GC ms/min | GC ms/min 2nd half | RSS med MB | TCPSocket reg/s | Digest reg/s | socket unreg/s | collections via grow_table / collect_or_expand (all runs) |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
med = lambda xs: statistics.median(xs)
for v in V:
    rs = [d for d in runs if d["variant"] == v]
    if not rs: continue
    tot = collections.Counter()
    for d in rs: tot.update(d["paths"])
    n = sum(tot.values())
    share = " / ".join(f"{tot.get(k, 0)} ({100 * tot.get(k, 0) / n:.0f}%)" for k in ("grow_table", "collect_or_expand"))
    other = n - tot.get("grow_table", 0) - tot.get("collect_or_expand", 0)
    if other: share += f", other {other}"
    u = [d["unreg_s"] for d in rs if d["unreg_s"] is not None]
    print(f"| {v} | {len(rs)} | {med([d['gcs_min'] for d in rs]):g} | {med([d['gcs_min_late'] for d in rs]):g} | {med([d['p50'] for d in rs]):g} | {med([d['max'] for d in rs]):g} | {med([d['gc_ms_min'] for d in rs]):g} | {med([d['gc_ms_min_late'] for d in rs]):g} | {med([d['rss_med'] for d in rs]):g} | {med([d['fin'].get('TCPSocket', 0) for d in rs]):g} | {med([d['fin'].get('OpenSSL::Digest', 0) for d in rs]):g} | {med(u) if u else '-'} | {share} |")

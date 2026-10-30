# report.py <runs.jsonl>: per-run table, per-variant medians and headline (main/combo ratios) as markdown
import sys, json, statistics as st
runs = [json.loads(l) for l in open(sys.argv[1])]
V = ["main", "combo16k", "combo32k"]
M = [("gcs_min", "coll/min"), ("p50", "p50 ms"), ("p90", "p90 ms"), ("max", "max ms"),
     ("gc_ms_min", "GC ms/min"), ("rss_peak", "RSS peak MB"), ("rss_end", "RSS end MB")]
fmt = lambda x: f"{x:.1f}" if isinstance(x, float) else str(x)
for mode in ["idle", "churn"]:
    rs = [r for r in runs if r["mode"] == mode]
    print(f"\n### {mode}: per run\n")
    print("| round | variant | " + " | ".join(h for _, h in M) + " | max at (s) | finalizers/s |")
    print("|" + "---|" * (len(M) + 4))
    for r in sorted(rs, key=lambda r: (r["round"], V.index(r["variant"]))):
        fin = ", ".join(f"{k} {v}" for k, v in sorted(r["fin_per_s"].items(), key=lambda x: -x[1]))
        print(f"| {r['round']} | {r['variant']} | " + " | ".join(fmt(r[k]) for k, _ in M) + f" | {r['max_at_s']} | {fin} |")
    med = {v: {k: st.median(r[k] for r in rs if r["variant"] == v) for k, _ in M} for v in V}
    finmed = {v: {} for v in V}
    for v in V:
        for k in sorted({k for r in rs if r["variant"] == v for k in r["fin_per_s"]}):
            finmed[v][k] = st.median(r["fin_per_s"].get(k, 0) for r in rs if r["variant"] == v)
    print(f"\n### {mode}: medians (n={len(rs)//3} per variant) and main/combo ratio\n")
    print("| metric | main | combo16k | combo32k | main/combo16k | main/combo32k |")
    print("|---|---|---|---|---|---|")
    for k, h in M:
        a, b, c = med["main"][k], med["combo16k"][k], med["combo32k"][k]
        print(f"| {h} | {a:.1f} | {b:.1f} | {c:.1f} | {a/b:.2f}x | {a/c:.2f}x |")
    for k in sorted(set(finmed["main"]) | set(finmed["combo16k"])):
        print(f"| finalizers/s {k} | " + " | ".join(f"{finmed[v].get(k, 0):.1f}" for v in V) + " | | |")

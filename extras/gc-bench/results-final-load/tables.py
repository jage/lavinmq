# tables.py: markdown tables (per run, per-variant medians, headline ratios) from runs/*/
import glob, json, os, statistics, subprocess, sys
here = os.path.dirname(os.path.abspath(__file__))
dirs = sorted(glob.glob(f"{here}/runs/*-r*"), key=lambda d: (int(d.rsplit("-r", 1)[1]), ["main", "combo16k", "combo32k"].index(d.split("/")[-1].rsplit("-r", 1)[0])))
rows = [json.loads(l) for l in subprocess.run([sys.executable, "-I", f"{here}/analyze.py", *dirs], capture_output=True, text=True, check=True).stdout.splitlines()]
fin = lambda r: ", ".join(f"{k} {v:g}" for k, v in sorted(r["fin_s"].items(), key=lambda kv: -kv[1]))
print("| run | GCs/min | p50 ms | p90 ms | max ms | max at s | GC ms/min | RSS peak/end MB | finalizer registrations/s | warm-up GCs (max ms) |")
print("|---|---|---|---|---|---|---|---|---|---|")
for r in rows:
    print(f"| {r['run']} | {r['gcs_min']} | {r['p50']} | {r['p90']} | {r['max']} | {r['max_at_s']} | {r['gc_ms_min']} | {r['rss_peak']}/{r['rss_end']} | {fin(r)} | {r['pre_n']} ({r['pre_max']}) |")
keys = [("gcs_min", "GCs/min"), ("p50", "pause p50 ms"), ("p90", "pause p90 ms"), ("max", "pause max ms"), ("gc_ms_min", "GC ms/min"), ("rss_peak", "RSS peak MB"), ("rss_end", "RSS end MB")]
med = {}
for v in ["main", "combo16k", "combo32k"]:
    rs = [r for r in rows if r["run"].rsplit("-r", 1)[0] == v]
    med[v] = {k: statistics.median(r[k] for r in rs) for k, _ in keys}
    med[v]["n"] = len(rs)
    med[v]["range"] = {k: (min(r[k] for r in rs), max(r[k] for r in rs)) for k, _ in keys}
print()
print(f"| metric (median, range) | main (n={med['main']['n']}) | combo16k (n={med['combo16k']['n']}) | combo32k (n={med['combo32k']['n']}) | main/combo16k | main/combo32k |")
print("|---|---|---|---|---|---|")
f = lambda v, k: f"{med[v][k]:g} ({med[v]['range'][k][0]:g}-{med[v]['range'][k][1]:g})"
for k, label in keys:
    print(f"| {label} | {f('main', k)} | {f('combo16k', k)} | {f('combo32k', k)} | {med['main'][k] / med['combo16k'][k]:.2f}x | {med['main'][k] / med['combo32k'][k]:.2f}x |")

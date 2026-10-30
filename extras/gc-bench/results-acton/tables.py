# tables.py <results.txt>: markdown table from run_idle.sh / run_load.sh output, one row per run
# (summarize.py line followed by its phases.py line), in the order the configurations first appear.
import sys, re

rows = {}
summary = None
for line in open(sys.argv[1]):
    if "gcs/min" in line:
        summary = line
        continue
    m = re.match(r"(\S+)-r(\d+)\s+n=\s*(\d+)\s+total p50\s+([\d.]+) ms\s+stop-world\s+([\d.]+) ms\s+mark\s+([\d.]+)", line)
    if not m or summary is None:
        continue
    label, run = m.group(1), m.group(2)
    s = summary
    num = lambda pat: re.search(pat, s).group(1)
    rows.setdefault(label, []).append(dict(
        run=run, n=m.group(3), gcmin=num(r"gcs/min\s+([\d.]+)"), p50=num(r"pause p50\s+([\d.]+)"),
        p99=num(r"p99\s+([\d.]+)"), max=num(r"max\s+([\d.]+) ms  gc"), gcms=num(r"gc ms/min\s+([\d.]+)"),
        mark=m.group(6), stw=m.group(5), rss=num(r"rss peak (\d+)"), rssend=num(r"end (\d+) MB"),
        pub=num(r"pub/s (\S+)"), alloc=num(r"alloc\s+([\d.]+) MB/s")))
    summary = None

print("| config | run | GCs | GCs/min | pause p50 | p99 | max | mark p50 | GC ms/min | RSS peak/end MB | pub/s | alloc MB/s |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|")
for label, rs in rows.items():
    for r in sorted(rs, key=lambda r: r["run"]):
        print(f"| {label} | {r['run']} | {r['n']} | {r['gcmin']} | {r['p50']} | {r['p99']} | {r['max']} | {r['mark']} | {r['gcms']} | {r['rss']}/{r['rssend']} | {r['pub']} | {r['alloc']} |")

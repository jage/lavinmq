# tables.py: per-run rows and the scrape latency, from summary.txt and runs/*/
import glob, json, os

here = os.path.dirname(os.path.abspath(__file__))
rows = []
for l in open(f"{here}/summary.txt"):
    if "{" in l:
        rows.append((l.split("|")[0].strip(), json.loads(l[l.index("{"):])))


def scrape_max(run):
    try:
        return max(int(l.split()[1]) for l in open(f"{here}/runs/{run}/scrapes.txt") if len(l.split()) > 1)
    except (OSError, ValueError):
        return None


print("| run | variant | connect all s | storm GCs | storm p50 / p90 / max ms | storm GC total ms | storm watchdog max s | "
      "steady GCs/min | steady p50 / max ms | steady GC ms/min | steady watchdog max / p99 s | late >1 s stretch | "
      "conns | heap MB | RSS MB | max scrape ms |")
print("|" + "---|" * 16)
for tag, d in rows:
    s, t = d["storm"], d.get("steady", {})
    print(f"| {d['run']} | {d['variant']} | {s['connect_all_s']} | {s['gcs']} | {s['p50']} / {s['p90']} / {s['max']} | "
          f"{s['gc_total_ms']} | {s['wd_max_s']} | {t.get('gcs_per_min')} | {t.get('p50')} / {t.get('max')} | "
          f"{t.get('gc_ms_per_min')} | {t.get('wd_max_s')} / {t.get('wd_p99_s')} | "
          f"{max(s['late_1s'], t.get('late_1s', 0))} | {d.get('conns_at_end')} | {d.get('heap_mb_at_end')} | "
          f"{d.get('rss_mb_at_end')} | {scrape_max(d['run'])} |")

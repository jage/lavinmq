import re, json, sys
from collections import defaultdict
raw = sys.argv[1]
def num(p, l):
    m = re.search(p, l); return float(m.group(1)) if m else None
rows = []
def add(id, scen, metric, unit, better, file, keyf, valp, filt=lambda l: True, base="fix"):
    vals = defaultdict(list)
    for l in open(f"{raw}/{file}.txt"):
        if not filt(l): continue
        v = num(valp, l)
        if v is not None: vals[keyf(l)].append(v)
    rows.append(dict(id=id, scenario=scen, metric=metric, unit=unit, better=better, base=base, values=vals))
mv = lambda l: l.split()[1]
for sc, name in [("M1","Mark: 2M-node lists"),("M2","Mark: nodes with pointer-free leaves"),("M3","Mark: 6,500 parked fibers")]:
    for m in ([4] if sc=="M3" else [1,4]):
        add(f"{sc}-m{m}", sc, f"{name}, {m} marker{'s' if m>1 else ''}", "ms collect p50", "lower", sc, mv, r"collect p50\s+([\d.]+)", lambda l, m=m: f"markers  {m} " in l or f"markers {m} " in l)
for t in [1,2,4]:
    add(f"A1-{t}", "A1", f"Allocation, {t} thread{'s' if t>1 else ''}", "ns/step", "lower", "A1", mv, r"([\d.]+) ns/step", lambda l, t=t: f"threads {t} " in l)
for t in [1,2,4]:
    add(f"AX-{t}", "AX", f"Allocation attribution, {t} thread{'s' if t>1 else ''}", "ns/step", "lower", "AX", mv, r"([\d.]+) ns/step", lambda l, t=t: f"threads {t} " in l)
bv = lambda l: l.split()[2]
for s in [16, 1024]:
    f = lambda l, s=s: re.search(rf"size\s+{s} ", l) is not None
    lbl = "16 B" if s == 16 else "1 KiB"
    add(f"B1-{s}-con", "B1", f"Full speed {lbl}: consume rate", "msg/s", "higher", "B1", bv, r"con/s\s+(\d+)", f)
    add(f"B1-{s}-cpu", "B1", f"Full speed {lbl}: broker CPU", "µs/msg", "lower", "B1", bv, r"([\d.]+) us/msg", f)
    add(f"B1-{s}-gc", "B1", f"Full speed {lbl}: GC time", "ms/s", "lower", "B1", bv, r"gc ms/s\s+([\d.]+)", f)
    add(f"B1-{s}-max", "B1", f"Full speed {lbl}: pause max", "ms", "lower", "B1", bv, r"max\s+([\d.]+) ms", f)
for sc, name in [("B2","Idle, 2k connections"),("B3","Full load"),("B3U","Full load, unmap threshold 1")]:
    add(f"{sc}-p50", sc, f"{name}: pause p50", "ms", "lower", sc, bv, r"pause p50\s+([\d.]+)")
    add(f"{sc}-max", sc, f"{name}: pause max", "ms", "lower", sc, bv, r"max\s+([\d.]+) ms")
    add(f"{sc}-gc", sc, f"{name}: GC time", "ms/min", "lower", sc, bv, r"gc ms/min\s+([\d.]+)")
    add(f"{sc}-rss", sc, f"{name}: RSS peak", "MB", "lower", sc, bv, r"rss peak (\d+)")
bis = [l.split(None, 3) for l in open(f"{raw}/../bisect-alloc4.txt")]
bisect = [dict(commit=b[0], ns=int(b[1]), subject=b[3].strip()) for b in bis]
print(json.dumps(dict(rows=rows, bisect=bisect), separators=(",", ":")))

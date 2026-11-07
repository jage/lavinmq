"""One summary line of a measure.sh run: wall and CPU time, compiler phases, GC collections and
time from GC_PRINT_STATS, peak RSS."""
import re, sys
label, wl, out, rc, extra = sys.argv[1:6]
so = open(f"{out}/stdout", errors="replace").read()
se = open(f"{out}/stderr", errors="replace").read()

def t(lbl):
    m = re.search(re.escape(lbl) + r":\s+(?:.*?:\s+)?(\d\d):(\d\d):(\d\d\.\d+)", so)
    return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3)) if m else 0.0

sem = sum(t("Semantic (" + p + ")") for p in ["top level", "new", "type declarations", "abstract def check",
          "restrictions augmenter", "ivars initializers", "cvars initializers", "main", "cleanup", "recursive struct check"])
cg, obj, link = t("Codegen (crystal)"), t("Codegen (bc+obj)"), t("Codegen (linking)")
macro = sum(int(a) * 3600 + int(b) * 60 + float(c) for a, b, c in re.findall(r"^ - .*: (\d\d):(\d\d):(\d\d\.\d+)$", so, re.M))
gc = [int(a) * 1e6 + int(b) for a, b in re.findall(r"Complete collection took (\d+) ms (\d+) ns", se)]
w = re.search(r"Elapsed \(wall clock\) time \(h:mm:ss or m:ss\): ([\d:.]+)", se)
wall = sum(float(x) * 60 ** i for i, x in enumerate(reversed(w.group(1).split(":")))) if w else 0
num = lambda p: float(re.search(p, se).group(1)) if re.search(p, se) else 0
cpu = num(r"User time \(seconds\): ([\d.]+)") + num(r"System time \(seconds\): ([\d.]+)")
rss = int(num(r"Maximum resident set size \(kbytes\): (\d+)")) // 1024
print(f"{label:22} {wl:12} rc={rc} wall {wall:7.1f} s cpu {cpu:7.1f} s | semantic {sem:6.1f} codegen {cg:5.1f} "
      f"bc+obj {obj:6.1f} link {link:4.1f} macro {macro:5.1f} s | gc {len(gc):3d} colls {sum(gc)/1e9:6.2f} s "
      f"max {max(gc)/1e6 if gc else 0:5.0f} ms | rss {rss} MB | extra [{extra}]")

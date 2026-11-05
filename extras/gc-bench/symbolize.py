import sys, bisect, collections
syms = []
for l in open(sys.argv[1]):
    a, _, n = l.rstrip("\n").split(" ", 2)
    syms.append((int(a, 16), n))
addrs = [a for a, _ in syms]
def name(x):
    i = bisect.bisect_right(addrs, x) - 1
    return syms[i][1] if i >= 0 else hex(x)
skip = ("GC_", "__crystal_malloc", "GC.malloc", "backtrace", "~proc", "*GC::", "*Pointer(", "~procProc", "GC::")
chains = collections.Counter()
for l in open(sys.argv[2]):
    frames = [name(int(h, 16)) for h in l.split()[1:]]
    useful = [f for f in frames if not f.startswith(skip) and "GCPauses" not in f and "LibGC" not in f]
    chains[" <- ".join(f[:110] for f in useful[:6])] += 1
for c, n in chains.most_common(12):
    print(f"{n:4}  {c}\n")

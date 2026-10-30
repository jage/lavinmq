# leak_table.py <run dir>: per minute: connections, reachable TCPSocket and Fiber, closed sockets and
# dead fibers still reachable, live fibers, and where the dead ones are held
import glob, re, sys

d = sys.argv[1]
print("| min | connections | TCPSocket | Fiber | closed sockets | dead fibers | live fibers | sockets / fibers held only from roots |")
print("|---|---|---|---|---|---|---|---|")
scr = [l.split() for l in open(f"{d}/scrapes.txt") if len(l.split()) >= 5]
for m in range(1, 100):
    try:
        t = open(f"{d}/census-{m}.txt").read()
    except OSError:
        break
    g = lambda pat: (re.search(pat, t, re.M) or [None, "?"])[1]
    print(f"| {m} | {scr[min(len(scr) - 1, 2 + m * 4)][4] if scr else '?'} | {g(r'^\s*[\d.]+ MB\s+[\d.]+%\s+(\d+)\s+scan\s+TCPSocket$')} | "
          f"{g(r'^\s*[\d.]+ MB\s+[\d.]+%\s+(\d+)\s+scan\s+Fiber$')} | {g(r'closed TCPSocket: (\d+)')} | {g(r'dead Fiber: (\d+)')} | "
          f"{g(r'fibers by name \(digits as N\): (\d+)')} | {g(r'closed TCPSocket: \d+ reachable, (\d+)')} / {g(r'dead Fiber: \d+ reachable, (\d+)')} |")

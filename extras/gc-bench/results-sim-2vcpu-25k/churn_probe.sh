#!/bin/bash
# churn_probe.sh <rev>: builds <rev> (bundled libgc, with the hook) and runs storm + 150 s of
# 37 reconnects/s without message load, printing the GC heap growth rate over the steady phase.
# Used to find which commit on main stopped v2.10.x's per-reconnect heap growth.
set -eu
rev=$1 res=$(cd "$(dirname "$0")" && pwd) gcb=$(cd "$(dirname "$0")/.." && pwd)
src=$SCRATCH/src-bisect
[ -d $src ] || { git -C $gcb/../.. worktree add -q --detach $src $rev; (cd $src && shards install > /dev/null); }
git -C $src checkout -q --detach $rev
(cd $src && shards install > /dev/null 2>&1; make -s js views > /dev/null 2>&1 || true)
sed 's|require "./typetable"|require "./zz_typetable"|' $gcb/gc_pauses.cr > $src/src/zz_gc_pauses.cr
cp $gcb/typetable.cr $src/src/zz_typetable.cr
printf 'require "./zz_gc_pauses"\nrequire "./lavinmq"\n' > $src/src/zz_bench.cr
(cd $src && crystal build --release src/zz_bench.cr -o $SCRATCH/brokers/lavinmq-bisect > $SCRATCH/bisect-build.log 2>&1) || { rm -f $src/src/zz_*.cr; echo "$rev build failed"; exit 125; }
rm -f $src/src/zz_*.cr
pkill -f "$SCRATCH/brokers/lavinmq-" || true; pkill -f "$SCRATCH/bench/driver" || true; sleep 3
PERF=0 $res/run_sim.sh bisect $SCRATCH/runs/bisect 150 > /dev/null
python3 -I - $SCRATCH/runs/bisect $rev <<'PY'
import sys
d, rev = sys.argv[1], sys.argv[2]
ph = {l.split()[0]: int(l.split()[1]) for l in open(f"{d}/phases.txt") if l.split()[1].isdigit()}
s = [(int(l.split()[0]), int(l.split()[3])) for l in open(f"{d}/scrapes.txt") if len(l.split()) >= 4 and l.split()[3]]
s = [x for x in s if ph["steady_start"] <= x[0] <= ph["steady_end"]]
rate = (s[-1][1] - s[0][1]) / 2**20 / ((s[-1][0] - s[0][0]) / 60e9)
print(f"{rev[:10]} heap {s[0][1] >> 20} -> {s[-1][1] >> 20} MB, {rate:.0f} MB/min; census: {open(d + '/census.txt').readline().strip()}")
PY

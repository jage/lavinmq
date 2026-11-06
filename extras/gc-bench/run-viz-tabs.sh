#!/bin/bash
# lavinmq-bpf reports for every scenario of the matrix, one report per scenario comparing the
# variants (the report page's tabs). Reuses run-viz.sh's B1 profiles and B3 recordings when
# they exist in $SCRATCH/viz, adds the rest. Output: $SCRATCH/tabs/<scenario>/<variant>.{folded,trace,lines}
# and $SCRATCH/tabs/<scenario>.html. Needs root and bpftrace.
set -eu
: "${SCRATCH:?set SCRATCH}"
S=$SCRATCH; T=$S/tabs; V=$S/viz; B=$S/bpf/lavinmq-bpf
here=$(cd "$(dirname "$0")" && pwd)
export SCRATCH SOURCE_URL=https://github.com/cloudamqp/lavinmq/blob/359fab1c
mkdir -p "$T"/{mark,alloc,b1,b2,b3}
base=$(crystal env CRYSTAL_LIBRARY_PATH)

profile() { # profile <out base> <seconds> <command...>: profile a microbenchmark while it runs
  local out=$1 secs=$2; shift 2
  "$@" > "$out.log" 2>&1 &
  local pid=$!
  sleep 8   # heap build / warm-up
  OUT=$out "$B" profile $pid "$secs" > "$out.bpf.log" 2>&1
  kill $pid 2>/dev/null; wait $pid 2>/dev/null || true
}

# Mark: pointer-free leaves heap (M2), 4 markers, collections back to back
for v in fix fix-pf acton acton-nopf; do
  CRYSTAL_LIBRARY_PATH=$S/gcbuild/install-$v/lib:$base crystal build --release "$here/mark.cr" -o "$S/mark/mark-$v"
  LEAVES=1 GC_MARKERS=4 COLLECTS=1000 profile "$T/mark/$v" 10 "$S/mark/mark-$v" 0 2000000
done
OUT=$T/mark "$B" report "$T"/mark/{fix,fix-pf,acton,acton-nopf}.folded

# Allocation: 4 threads
for v in fix fix-fl acton acton-noatomicfl; do
  profile "$T/alloc/$v" 8 "$S/mark/alloc-$v" 4 400 200000
done
OUT=$T/alloc "$B" report "$T"/alloc/{fix,fix-fl,acton,acton-noatomicfl}.folded

# B1: full speed, 16 B messages
for v in fix acton; do
  if [ -f "$V/b1-$v.folded" ]; then cp "$V/b1-$v.folded" "$T/b1/$v.folded"
  else BPF=profile RUN=viz "$S/bench/run_throughput.sh" $v 16 30; cp "$S/runs/tp-$v-16-viz/profile.folded" "$T/b1/$v.folded"; fi
done
OUT=$T/b1 "$B" report "$T"/b1/{fix,acton}.folded

# B2: idle broker with 2,000 connections and a forced GC every 3 s, 20 s recordings
for v in stock fix acton; do
  (cd "$S/bench" && BPF=record BPF_AT=20 BPF_SECS=20 PERF=0 FLAP=0 ./run_broker_forcegc.sh $v none 60 | cut -c1-120)
  cp "$S/runs/$v-none/record.trace" "$T/b2/$v.trace"; cp "$S/runs/$v-none/record.lines" "$T/b2/$v.lines"
done
OUT=$T/b2 "$B" report "$T"/b2/{stock,fix,acton}.trace

# B3: full load, 20 s recordings 60 s into the window
for v in stock fix acton; do
  if [ -f "$V/b3-$v.trace" ]; then cp "$V/b3-$v.trace" "$T/b3/$v.trace"; cp "$V/b3-$v.lines" "$T/b3/$v.lines"
  else (cd "$S/bench" && BPF=record BPF_AT=60 BPF_SECS=20 ./run_broker.sh $v churn 120 | cut -c1-120)
    cp "$S/runs/$v-churn/record.trace" "$T/b3/$v.trace"; cp "$S/runs/$v-churn/record.lines" "$T/b3/$v.lines"; fi
done
OUT=$T/b3 "$B" report "$T"/b3/{stock,fix,acton}.trace
ls -la "$T"/*.html

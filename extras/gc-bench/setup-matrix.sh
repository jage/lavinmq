#!/bin/bash
# Builds everything the Acton attribution matrix needs (PLAN-acton.md), from this checkout
# (upstream main + the bench tools), with the Crystal on PATH (1.22.2 with 84codes' libgc 8.2.12):
#   $SCRATCH/gcbuild/install-<v>   libgc variants (build-libgc-matrix.sh)
#   $SCRATCH/brokers/lavinmq-<v>   broker per libgc, with the gc_pauses.cr hook and frame pointers
#   $SCRATCH/brokers/lavinmqperf, $SCRATCH/bench/driver, $SCRATCH/mark/{mark,alloc}-<v>
# Run from the repo root: SCRATCH=$HOME/gcbench extras/gc-bench/setup-matrix.sh
set -eu
: "${SCRATCH:?set SCRATCH}"
repo=$(cd "$(dirname "$0")/../.." && pwd)
here=$repo/extras/gc-bench
variants=${VARIANTS:-stock fix fix-pf acton acton-nopf acton-noinl}
mkdir -p "$SCRATCH"/{bench,brokers,runs,mark}
[ -d "$SCRATCH/gcbuild/install-acton" ] || VARIANTS="$variants" "$here/build-libgc-matrix.sh" "$SCRATCH/gcbuild"
base=$(crystal env CRYSTAL_LIBRARY_PATH)
libpath() { echo "$SCRATCH/gcbuild/install-$1/lib:$base"; }
cp "$here"/{summarize.py,phases.py,run_broker.sh,run_broker_forcegc.sh,run_throughput.sh} "$SCRATCH/bench/"
cd "$repo"
[ -d lib ] || shards install --production > /dev/null
make -s js views > /dev/null
[ -x "$SCRATCH/brokers/lavinmqperf" ] || crystal build --release src/lavinmqperf.cr -o "$SCRATCH/brokers/lavinmqperf"
[ -x "$SCRATCH/bench/driver" ] || CRYSTAL_PATH="$repo/lib:$(crystal env CRYSTAL_PATH)" crystal build --release "$here/driver.cr" -o "$SCRATCH/bench/driver"
for v in $variants; do
  CRYSTAL_LIBRARY_PATH=$(libpath $v) crystal build --release "$here/mark.cr" -o "$SCRATCH/mark/mark-$v"
  CRYSTAL_LIBRARY_PATH=$(libpath $v) crystal build --release "$here/alloc.cr" -o "$SCRATCH/mark/alloc-$v"
done
echo "microbenchmarks built"
sed 's|require "./typetable"|require "./zz_typetable"|' "$here/gc_pauses.cr" > src/zz_gc_pauses.cr
cp "$here/typetable.cr" src/zz_typetable.cr
printf 'require "./zz_gc_pauses"\nrequire "./lavinmq"\n' > src/zz_bench.cr
trap 'rm -f src/zz_*.cr' EXIT
for v in $variants; do
  CRYSTAL_LIBRARY_PATH=$(libpath $v) crystal build --release --frame-pointers always src/zz_bench.cr \
    -o "$SCRATCH/brokers/lavinmq-$v" > "$SCRATCH/brokers/build-$v.log" 2>&1
  echo "built broker $v"
done

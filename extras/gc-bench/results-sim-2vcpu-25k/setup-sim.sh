#!/bin/bash
# Setup for the 2-vCPU, many-connection simulation: like results-final-load/setup-final.sh, with
# brokers built from upstream main baaa3ea (main, bundled libgc), PR 2584 142910d +
# zz_socket_unregister.cr against bdwgc 8.2.8 + global patch + 32768-entry initial mark stack
# (combo32k), and tag v2.10.2 (v2102, bundled libgc). Run after build-libgc.sh (VARIANTS=global32k)
# and with Crystal 1.21.0 on PATH.
#   SCRATCH=$HOME/gcbench extras/gc-bench/results-sim-2vcpu-25k/setup-sim.sh
set -eu
: "${SCRATCH:?set SCRATCH}"
here=$(cd "$(dirname "$0")" && pwd)
gcb=$(cd "$here/.." && pwd)
repo=$(cd "$gcb/../.." && pwd)
(cd "$repo" && shards install > /dev/null)
base=$(crystal env CRYSTAL_LIBRARY_PATH)
CRYSTAL_PATH="$repo/lib:$(crystal env CRYSTAL_PATH)" crystal build --release "$gcb/driver.cr" -o "$SCRATCH/bench/driver"
[ -x "$SCRATCH/brokers/lavinmqperf" ] || (cd "$repo" && crystal build --release src/lavinmqperf.cr -o "$SCRATCH/brokers/lavinmqperf")
git -C "$repo" fetch -q https://github.com/cloudamqp/lavinmq pull/2584/head 'refs/tags/v2.10.2:refs/tags/v2.10.2'
for s in main:baaa3ea digest:142910d v2102:v2.10.2; do
  name=${s%%:*} rev=${s#*:} src=$SCRATCH/src-${s%%:*}
  if [ ! -d "$src" ]; then
    git -C "$repo" worktree add -q --detach "$src" "$rev"
    (cd "$src" && shards install > /dev/null)
  fi
  (cd "$src" && make -s js views > /dev/null 2>&1)
  sed 's|require "./typetable"|require "./zz_typetable"|' "$gcb/gc_pauses.cr" > "$src/src/zz_gc_pauses.cr"
  cp "$gcb/typetable.cr" "$src/src/zz_typetable.cr"
  if [ $name = digest ]; then
    cp "$here/zz_socket_unregister.cr" "$src/src/"
    printf 'require "./zz_gc_pauses"\nrequire "./zz_socket_unregister"\nrequire "./lavinmq"\n' > "$src/src/zz_bench.cr"
  else
    printf 'require "./zz_gc_pauses"\nrequire "./lavinmq"\n' > "$src/src/zz_bench.cr"
  fi
done
build() { # <broker name> <source> <lib path>
  (cd "$SCRATCH/src-$2" && CRYSTAL_LIBRARY_PATH=$3 crystal build --release src/zz_bench.cr -o "$SCRATCH/brokers/lavinmq-$1")
  echo "built broker $1"
}
build main main "$base"
build combo32k digest "$SCRATCH/gcbuild/install-global32k/lib:$base"
build v2102 v2102 "$base"
echo "setup done"

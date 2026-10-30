#!/bin/bash
# Builds the four brokers of this experiment with Crystal's bundled libgc:
# main (baaa3ea), main-socket, digest (142910d, PR 2584), digest-socket.
# Expects $SCRATCH/src-main and $SCRATCH/src-digest worktrees (shards installed).
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
res=$here/results-main-finalizers-load
lib=$(crystal env CRYSTAL_LIBRARY_PATH)
for base in main digest; do
  src=$SCRATCH/src-$base
  (cd "$src" && make -s js views > /dev/null 2>&1)
  sed 's|require "./typetable"|require "./zz_typetable"|' "$here/gc_pauses.cr" > "$src/src/zz_gc_pauses.cr"
  cp "$here/typetable.cr" "$src/src/zz_typetable.cr"
  cp "$res/zz_socket_unregister.cr" "$src/src/zz_socket_unregister.cr"
  printf 'require "./zz_gc_pauses"\nrequire "./lavinmq"\n' > "$src/src/zz_bench.cr"
  (cd "$src" && CRYSTAL_LIBRARY_PATH=$lib crystal build --release src/zz_bench.cr -o "$SCRATCH/brokers/lavinmq-$base")
  printf 'require "./zz_gc_pauses"\nrequire "./zz_socket_unregister"\nrequire "./lavinmq"\n' > "$src/src/zz_bench.cr"
  (cd "$src" && CRYSTAL_LIBRARY_PATH=$lib crystal build --release src/zz_bench.cr -o "$SCRATCH/brokers/lavinmq-$base-socket")
  rm -f "$src"/src/zz_*.cr
  echo "built $base, $base-socket"
done

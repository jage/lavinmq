#!/bin/bash
# Builds the three brokers: main (baaa3ea, bundled libgc) and combo16k/combo32k (142910d + socket
# finalizer drop + bdwgc 8.2.8 global patch with a 16k/32k initial mark stack), all with the GC hook.
set -eu
: "${SCRATCH:?}"
here=$(cd "$(dirname "$0")/.." && pwd)
base=$(crystal env CRYSTAL_LIBRARY_PATH)
prep() { # <src> <with socket snippet?>
  local src=$1
  (cd "$src" && [ -d lib ] || shards install > /dev/null; make -s js views > /dev/null 2>&1 || true)
  sed 's|require "./typetable"|require "./zz_typetable"|' "$here/gc_pauses.cr" > "$src/src/zz_gc_pauses.cr"
  cp "$here/typetable.cr" "$src/src/zz_typetable.cr"
  if [ "$2" = 1 ]; then
    cp "$here/results-final-idle-churn/zz_socket_unregister.cr" "$src/src/"
    printf 'require "./zz_gc_pauses"\nrequire "./zz_socket_unregister"\nrequire "./lavinmq"\n' > "$src/src/zz_bench.cr"
  else
    printf 'require "./zz_gc_pauses"\nrequire "./lavinmq"\n' > "$src/src/zz_bench.cr"
  fi
}
build() { # <name> <src> <libpath>
  (cd "$2" && CRYSTAL_LIBRARY_PATH=$3 crystal build --release src/zz_bench.cr -o "$SCRATCH/brokers/lavinmq-$1")
  echo "built broker $1"
}
prep "$SCRATCH/src-main" 0
prep "$SCRATCH/src-combo" 1
build main "$SCRATCH/src-main" "$base"
build combo16k "$SCRATCH/src-combo" "$SCRATCH/gcbuild/install-global16k/lib:$base"
build combo32k "$SCRATCH/src-combo" "$SCRATCH/gcbuild/install-global32k/lib:$base"

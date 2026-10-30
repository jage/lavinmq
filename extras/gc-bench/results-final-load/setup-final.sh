#!/bin/bash
# Setup for the final-load comparison: like setup.sh, but brokers are built from upstream main
# baaa3ea (main) and PR 2584 142910d + src/zz_socket_unregister.cr (combo16k, combo32k).
#   SCRATCH=$HOME/gcbench extras/gc-bench/results-final-load/setup-final.sh
set -eu
: "${SCRATCH:?set SCRATCH}"
here=$(cd "$(dirname "$0")" && pwd)
gcb=$(cd "$here/.." && pwd)
repo=$(cd "$gcb/../.." && pwd)
mkdir -p "$SCRATCH"/{bench,brokers,runs,cr}
if [ ! -x "$SCRATCH/cr/crystal-1.21.0-1/bin/crystal" ]; then
  curl -sSfL https://github.com/crystal-lang/crystal/releases/download/1.21.0/crystal-1.21.0-1-linux-x86_64.tar.gz | tar xz -C "$SCRATCH/cr"
fi
cat > "$SCRATCH/env.sh" <<ENV
export SCRATCH=$SCRATCH
export PATH=$SCRATCH/cr/crystal-1.21.0-1/bin:\$PATH
ENV
. "$SCRATCH/env.sh"
sudo apt-get install -y -q liblz4-dev zlib1g-dev > /dev/null || true
(cd "$repo" && shards install > /dev/null)
VARIANTS="global16k global32k" "$gcb/build-libgc.sh" "$SCRATCH/gcbuild"
base=$(crystal env CRYSTAL_LIBRARY_PATH)
cp "$gcb"/{summarize.py,phases.py,fincount.py,run_broker.sh} "$SCRATCH/bench/"
CRYSTAL_PATH="$repo/lib:$(crystal env CRYSTAL_PATH)" crystal build --release "$gcb/driver.cr" -o "$SCRATCH/bench/driver"
(cd "$repo" && crystal build --release src/lavinmqperf.cr -o "$SCRATCH/brokers/lavinmqperf")
git -C "$repo" fetch -q https://github.com/cloudamqp/lavinmq pull/2584/head
for s in main:baaa3ea digest:142910d; do
  name=${s%%:*} rev=${s#*:} src=$SCRATCH/src-${s%%:*}
  [ -d "$src" ] || { git -C "$repo" worktree add -q --detach "$src" "$rev"; ln -s "$repo/lib" "$src/lib"; }
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
build combo16k digest "$SCRATCH/gcbuild/install-global16k/lib:$base"
build combo32k digest "$SCRATCH/gcbuild/install-global32k/lib:$base"
echo "setup done: source $SCRATCH/env.sh"

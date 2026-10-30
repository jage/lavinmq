#!/bin/bash
# setup.sh variant: brokers built from upstream main baaa3ea (no digest fix), libgc variants
# bundled, global and global32k.
set -eu
: "${SCRATCH:?set SCRATCH}"
repo=$(cd "$(dirname "$0")/../../.." && pwd)
here=$repo/extras/gc-bench
mkdir -p "$SCRATCH"/{bench,brokers,runs,cr}
if [ ! -x "$SCRATCH/cr/crystal-1.21.0-1/bin/crystal" ]; then
  curl -sSfL https://github.com/crystal-lang/crystal/releases/download/1.21.0/crystal-1.21.0-1-linux-x86_64.tar.gz | tar xz -C "$SCRATCH/cr"
fi
cat > "$SCRATCH/env.sh" <<ENV
export SCRATCH=$SCRATCH
export PATH=$SCRATCH/cr/crystal-1.21.0-1/bin:\$PATH
ENV
. "$SCRATCH/env.sh"
sudo apt-get install -y -q liblz4-dev zlib1g-dev > /dev/null 2>&1 || apt-get install -y -q liblz4-dev zlib1g-dev > /dev/null || true
(cd "$repo" && shards install > /dev/null)
VARIANTS="global global32k" "$here/build-libgc.sh" "$SCRATCH/gcbuild"
base=$(crystal env CRYSTAL_LIBRARY_PATH)
cp "$here"/{summarize.py,phases.py,fincount.py,run_broker.sh,run_broker_forcegc.sh} "$SCRATCH/bench/"
CRYSTAL_PATH="$repo/lib:$(crystal env CRYSTAL_PATH)" crystal build --release "$here/driver.cr" -o "$SCRATCH/bench/driver"
(cd "$repo" && crystal build --release src/lavinmqperf.cr -o "$SCRATCH/brokers/lavinmqperf")
src=$SCRATCH/broker-src
if [ ! -d "$src" ]; then
  git -C "$repo" fetch -q https://github.com/cloudamqp/lavinmq pull/2584/head
  git -C "$repo" worktree add -q --detach "$src" baaa3ea
  (cd "$src" && shards install > /dev/null)
fi
(cd "$src" && make -s js views > /dev/null 2>&1)
sed 's|require "./typetable"|require "./zz_typetable"|' "$here/gc_pauses.cr" > "$src/src/zz_gc_pauses.cr"
cp "$here/typetable.cr" "$src/src/zz_typetable.cr"
printf 'require "./zz_gc_pauses"\nrequire "./lavinmq"\n' > "$src/src/zz_bench.cr"
for v in bundled global global32k; do
  lib=$base; [ $v != bundled ] && lib="$SCRATCH/gcbuild/install-$v/lib:$base"
  (cd "$src" && CRYSTAL_LIBRARY_PATH=$lib crystal build --release src/zz_bench.cr -o "$SCRATCH/brokers/lavinmq-$v")
  printf 'lib LibGC\n  fun get_version = GC_get_version : UInt32\nend\nv = LibGC.get_version\nputs "#{v >> 16}.#{(v >> 8) & 0xff}.#{v & 0xff}"\n' > "$SCRATCH/gcver.cr"
  CRYSTAL_LIBRARY_PATH=$lib crystal build "$SCRATCH/gcver.cr" -o "$SCRATCH/gcver-$v"
  echo "built broker $v (libgc $("$SCRATCH/gcver-$v"))"
done
rm -f "$src"/src/zz_*.cr
echo "setup done: source $SCRATCH/env.sh"

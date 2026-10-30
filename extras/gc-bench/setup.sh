#!/bin/bash
# Sets up a fresh VM for the GC benchmarks. Run from the repo root with SCRATCH set:
#   SCRATCH=$HOME/gcbench extras/gc-bench/setup.sh
# Then `source $SCRATCH/env.sh`. Builds: Crystal 1.21, libgc variants, the test program `mark`
# against each libgc, the load driver, lavinmqperf, and a broker per libgc from
# gc-heap-stats + password-digest-without-finalizer with the GC hook compiled in.
set -eu
: "${SCRATCH:?set SCRATCH}"
repo=$(cd "$(dirname "$0")/../.." && pwd)
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
sudo apt-get update -q > /dev/null && sudo apt-get install -y -q liblz4-dev zlib1g-dev > /dev/null || true
(cd "$repo" && shards install > /dev/null)
"$here/build-libgc.sh" "$SCRATCH/gcbuild"
base=$(crystal env CRYSTAL_LIBRARY_PATH)
cp "$here"/{summarize.py,phases.py,fincount.py,run_broker.sh,run_broker_forcegc.sh} "$SCRATCH/bench/"
cp "$here/run_broker.sh" "$SCRATCH/bench/run_broker_frozen.sh"
CRYSTAL_PATH="$repo/lib:$(crystal env CRYSTAL_PATH)" crystal build --release "$here/driver.cr" -o "$SCRATCH/bench/driver"
(cd "$repo" && crystal build --release src/lavinmqperf.cr -o "$SCRATCH/brokers/lavinmqperf")
mkdir -p "$SCRATCH/mark"
for v in bundled stock broad global bigstack; do
  lib=$base; [ $v != bundled ] && lib="$SCRATCH/gcbuild/install-$v/lib:$base"
  CRYSTAL_LIBRARY_PATH=$lib crystal build --release "$here/mark.cr" -o "$SCRATCH/mark/mark-$v"
done
# Broker source: GC branch + digest fix, with the hook
src=$SCRATCH/broker-src
if [ ! -d "$src" ]; then
  git -C "$repo" fetch -q origin gc-heap-stats password-digest-without-finalizer
  git -C "$repo" worktree add -q --detach "$src" origin/gc-heap-stats
  git -C "$src" cherry-pick --no-commit origin/password-digest-without-finalizer
  ln -s "$repo/lib" "$src/lib"
fi
(cd "$src" && make -s js views > /dev/null 2>&1)
sed 's|require "./typetable"|require "./zz_typetable"|' "$here/gc_pauses.cr" > "$src/src/zz_gc_pauses.cr"
cp "$here/typetable.cr" "$src/src/zz_typetable.cr"
printf 'require "./zz_gc_pauses"\nrequire "./lavinmq"\n' > "$src/src/zz_bench.cr"
for v in ${BROKERS:-bundled global}; do
  lib=$base; [ $v != bundled ] && lib="$SCRATCH/gcbuild/install-$v/lib:$base"
  (cd "$src" && CRYSTAL_LIBRARY_PATH=$lib crystal build --release src/zz_bench.cr -o "$SCRATCH/brokers/lavinmq-$v")
  echo "built broker $v"
done
rm -f "$src"/src/zz_*.cr
echo "setup done: source $SCRATCH/env.sh"

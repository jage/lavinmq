#!/bin/bash
# Prepares a fresh VM for the compile benchmarks: build deps, Crystal 1.22.2 source (the compiler
# as a workload and for rebuilding the compiler with other libgc variants), LavinMQ's shards.
# Run from the lavinmq repo root. CB (default $HOME/cbench) holds everything.
set -eu
CB=${CB:-$HOME/cbench}
repo=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$CB"/{runs,results,compilers,gcbuild}
apt-get install -y -q time llvm-18-dev libxml2-dev libyaml-dev libgmp-dev libtool autoconf automake lld liblz4-dev libjemalloc2 libmimalloc2.0 > /dev/null
[ -d "$CB/crystal-src" ] || git clone -q --depth 1 --branch 1.22.2 https://github.com/crystal-lang/crystal.git "$CB/crystal-src" 2> /dev/null
(cd "$repo" && { [ -d lib ] || shards install --production > /dev/null; })
crystal --version | head -1
echo "setup done: CB=$CB"

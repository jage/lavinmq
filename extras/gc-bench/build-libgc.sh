#!/bin/bash
# Builds bdwgc 8.2.8 in five variants: stock, broad patch (always flag the mark stack to grow),
# global patch (flag it when the global stack overflows, the one to ship), global patch with a
# 32768-entry initial mark stack (global32k) and a 262144-entry initial mark stack. Installs each
# under <dir>/install-<variant>. VARIANTS="global global32k" builds a subset.
set -eu
dir=${1:?usage: build-libgc.sh <dir>}
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$dir" && cd "$dir"
[ -f gc.tar.gz ] || curl -sSfL -o gc.tar.gz https://github.com/ivmai/bdwgc/releases/download/v8.2.8/gc-8.2.8.tar.gz
for v in ${VARIANTS:-stock broad global global32k bigstack}; do
  rm -rf "src-$v" && mkdir "src-$v" && tar xzf gc.tar.gz -C "src-$v" --strip-components=1
  case $v in
    broad) patch -d "src-$v" -p1 < "$here/bdwgc-mark-stack-overflow.patch" ;;
    global|global32k) patch -d "src-$v" -p1 < "$here/bdwgc-mark-stack-overflow-global.patch" ;;
  esac
  cflags="-O2"
  [ "$v" = bigstack ] && cflags="-O2 -DINITIAL_MARK_STACK_SIZE=262144"
  [ "$v" = global32k ] && cflags="-O2 -DINITIAL_MARK_STACK_SIZE=32768"
  (cd "src-$v" && CFLAGS="$cflags" ./configure -q --disable-debug --disable-shared --enable-large-config \
     --enable-threads=posix --enable-parallel-mark --with-libatomic-ops=none --prefix="$dir/install-$v" \
     && make -j"$(nproc)" > make.log 2>&1 && make install > install.log 2>&1)
  echo "built libgc $v"
done

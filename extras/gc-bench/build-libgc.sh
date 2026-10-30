#!/bin/bash
# Builds bdwgc 8.2.8 in four variants: stock, broad patch (always flag the mark stack to grow),
# global patch (flag it when the global stack overflows, the one to ship) and a 262144-entry
# initial mark stack. Installs each under <dir>/install-<variant>.
set -eu
dir=${1:?usage: build-libgc.sh <dir>}
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$dir" && cd "$dir"
[ -f gc.tar.gz ] || curl -sSfL -o gc.tar.gz https://github.com/ivmai/bdwgc/releases/download/v8.2.8/gc-8.2.8.tar.gz
for v in stock broad global bigstack; do
  rm -rf "src-$v" && mkdir "src-$v" && tar xzf gc.tar.gz -C "src-$v" --strip-components=1
  case $v in
    broad) patch -d "src-$v" -p1 < "$here/bdwgc-mark-stack-overflow.patch" ;;
    global) patch -d "src-$v" -p1 < "$here/bdwgc-mark-stack-overflow-global.patch" ;;
  esac
  cflags="-O2"
  [ "$v" = bigstack ] && cflags="-O2 -DINITIAL_MARK_STACK_SIZE=262144"
  (cd "src-$v" && CFLAGS="$cflags" ./configure -q --disable-debug --disable-shared --enable-large-config \
     --enable-threads=posix --enable-parallel-mark --with-libatomic-ops=none --prefix="$dir/install-$v" \
     && make -j"$(nproc)" > make.log 2>&1 && make install > install.log 2>&1)
  echo "built libgc $v"
done

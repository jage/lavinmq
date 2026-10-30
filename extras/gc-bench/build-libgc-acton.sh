#!/bin/bash
# Builds Acton's bdwgc fork (actonlang/bdwgc, 8.3 development line) with autotools in two
# variants and installs each under <dir>/install-<variant>:
#   acton-default: no extra defines
#   acton-opts:    the defines Acton's build.zig sets on Linux x86_64 that concern marking,
#                  thread-local allocation and heap growth (see ACTON_OPTS below)
# RUN_CHECK=1 also runs `make check` (log in <dir>/src-<variant>/check.log).
set -eu
dir=${1:?usage: build-libgc-acton.sh <dir>}
rev=${ACTON_GC_REV:-2b99b72c85ac89f580dc7353e078290f83e8b065}
ACTON_OPTS="-DINITIAL_MARK_STACK_SIZE=4194304 -DSTEAL_MARK_STACK_RANGES -DGC_TL_REFILL_MAX=16 -DGC_NO_THREAD_LOCAL_WARMUP -DGC_HEAP_GROWTH_DIVISOR=4"
mkdir -p "$dir" && cd "$dir"
[ -d bdwgc.git ] || git clone -q --bare https://github.com/actonlang/bdwgc.git bdwgc.git
for v in ${VARIANTS:-acton-default acton-opts}; do
  rm -rf "src-$v" && git -C bdwgc.git worktree prune && git -C bdwgc.git worktree add -q --detach "$dir/src-$v" "$rev"
  cflags="-O2"
  [ "$v" = acton-opts ] && cflags="-O2 $ACTON_OPTS"
  (cd "src-$v" && ./autogen.sh > autogen.log 2>&1 \
     && CFLAGS="$cflags" ./configure -q --disable-debug --disable-shared --enable-large-config \
     --enable-threads=posix --enable-parallel-mark --with-libatomic-ops=none --prefix="$dir/install-$v" \
     && make -j"$(nproc)" > make.log 2>&1 && make install > install.log 2>&1)
  echo "built libgc $v ($rev, CFLAGS=$cflags)"
  if [ "${RUN_CHECK:-0}" = 1 ]; then
    (cd "src-$v" && make -j"$(nproc)" check > check.log 2>&1) && echo "make check $v: ok" || echo "make check $v: FAILED"
    grep -E "^# (TOTAL|PASS|SKIP|XFAIL|FAIL|XPASS|ERROR):" "src-$v/check.log" || true
  fi
done

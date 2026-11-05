#!/bin/bash
# Builds the libgc variants of the Acton commit attribution matrix (see PLAN-acton.md) and
# installs each under <dir>/install-<variant>. Same configure flags as 84codes/crystal-packages
# (static, large config, -O2 -fPIC -std=gnu17), parallel marking and thread-local allocation on.
#
#   stock       bdwgc 8.2.12 as 84codes/crystal ships it (what LavinMQ runs today)
#   fix         8.2.12 + mark-stack-overflow-global patch + 32768-entry initial mark stack
#               (the fix planned to ship; the baseline the Acton commits are measured against)
#   fix-pf      fix + prefetch on push (843bb7e6 backported, bdwgc-8.2.12-prefetch-on-push.patch)
#   fix-fl      fix + the free-list builder releases the mark lock before the allocator lock
#               (the ordering part of 27c37207, bdwgc-8.2.12-fl-builder-unlock-order.patch)
#   acton       actonlang/bdwgc acton branch at $ACTON_GC_REV, no extra defines
#   acton-nopf  acton with -DGC_NO_PUSH_PREFETCH (old prefetch placement)
#   acton-noinl acton with the inlined thread-local malloc fast path and the forced inlining of
#               the mark loop's push off (-DGC_NO_TL_MALLOC_FAST_PATH -DGC_ATTR_ALWAYS_INLINE=)
#   master      upstream bdwgc master at the fork's merge base $MASTER_GC_REV (8.3 development),
#               no defines: separates upstream changes since 8.2.12 from Acton's commits
#   acton-noidlecv   acton with -DGC_NO_IDLE_MARKER_CV (840f355e off: idle markers share the cv)
#   acton-noatomicfl acton with -DNO_ATOMIC_FL_BUILDER_COUNT (27c37207 off: builder count under
#                    the mark lock)
#
# VARIANTS="..." picks a subset.
set -eu
dir=${1:?usage: build-libgc-matrix.sh <dir>}
here=$(cd "$(dirname "$0")" && pwd)
rev=${ACTON_GC_REV:-9ad2afa248c4b23e239ceaf483dd1d89ec79c3a6}
master_rev=${MASTER_GC_REV:-635112baf}
mkdir -p "$dir" && cd "$dir"
[ -f gc-8.2.12.tar.gz ] || curl -sSfL -o gc-8.2.12.tar.gz https://github.com/ivmai/bdwgc/releases/download/v8.2.12/gc-8.2.12.tar.gz
[ -d bdwgc.git ] || git clone -q --bare https://github.com/actonlang/bdwgc.git bdwgc.git
git -C bdwgc.git fetch -q origin acton
git -C bdwgc.git cat-file -e "$master_rev^{commit}" 2>/dev/null || git -C bdwgc.git fetch -q https://github.com/ivmai/bdwgc.git master
base="-fPIC -pipe -O2 -std=gnu17"
for v in ${VARIANTS:-stock fix fix-pf acton acton-nopf acton-noinl}; do
  src=$dir/src-$v
  rm -rf "$src"; git -C bdwgc.git worktree prune
  cflags=$base
  case $v in
    stock|fix|fix-pf|fix-fl)
      mkdir "$src" && tar xzf gc-8.2.12.tar.gz -C "$src" --strip-components=1
      if [ $v != stock ]; then
        patch -s -d "$src" -p1 < "$here/bdwgc-mark-stack-overflow-global.patch"
        cflags="$base -DINITIAL_MARK_STACK_SIZE=32768"
      fi
      [ $v = fix-fl ] && patch -s -d "$src" -p1 < "$here/bdwgc-8.2.12-fl-builder-unlock-order.patch"
      [ $v = fix-pf ] && patch -s -d "$src" -p1 < "$here/bdwgc-8.2.12-prefetch-on-push.patch"
      ;;
    master|acton*)
      git -C bdwgc.git worktree add -q --detach "$src" "$([ $v = master ] && echo "$master_rev" || echo "$rev")"
      (cd "$src" && ./autogen.sh > autogen.log 2>&1)
      case $v in
        acton-nopf) cflags="$base -DGC_NO_PUSH_PREFETCH" ;;
        acton-noinl) cflags="$base -DGC_NO_TL_MALLOC_FAST_PATH -DGC_ATTR_ALWAYS_INLINE=" ;;
        acton-noidlecv) cflags="$base -DGC_NO_IDLE_MARKER_CV" ;;
        acton-noatomicfl) cflags="$base -DNO_ATOMIC_FL_BUILDER_COUNT" ;;
      esac
      ;;
    *) echo "unknown variant $v" >&2; exit 1 ;;
  esac
  (cd "$src" && CFLAGS="$cflags" ./configure -q --disable-debug --disable-shared --enable-large-config \
     --prefix="$dir/install-$v" > configure.log 2>&1 \
     && make -j"$(nproc)" > make.log 2>&1 && make install > install.log 2>&1)
  echo "built libgc $v: CFLAGS=$cflags"
done

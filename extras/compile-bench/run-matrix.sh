#!/bin/bash
# run-matrix.sh <phase> [rounds]: one phase of PLAN.md, variants interleaved in each round.
# Results: $CB/results/<phase>.txt (one line per compile, see measure.sh), TP lines for throughput.
#   env     GC environment tuning of the packaged compiler (lmq-dev, cr-dev)
#   libgc-a compilers rebuilt with libgc: stock fix fix-fl fix-pf, plus pkg (lmq-dev, cr-dev)
#   libgc-b compilers rebuilt with libgc: stock acton acton-noinl, acton with heap options, plus pkg
#   relopt  optimization levels of release builds (lmq, cr) and the throughput of the LavinMQ binaries
#   devopt  development build options: threads, debug info, linker, warm cache (lmq-dev, cr-dev)
#   specs   Crystal's std and semantic compiler specs, built against libgc stock fix fix-fl acton
#           (the spec process's own GC) and run, plus GC env on stock
set -u
here=$(cd "$(dirname "$0")" && pwd); . "$here/env.sh"
phase=$1 rounds=${2:-3}
M=$here/measure.sh; C=$CB/compilers; P=/usr/bin/crystal
log() { echo "$(date +%T) $*" >&2; }
case $phase in
env)
  for r in $(seq $rounds); do
    for wl in lmq-dev lmq-spec cr-dev; do
      $M env base-r$r $wl $P
      GC_MARKERS=1 $M env markers1-r$r $wl $P
      GC_MARKERS=2 $M env markers2-r$r $wl $P
      GC_FREE_SPACE_DIVISOR=2 $M env fsd2-r$r $wl $P
      GC_FREE_SPACE_DIVISOR=1 $M env fsd1-r$r $wl $P
      GC_INITIAL_HEAP_SIZE=2G $M env heap2g-r$r $wl $P
      GC_INITIAL_HEAP_SIZE=4G $M env heap4g-r$r $wl $P
      GC_DONT_GC=1 $M env nogc-r$r $wl $P
    done
    log "env round $r done"
  done ;;
libgc-a|libgc-b)
  vs=$([ $phase = libgc-a ] && echo "pkg stock fix fix-fl fix-pf" || echo "pkg stock acton acton-noinl")
  "$here/build-compiler.sh" $vs
  for r in $(seq $rounds); do
    for wl in lmq-dev lmq-spec cr-dev; do
      for v in $vs; do $M $phase $v-r$r $wl $C/crystal-$v; done
      if [ $phase = libgc-b ]; then
        GC_HEAP_GROWTH_DIVISOR=4 $M $phase acton+growdiv4-r$r $wl $C/crystal-acton
        GC_ALLOC_BUDGET_PERCENT=100 $M $phase acton+budget100-r$r $wl $C/crystal-acton
        GC_TL_REFILL_MAX=8 $M $phase acton+refill8-r$r $wl $C/crystal-acton
      fi
    done
    log "$phase round $r done"
  done ;;
relopt)
  (cd "$LMQ" && [ -x "$CB/lavinmqperf" ] || crystal build --release src/lavinmqperf.cr -o "$CB/lavinmqperf")
  for r in $(seq $rounds); do
    for wl in lmq-release lmq-O3 lmq-O2 lmq-O1; do
      KEEP_BIN=1 $M relopt opt-r$r $wl $P
      for i in 1 2; do "$here/tp-check.sh" "$CB/runs/relopt-opt-r$r-$wl/bin" "$wl-r$r" >> "$CB/results/relopt-tp.txt"; done
    done
    for wl in cr-release cr-O3 cr-O2 cr-O1; do $M relopt opt-r$r $wl $P; done
    log "relopt round $r done"
  done ;;
devopt)
  for r in $(seq $rounds); do
    for wl in lmq-dev cr-dev; do
      $M devopt default-r$r $wl $P
      EXTRA="--threads 1" $M devopt threads1-r$r $wl $P
      EXTRA="--threads 2" $M devopt threads2-r$r $wl $P
      EXTRA="--threads 8" $M devopt threads8-r$r $wl $P
      EXTRA="--no-debug" $M devopt nodebug-r$r $wl $P
      EXTRA="--link-flags=-fuse-ld=lld" $M devopt lld-r$r $wl $P
      cache=$CB/runs/warm-cache-$wl; rm -rf "$cache"
      CACHE=$cache $M devopt-prime prime-r$r $wl $P > /dev/null
      CACHE=$cache $M devopt warm-r$r $wl $P
      rm -rf "$cache"
    done
    log "devopt round $r done"
  done ;;
specs)
  vs="stock fix fix-fl acton"
  for v in $vs; do
    [ -f "$CB/gcbuild/install-$v/lib/libgc.a" ] || VARIANTS=$v "$LMQ/extras/gc-bench/build-libgc-matrix.sh" "$CB/gcbuild"
    for wl in crstd-spec crsem-spec; do
      CRYSTAL_LIBRARY_PATH=$CB/gcbuild/install-$v/lib:/usr/lib/crystal KEEP_BIN=1 CACHE=$CB/runs/cache-spec-$v $M specs-build $v $wl $P
    done
  done
  for r in $(seq $rounds); do
    for wl in crsem-spec crstd-spec; do
      for v in $vs; do "$here/spec-run.sh" specs $v-r$r "$CB/runs/specs-build-$v-$wl/bin" $wl; done
      GC_MARKERS=1 "$here/spec-run.sh" specs stock+markers1-r$r "$CB/runs/specs-build-stock-$wl/bin" $wl
      GC_FREE_SPACE_DIVISOR=1 "$here/spec-run.sh" specs stock+fsd1-r$r "$CB/runs/specs-build-stock-$wl/bin" $wl
    done
    log "specs round $r done"
  done ;;
*) echo "unknown phase $phase" >&2; exit 2 ;;
esac
log "$phase done"

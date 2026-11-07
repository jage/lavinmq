#!/bin/bash
# Re-run of the env phase's lmq-spec workload only (same variants as run-matrix.sh env).
M=/home/user/lavinmq/extras/compile-bench/measure.sh P=/usr/bin/crystal wl=lmq-spec
for r in 1 2 3; do
  $M env base-r$r $wl $P
  GC_MARKERS=1 $M env markers1-r$r $wl $P
  GC_MARKERS=2 $M env markers2-r$r $wl $P
  GC_FREE_SPACE_DIVISOR=2 $M env fsd2-r$r $wl $P
  GC_FREE_SPACE_DIVISOR=1 $M env fsd1-r$r $wl $P
  GC_INITIAL_HEAP_SIZE=2G $M env heap2g-r$r $wl $P
  GC_INITIAL_HEAP_SIZE=4G $M env heap4g-r$r $wl $P
  GC_DONT_GC=1 $M env nogc-r$r $wl $P
  echo "$(date +%T) env lmq-spec round $r done"
done
echo "$(date +%T) env-spec done"

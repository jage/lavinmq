#!/bin/bash
# Re-run of the libgc-b lmq-spec workload only (same invocations as run-matrix.sh)
here=/home/user/lavinmq/extras/compile-bench; . "$here/env.sh"
M=$here/measure.sh; C=$CB/compilers; phase=libgc-b
for r in 1 2 3; do wl=lmq-spec
  for v in pkg stock acton acton-noinl; do $M $phase $v-r$r $wl $C/crystal-$v; done
  GC_HEAP_GROWTH_DIVISOR=4 $M $phase acton+growdiv4-r$r $wl $C/crystal-acton
  GC_ALLOC_BUDGET_PERCENT=100 $M $phase acton+budget100-r$r $wl $C/crystal-acton
  GC_TL_REFILL_MAX=8 $M $phase acton+refill8-r$r $wl $C/crystal-acton
  echo "$(date +%T) lmq-spec rerun round $r done"
done
echo "$(date +%T) lmq-spec rerun done"

#!/bin/bash
# run_mark.sh: mark.cr matrix (variants x fibers x markers), then GC_PRINT_STATS overflow counts.
# Expects $SCRATCH/mark/mark-<variant>. Output to stdout.
set -u
V=${VARIANTS:-bundled global acton-default acton-opts}
for v in $V; do
  for f in 0 6500 30000; do
    for m in 1 2 4; do
      printf '%-14s m=%d ' $v $m
      TREE=1 GC_MARKERS=$m $SCRATCH/mark/mark-$v $f 2000000 0
    done
  done
done
echo
echo "# GC_PRINT_STATS=1: overflow/growth log lines over the 11 collections of one run"
for v in $V; do
  for f in 0 6500 30000; do
    for m in 1 2 4; do
      log=$SCRATCH/mark/stats-$v-$f-$m.log
      TREE=1 GC_MARKERS=$m GC_PRINT_STATS=1 $SCRATCH/mark/mark-$v $f 2000000 0 > $log 2>&1
      ov=$(grep -c "Mark stack overflow" $log); lo=$(grep -c "Local mark stack overflow" $log)
      mv=$(grep -c "Moved .* entries of full mark stack" $log); gr=$(grep -c "Grew mark stack" $log)
      last=$(grep "Grew mark stack" $log | tail -1 | grep -oE "to [0-9]+ frames")
      res=$(grep -oE "collect p50 .*" $log)
      printf '%-14s fibers %5d m=%d  overflow-lines %3d local %3d moved %3d grew %3d (%s)  %s\n' $v $f $m $ov $lo $mv $gr "${last:-}" "$res"
    done
  done
done

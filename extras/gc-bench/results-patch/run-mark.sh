#!/bin/bash
# Runs mark-<variant> over fibers x markers, once plain (timing) and once with GC_PRINT_STATS=1
# (overflow/grow counts). Usage: run-mark.sh <markdir> <logdir>
mark=${1:?markdir}; logs=${2:?logdir}; mkdir -p "$logs"
for tree in 1 0; do
  for v in bundled stock broad global bigstack; do
    fibs="0 6500 20000 30000"; [ $tree = 0 ] && fibs="0 6500"
    for f in $fibs; do
      for m in 1 2 4; do
        t=tree$tree-$v-f$f-m$m
        if [ $tree = 1 ]; then env="TREE=1"; else env=""; fi
        env $env GC_MARKERS=$m "$mark/mark-$v" $f 2000000 0 > "$logs/$t.out" 2>&1; ec=$?
        env $env GC_MARKERS=$m GC_PRINT_STATS=1 "$mark/mark-$v" $f 2000000 0 > "$logs/$t.stats" 2>&1; ec2=$?
        ov=$(grep -c 'Mark stack overflow' "$logs/$t.stats")
        grew=$(grep 'Grew mark stack' "$logs/$t.stats" | tail -1 | awk '{print $5}')
        p50=$(grep -o 'collect p50 *[0-9.]*' "$logs/$t.out" | awk '{print $3}')
        sp50=$(grep -o 'collect p50 *[0-9.]*' "$logs/$t.stats" | awk '{print $3}')
        echo "tree=$tree variant=$v fibers=$f markers=$m exit=$ec/$ec2 p50=${p50:-FAIL} stats_p50=${sp50:-FAIL} overflows=$ov grew_to=${grew:--}"
      done
    done
  done
done

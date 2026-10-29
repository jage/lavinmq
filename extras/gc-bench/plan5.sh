#!/bin/bash
R=$SCRATCH/bench/run_broker_forcegc.sh
for i in 1 2; do
  for m in default 1 2 4; do
    echo -n "idle, forced GC, markers=$m | "
    if [ $m = default ]; then PERF=0 FLAP=0 $R gcdigest none 60; else GC_MARKERS=$m PERF=0 FLAP=0 $R gcdigest none 60; fi
  done
done

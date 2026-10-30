#!/bin/bash
# run_idle.sh: idle broker (20k queues, 2,000 connections, no perf load, no flapping) with a
# forced collection every 3 s, 60 s, for each broker and GC_MARKERS setting, RUNS rounds,
# interleaved. Copies each run directory to $SCRATCH/runs-acton/idle/<broker>-m<m>-r<n>.
set -u
B=${BROKERS:-bundled global acton-default acton-opts}
M=${MARKERS:-1 4 default}
cd $SCRATCH/bench
for r in $(seq 1 ${RUNS:-2}); do
  for b in $B; do
    for m in $M; do
      label=$b-m$m-r$r
      if [ $m = default ]; then
        env -u GC_MARKERS PERF=0 FLAP=0 ./run_broker_forcegc.sh $b none 60
      else
        GC_MARKERS=$m PERF=0 FLAP=0 ./run_broker_forcegc.sh $b none 60
      fi
      python3 -I phases.py $SCRATCH/runs/$b-none $label
      mkdir -p $SCRATCH/runs-acton/idle && rm -rf $SCRATCH/runs-acton/idle/$label
      cp -r $SCRATCH/runs/$b-none $SCRATCH/runs-acton/idle/$label && rm -rf $SCRATCH/runs-acton/idle/$label/data
    done
  done
done

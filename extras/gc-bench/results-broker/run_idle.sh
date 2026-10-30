#!/bin/bash
# Step 2: idle broker, forced collections every 3 s, two rounds of brokers x GC_MARKERS.
# Raw run dirs are copied to $RES/idle/<broker>-m<m>-r<round>.
set -u
RES=${RES:?}; mkdir -p $RES/idle
cd $SCRATCH/bench
for r in 1 2; do
  for m in 1 2 4 default; do
    for b in bundled global bigstack; do
      label="$b m=$m r$r"
      if [ $m = default ]; then
        line=$(env -u GC_MARKERS PERF=0 FLAP=0 ./run_broker_forcegc.sh $b none 60)
      else
        line=$(GC_MARKERS=$m PERF=0 FLAP=0 ./run_broker_forcegc.sh $b none 60)
      fi
      ph=$(python3 -I phases.py $SCRATCH/runs/$b-none "$label")
      echo "$line" >> $RES/idle/summary.txt; echo "$ph" >> $RES/idle/phases.txt
      echo "$ph"
      rm -rf $SCRATCH/runs/$b-none/data
      cp -r $SCRATCH/runs/$b-none $RES/idle/$b-m$m-r$r
    done
  done
done

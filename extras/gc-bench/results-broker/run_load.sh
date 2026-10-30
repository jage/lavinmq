#!/bin/bash
# Step 3: full load (churn + flapping + lavinmqperf), 240 s, two interleaved rounds.
set -u
RES=${RES:?}; mkdir -p $RES/load
cd $SCRATCH/bench
for r in 1 2; do
  for cfg in bundled:1 global:4 global:default bigstack:4; do
    b=${cfg%%:*}; m=${cfg#*:}
    label="$b m=$m r$r"
    if [ $m = default ]; then
      line=$(env -u GC_MARKERS ./run_broker_frozen.sh $b churn 240)
    else
      line=$(GC_MARKERS=$m ./run_broker_frozen.sh $b churn 240)
    fi
    ph=$(python3 -I phases.py $SCRATCH/runs/$b-churn "$label")
    echo "$label | $line" >> $RES/load/summary.txt; echo "$ph" >> $RES/load/phases.txt
    echo "$label | $line"; echo "$ph"
    rm -rf $SCRATCH/runs/$b-churn/data
    cp -r $SCRATCH/runs/$b-churn $RES/load/$b-m$m-r$r
  done
done

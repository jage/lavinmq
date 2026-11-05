#!/bin/bash
R=$SCRATCH/bench/run_broker_frozen.sh
run() { label=$1; shift; echo -n "$label | "; env "$@" $R $V churn 240; }
for i in 1 2; do
  V=gcdigest run "digest + GC_MARKERS=1      " GC_MARKERS=1
  V=gcdigest run "digest + GC_MARKERS=2      " GC_MARKERS=2
  if [ $i = 1 ]; then V=gclazy run "digest + lazy BoolChannel  " CENSUS_AT=120; cp $SCRATCH/runs/gclazy-churn/census.txt $SCRATCH/bench/census-gclazy.txt
  else V=gclazy run "digest + lazy BoolChannel  "; fi
  V=gclazy run "digest + lazy + MARKERS=1  " GC_MARKERS=1
done

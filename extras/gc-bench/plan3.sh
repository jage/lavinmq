#!/bin/bash
R=$SCRATCH/bench/run_broker_frozen.sh
run() { label=$1; shift; echo -n "$label | "; env "$@" $R $V churn 240; }
for i in 1 2; do
  V=gcbase run "baseline              "
  V=gcbase run "GC_MARKERS=4          " GC_MARKERS=4
  V=gcbase run "GC_MARKERS=1          " GC_MARKERS=1
  V=gcbase run "per-finalizer 1KB     " GC_BYTES_PER_FINALIZER=1000
  V=gcdigest run "digest fix            "
  V=gcdigest run "digest fix + 1KB      " GC_BYTES_PER_FINALIZER=1000
  V=gcbase run "GC_FREE_SPACE_DIVISOR=2" GC_FREE_SPACE_DIVISOR=2
done

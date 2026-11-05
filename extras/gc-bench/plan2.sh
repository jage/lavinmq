#!/bin/bash
R=$SCRATCH/bench/run_broker_frozen.sh
for i in 1 2 3; do
  PERF=0 FLAP=0 $R gcbase churn 120
  PERF=0 FLAP=0 $R gcdigest churn 120
  echo -n "per-finalizer 1KB: "; GC_BYTES_PER_FINALIZER=1000 PERF=0 FLAP=0 $R gcbase churn 120
done

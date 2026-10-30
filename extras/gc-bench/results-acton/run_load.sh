#!/bin/bash
# run_load.sh: full load (20k flapping queues, 200 reconnects/s, 20k msg/s), 240 s, GC_MARKERS=4
# for the patched/fork brokers and GC_MARKERS=1 for bundled; RUNS rounds, interleaved.
# CONFIGS entries are <broker>:<markers>[:<extra env VAR=val,...>]:<label>.
set -u
C=${CONFIGS:-bundled:1::bundled-m1 global:4::global-m4 acton-default:4::acton-default-m4 acton-opts:4::acton-opts-m4}
cd $SCRATCH/bench
for r in $(seq 1 ${RUNS:-2}); do
  for c in $C; do
    IFS=: read b m extra label <<< "$c"
    label=$label-r$r
    env GC_MARKERS=$m ${extra//,/ } ./run_broker_frozen.sh $b churn 240 | sed "s/^/$label /"
    python3 -I phases.py $SCRATCH/runs/$b-churn $label
    mkdir -p $SCRATCH/runs-acton/load && rm -rf $SCRATCH/runs-acton/load/$label
    cp -r $SCRATCH/runs/$b-churn $SCRATCH/runs-acton/load/$label && rm -rf $SCRATCH/runs-acton/load/$label/data
  done
done

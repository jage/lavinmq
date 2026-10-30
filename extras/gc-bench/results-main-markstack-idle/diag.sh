#!/bin/bash
# Untimed diagnostic: one 60 s run per variant with GC_PRINT_STATS=1; overflow lines go to broker.log
R=$SCRATCH/bench/run_broker_forcegc.sh
for v in bundled bundled-m1 global global32k; do
  pkill -f 'lavinmq-|bench/driver|lavinmqperf' ; sleep 2
  while awk '$4=="0A"{print $2}' /proc/net/tcp* | grep -qiE ':(1628|3D38)$'; do sleep 1; done
  echo -n "diag $v | "
  if [ $v = bundled-m1 ]; then GC_MARKERS=1 GC_PRINT_STATS=1 PERF=0 FLAP=0 $R $v none 60; else GC_PRINT_STATS=1 PERF=0 FLAP=0 $R $v none 60; fi
  rm -rf $SCRATCH/runs/$v-none/data
  mkdir -p $SCRATCH/keep && rm -rf $SCRATCH/keep/diag-$v && mv $SCRATCH/runs/$v-none $SCRATCH/keep/diag-$v
  echo "  overflows: $(grep -c 'Mark stack overflow' $SCRATCH/keep/diag-$v/broker.log); sizes: $(grep -o 'current size = [0-9]*' $SCRATCH/keep/diag-$v/broker.log | sort | uniq -c | tr '\n' ';')"
done

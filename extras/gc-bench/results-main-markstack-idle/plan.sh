#!/bin/bash
# Idle broker on main (baaa3ea), forced GC every 3 s, 120 s per run, variants interleaved.
#   plan.sh <first round> <last round>; raw output kept in $SCRATCH/keep/r<round>-<variant>
R=$SCRATCH/bench/run_broker_forcegc.sh
for i in $(seq ${1:-1} ${2:-3}); do
  echo "round $i vmstat:"; vmstat 1 5
  for v in bundled bundled-m1 global global32k; do
    pkill -f 'lavinmq-|bench/driver|lavinmqperf' ; sleep 2
    while awk '$4=="0A"{print $2}' /proc/net/tcp* | grep -qiE ':(1628|3D38)$'; do sleep 1; done
    echo -n "round $i $v | "
    if [ $v = bundled-m1 ]; then GC_MARKERS=1 PERF=0 FLAP=0 $R $v none 120; else PERF=0 FLAP=0 $R $v none 120; fi
    rm -rf $SCRATCH/runs/$v-none/data
    mkdir -p $SCRATCH/keep && rm -rf $SCRATCH/keep/r$i-$v && mv $SCRATCH/runs/$v-none $SCRATCH/keep/r$i-$v
  done
done

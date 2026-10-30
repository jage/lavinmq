#!/bin/bash
# Full load (PERF=1, FLAP=1), 1200 s per run, one run per variant per round, interleaved.
#   plan.sh <first round> <last round>
set -u
. $HOME/gcbench/env.sh
R=$SCRATCH/bench/run_broker.sh
repo=/home/user/lavinmq
D=$repo/extras/gc-bench/results-main-finalizers-long
V=(main main-socket digest digest-socket)
clean() {
  pkill -f "brokers/lavinmq" ; pkill -f bench/driver; sleep 2
  pkill -9 -f "brokers/lavinmq"; pkill -9 -f bench/driver
  # listening sockets (state 0A) on 5672 or 15672
  while awk '$4 == "0A" && $2 ~ /:(1628|3D38)$/ {f=1} END {exit !f}' /proc/net/tcp /proc/net/tcp6; do sleep 1; done
}
for i in $(seq $1 $2); do
  for v in "${V[@]}"; do
    clean
    o=$D/r$i/$v; mkdir -p $o
    vmstat 1 5 > $o/vmstat.txt
    # wall clock minus CLOCK_MONOTONIC, to put samples.txt (wall) on the hook's tick axis
    python3 -Ic 'import time; print(time.time() - time.monotonic())' > $o/clock.txt
    echo -n "r$i | " >> $D/summary.txt
    PERF=1 FLAP=1 $R $v churn 1200 | tee -a $D/summary.txt
    cp $SCRATCH/runs/$v-churn/{gc.pauses*,driver.log,perf.log,samples.txt,broker.log,lavinmq.ini} $o/
    python3 -I $D/analyze.py $o $SCRATCH/brokers/lavinmq-$v > $o/minutes.txt 2>&1
    (cd $repo && git add $D && git commit -qm "GC bench main finalizers long: r$i $v" && \
     for t in 2 4 8 16 0; do git push -q -u origin gc-bench-main-finalizers-long && break; sleep $t; done)
  done
done
clean

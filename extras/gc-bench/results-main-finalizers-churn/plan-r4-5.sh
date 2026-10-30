#!/bin/bash
# Connection churn only (PERF=0 FLAP=0), 240 s per run, variants interleaved and rotated per round.
#   plan.sh <first round> <last round>
set -u
. $HOME/gcbench/env.sh
R=$SCRATCH/bench/run_broker.sh
repo=/home/user/lavinmq
D=$repo/extras/gc-bench/results-main-finalizers-churn
V=(main main-socket digest digest-socket digest-socket-1k)
ln -sf lavinmq-digest-socket $SCRATCH/brokers/lavinmq-digest-socket-1k
clean() {
  pkill -f "brokers/lavinmq" ; pkill -f bench/driver; sleep 2
  pkill -9 -f "brokers/lavinmq"; pkill -9 -f bench/driver
  # no ss on this VM: listening sockets (state 0A) on 5672 or 15672
  while awk '$4 == "0A" && $2 ~ /:(1628|3D38)$/ {f=1} END {exit !f}' /proc/net/tcp; do sleep 1; done
}
for i in $(seq $1 $2); do
  mkdir -p $D/r$i
  vmstat 1 5 > $D/r$i/vmstat.txt
  for k in 0 1 2 3 4; do
    v=${V[$(( (k + i - 1) % 5 ))]}
    clean
    env=""; [ $v = digest-socket-1k ] && env="GC_BYTES_PER_FINALIZER=1000"
    echo -n "r$i | " >> $D/summary.txt
    env $env PERF=0 FLAP=0 $R $v churn 240 | tee -a $D/summary.txt
    o=$D/r$i/$v; mkdir -p $o
    cp $SCRATCH/runs/$v-churn/{gc.pauses*,driver.log,perf.log,samples.txt,broker.log,lavinmq.ini} $o/
  done
  clean
  (cd $repo && git add extras/gc-bench/results-main-finalizers-churn && git commit -qm "GC bench main finalizers churn: round $i" && \
   for t in 2 4 8 16 0; do git push -q -u origin gc-bench-main-finalizers-churn && break; sleep $t; done)
done

#!/bin/bash
# Full load (churn 240 s, PERF=1, FLAP=1), variants interleaved per round.
# Usage: plan.sh <first round> <last round>. Copies every run into $DEST/r<round>-<variant>/.
R=$SCRATCH/bench/run_broker.sh
DEST=${DEST:?set DEST}
clean() {
  pkill -f 'brokers/lavinmq-' ; pkill -f lavinmqperf; pkill -f bench/driver
  while ss -ltn | grep -qE ':(5672|15672) '; do sleep 1; done
}
for i in $(seq $1 $2); do
  echo "== round $i $(date -u +%FT%TZ)"; vmstat 1 5
  for v in bundled bundled-m1 global global32k; do
    clean
    bin=$v; envs=()
    [ $v = bundled-m1 ] && { bin=bundled; envs=(GC_MARKERS=1); }
    echo -n "r$i $v | "
    env "${envs[@]}" PERF=1 FLAP=1 $R $bin churn 240
    d=$DEST/r$i-$v; mkdir -p $d
    cp $SCRATCH/runs/$bin-churn/{gc.pauses,gc.pauses.allocs,gc.pauses.finalizers,driver.log,perf.log,samples.txt,broker.log} $d/
  done
done
clean

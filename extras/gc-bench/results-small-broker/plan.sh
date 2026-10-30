#!/bin/bash
# Small broker (NQ=50, NCONN=20), libgc mark stack start 4096 / 16k / 32k vs bundled.
# Per round, variants interleaved (start rotated each round): idle with forced GC every 3 s
# (120 s), then light load (churn + 1000 msg/s, 240 s). Then the probe, then GC_PRINT_STATS runs.
set -u
B=$SCRATCH/bench
res=/home/user/lavinmq/extras/gc-bench/results-small-broker
VS=(bundled global global16k global32k)
export NQ=50 NCONN=20 FLAP=0
clean() {
  pkill -f "$SCRATCH/brokers/lavinmq-" ; pkill -f "$B/driver"; pkill -f lavinmqperf
  for port in 5672 15672; do while (exec 3<>/dev/tcp/127.0.0.1/$port) 2>/dev/null; do sleep 1; done; done
}
keep() { # keep <run dir> <dest>
  mkdir -p $2
  cp $1/{gc.pauses,gc.pauses.allocs,gc.pauses.finalizers,driver.log,perf.log,samples.txt,broker.log,smaps_rollup.txt,rss_start.txt,rss_end.txt} $2/ 2>/dev/null
}
push() {
  cd /home/user/lavinmq && git add extras/gc-bench/results-small-broker && git commit -qm "$1" && \
  for d in 2 4 8 16 0; do git push -q -u origin gc-bench-small-broker && break; [ $d = 0 ] || sleep $d; done
}
for r in ${ROUNDS:-1 2 3 4 5}; do
  echo "== round $r vmstat" >> $res/vmstat.txt; vmstat 1 5 >> $res/vmstat.txt
  for k in 0 1 2 3; do
    v=${VS[$(( (k + r - 1) % 4 ))]}
    clean; echo -n "r$r idle  | " | tee -a $res/summary.txt
    PERF=0 $B/run_small_forcegc.sh $v none 120 | tee -a $res/summary.txt
    keep $SCRATCH/runs/$v-none $res/runs/r$r-idle-$v
  done
  for k in 0 1 2 3; do
    v=${VS[$(( (k + r - 1) % 4 ))]}
    clean; echo -n "r$r load  | " | tee -a $res/summary.txt
    $B/run_small.sh $v churn 240 | tee -a $res/summary.txt
    keep $SCRATCH/runs/$v-churn $res/runs/r$r-load-$v
  done
  push "Small broker GC bench: round $r"
done
if [ "${PROBE:-1}" = 1 ]; then
  for i in $(seq 10); do for v in ${VS[@]}; do
    echo "$i $v $($SCRATCH/probe/probe-$v)" | tee -a $res/probe.txt
  done; done
fi
if [ "${STATS:-1}" = 1 ]; then
  for v in ${VS[@]}; do
    clean; echo -n "stats idle | " | tee -a $res/summary-stats.txt
    GC_PRINT_STATS=1 PERF=0 $B/run_small_forcegc.sh $v none 60 | tee -a $res/summary-stats.txt
    keep $SCRATCH/runs/$v-none $res/runs/stats-idle-$v
  done
fi
clean
push "Small broker GC bench: probe and GC_PRINT_STATS runs"
echo PLAN DONE

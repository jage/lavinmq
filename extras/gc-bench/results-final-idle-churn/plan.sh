#!/bin/bash
# The plan run for results-final-idle-churn: 3 rounds (ROUNDS) of idle forced-GC (120 s) and
# churn-only (240 s), variants interleaved, then a 60 s GC_PRINT_STATS idle run per variant.
set -u
: "${SCRATCH:?}"
repo=/home/user/lavinmq
res=$repo/extras/gc-bench/results-final-idle-churn
B=$SCRATCH/bench
VARIANTS=${VARIANTS:-"main combo16k combo32k"}
clean() {
  pkill -f 'lavinmq-(main|combo)' ; pkill -f bench/driver; pkill -f lavinmqperf; sleep 2
  pkill -9 -f 'lavinmq-(main|combo)'; pkill -9 -f bench/driver
  while ss -ltn | grep -qE ':(5672|15672) '; do sleep 1; done
}
save() { # <variant> <mode> <dest>
  local src=$SCRATCH/runs/$1-$2 d=$res/runs/$3
  mkdir -p "$d"
  cp "$src"/{driver.log,perf.log,samples.txt,broker.log} "$d"/
  cp "$src"/gc.pauses "$src"/gc.pauses.allocs "$src"/gc.pauses.finalizers "$d"/ 2>/dev/null
  gzip -c "$src"/gc.pauses.traces > "$d"/gc.pauses.traces.gz 2>/dev/null
  cp "$src"/gc.pauses.maps "$d"/ 2>/dev/null
}
push() {
  (cd $repo && git add extras/gc-bench && git commit -qm "$1" && \
   for t in 2 4 8 16 0; do git push -q -u origin gc-bench-final-idle-churn && break; [ $t = 0 ] && break; sleep $t; done)
}
for r in $(seq ${FIRST:-1} ${ROUNDS:-3}); do
  { echo "== round $r $(date -u +%FT%TZ)"; vmstat 1 5; } >> $res/vmstat.txt
  for v in $VARIANTS; do
    clean
    line=$(PERF=0 FLAP=0 $B/run_broker_forcegc.sh $v none 120)
    echo "r$r idle  $line" | tee -a $res/summary.txt
    save $v none r$r-idle-$v
    python3 -I $res/analyze.py $v idle $res/runs/r$r-idle-$v | sed "s/^{/{\"round\": $r, /" >> $res/runs.jsonl
  done
  for v in $VARIANTS; do
    clean
    line=$(PERF=0 FLAP=0 $B/run_broker.sh $v churn 240)
    echo "r$r churn $line" | tee -a $res/summary.txt
    save $v churn r$r-churn-$v
    python3 -I $res/analyze.py $v churn $res/runs/r$r-churn-$v | sed "s/^{/{\"round\": $r, /" >> $res/runs.jsonl
  done
  push "GC bench final idle/churn: round $r"
done
if [ "${STATS:-1}" = 1 ]; then
  for v in $VARIANTS; do
    clean
    line=$(GC_PRINT_STATS=1 PERF=0 FLAP=0 $B/run_broker_forcegc.sh $v none 60)
    echo "stats $line" | tee -a $res/summary.txt
    save $v none stats-$v
    gzip -f $res/runs/stats-$v/broker.log
    echo "$v overflow $(zgrep -c 'Mark stack overflow' $res/runs/stats-$v/broker.log.gz) grew $(zgrep -c 'Grew mark stack' $res/runs/stats-$v/broker.log.gz)" | tee -a $res/markstack.txt
  done
  clean
  push "GC bench final idle/churn: GC_PRINT_STATS runs"
fi

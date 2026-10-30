#!/bin/bash
# Which load drives v2.10.2's heap growth: 150 s steady runs with one factor removed each
# (churn, lavinmqperf, the 15 s metric scrapes), plus all factors. Heap and String bytes from the
# end-of-run census.
res=$(cd "$(dirname "$0")" && pwd)
for c in all:: nochurn:CHURN_RATE=0: noperf:PERF=0: noscrape:SCRAPE_EVERY=0:; do
  name=${c%%:*} e=${c#*:}; e=${e%:}
  pkill -f "$SCRATCH/brokers/lavinmq-"; pkill -f "$SCRATCH/bench/driver"; pkill -x lavinmqperf; sleep 3
  echo -n "$name | " >> $res/growth-check.txt
  env $e $res/run_sim.sh v2102 $SCRATCH/runs/growth-$name 150 >> $res/growth-check.txt
  mkdir -p $res/runs/growth-$name
  (cd $SCRATCH/runs/growth-$name && cp census.txt phases.txt rss.txt scrapes.txt gc.pauses gc.pauses.watchdog $res/runs/growth-$name/)
done

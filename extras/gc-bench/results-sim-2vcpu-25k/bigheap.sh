#!/bin/bash
# Production-sized heap: v2.10.2 retains ~46 KB of heap per reconnect, so churning at 300/s for
# 600 s grows its heap to ~8 GB in 10 minutes, about what the production leader reaches over hours.
# Bundled libgc (v2102) vs the global patch + 32768-entry initial mark stack (v2102g).
res=$(cd "$(dirname "$0")" && pwd)
for v in v2102 v2102g; do
  pkill -f "$SCRATCH/brokers/lavinmq-"; pkill -f "$SCRATCH/bench/driver"; pkill -x lavinmqperf; sleep 3
  { echo "== bigheap $v"; vmstat 1 5; } >> $res/vmstat.txt
  echo -n "bigheap | " >> $res/bigheap.txt
  CHURN_RATE=300 $res/run_sim.sh $v $SCRATCH/runs/bigheap-$v 600 >> $res/bigheap.txt
  mkdir -p $res/runs/bigheap-$v
  (cd $SCRATCH/runs/bigheap-$v && cp gc.pauses gc.pauses.allocs gc.pauses.watchdog gc_version.txt markers.txt phases.txt \
     driver0.log driver1.log perf.log rss.txt scrapes.txt census.txt smaps_rollup.txt $res/runs/bigheap-$v/ && \
   gzip -c broker.log > $res/runs/bigheap-$v/broker.log.gz)
done

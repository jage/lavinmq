#!/bin/bash
# Unpaged list polling: per variant, storm then 20 minutes steady (37 reconnects/s, 830 msg/s) with
# two GET /api/connections 5 s apart every 60 s; then /api/channels on v2.10.2 and v2.10.4.
# RUNS picks variant:list pairs, ROUND suffixes the run names.
set -u
res=$(cd "$(dirname "$0")" && pwd)
clean() {
  pkill -f "$SCRATCH/brokers/lavinmq-"; pkill -f "$SCRATCH/bench/driver"; pkill -x lavinmqperf
  for port in 5672 15672; do while (exec 3<>/dev/tcp/127.0.0.1/$port) 2>/dev/null; do sleep 1; done; done
  sleep 2
}
push() {
  if grep -rIl "cloudamqp\.com" $res; then echo "identifying string found, not pushing"; return 1; fi
  cd /home/user/lavinmq && git add extras/gc-bench && git commit -qm "$1" && \
  for d in 2 4 8 16 0; do git push -q -u origin gc-bench-sim-2vcpu-25k && break; [ $d = 0 ] || sleep $d; done
}
for c in ${RUNS:-v2102:connections v2104:connections combo32k:connections v2102:channels v2104:channels}; do
  v=${c%%:*} what=${c#*:} name=poll-$what-$v${ROUND:+-$ROUND} run=$SCRATCH/runs/poll-$what-$v${ROUND:+-$ROUND}
  clean
  { echo "== $name"; vmstat 1 5; } >> $res/vmstat.txt
  echo -n "$name | " >> $res/poll-summary.txt
  POLL_PATH=/api/$what $res/run_sim.sh $v $run ${STEADY:-1200} >> $res/poll-summary.txt
  dst=$res/runs/$name; mkdir -p $dst
  (cd $run && cp gc.pauses gc.pauses.allocs gc.pauses.finalizers gc.pauses.watchdog gc_version.txt markers.txt limits.txt \
     phases.txt declare.log driver0.log driver1.log perf.log rss.txt scrapes.txt polls.txt census.txt smaps_rollup.txt \
     metrics.end $dst/ 2>/dev/null; gzip -c broker.log > $dst/broker.log.gz)
  echo "truncated-result warnings: $(grep -c 'Result set truncated' $run/broker.log)" > $dst/truncated.txt
  python3 -I $res/per_minute.py $dst > $dst/per-minute.md
  push "Sim 2-vCPU many-connection cluster: unpaged $what polling on $v"
done
clean
echo POLL PLAN DONE

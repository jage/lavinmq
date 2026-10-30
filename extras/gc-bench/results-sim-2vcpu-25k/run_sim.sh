#!/bin/bash
# run_sim.sh <broker variant> <run dir> <steady seconds>: one failover-like run on a broker pinned
# to CPUs 0-1. Declares NQ queues, then two drivers (one per CPU 2 and 3) open NCONN connections in
# total as fast as possible (storm), then churn CHURN_RATE/s in total while lavinmqperf moves
# PERF_RATE msg/s, for <steady seconds> (steady). Ends with a heap census while all connections are
# still open. Phase timestamps (CLOCK_MONOTONIC ns) go to <run dir>/phases.txt.
# DIAG=1 runs the broker with GC_PRINT_STATS=1. PERF=0 skips lavinmqperf, SCRAPE_EVERY=0 skips the
# periodic scrapes (default every 15 s). GC_MARKERS defaults to 2: bdwgc sizes its markers
# from the online CPU count, not the affinity mask, so taskset alone would give it 4.
set -u
S=$SCRATCH
v=$1; out=$2; secs=$3
NCONN=${NCONN:-19500} NQ=${NQ:-1150} CHURN_RATE=${CHURN_RATE:-37} CONSUMERS=${CONSUMERS:-770}
PERF_RATE=${PERF_RATE:-415}
mono() { python3 -c 'import time; print(time.monotonic_ns())'; }
rm -rf $out; mkdir -p $out/data
cat > $out/lavinmq.ini <<INI
[main]
data_dir = $out/data
log_level = info
[mgmt]
bind = 127.0.0.1
[amqp]
bind = 127.0.0.1
INI
extra=(); [ "${DIAG:-0}" = 1 ] && extra=(GC_PRINT_STATS=1)
taskset -c 0,1 env GC_MARKERS=${GC_MARKERS:-2} GC_PAUSE_FILE=$out/gc.pauses "${extra[@]}" $S/brokers/lavinmq-$v -c $out/lavinmq.ini > $out/broker.log 2>&1 &
pid=$!
until curl -s -o /dev/null -u guest:guest http://127.0.0.1:15672/api/overview; do sleep 0.2; done
echo "broker_start $(mono)" > $out/phases.txt
grep "open files" /proc/$pid/limits > $out/limits.txt
# RSS each second; a Prometheus-like scrape every 15 s, recording how long it took
( while kill -0 $pid 2>/dev/null; do echo "$(mono) $(awk '/VmRSS/{print $2}' /proc/$pid/status 2>/dev/null) $(ls /proc/$pid/fd 2>/dev/null | wc -l)"; sleep 1; done ) > $out/rss.txt &
( while kill -0 $pid 2>/dev/null; do
    t0=$(mono); curl -s -m 60 -u guest:guest http://127.0.0.1:15672/metrics > $out/metrics.tmp; rc=$?; t1=$(mono)
    heap=$(awk '$1 == "lavinmq_gc_heap_size_bytes" {print $2}' $out/metrics.tmp)
    conns=$(awk '$1 == "lavinmq_connections" {print $2}' $out/metrics.tmp)
    echo "$t0 $(( (t1 - t0) / 1000000 )) $rc $heap $conns"; cp $out/metrics.tmp $out/metrics.last
    [ "${SCRAPE_EVERY:-15}" = 0 ] && break; sleep ${SCRAPE_EVERY:-15}
  done ) > $out/scrapes.txt &
sleep 1
curl -s -u guest:guest http://127.0.0.1:15672/metrics | grep -E "^lavinmq_gc_marker_threads" > $out/markers.txt
cp $out/gc.pauses.version $out/gc_version.txt 2>/dev/null
NQ=$NQ taskset -c 2,3 $S/bench/driver declare 0 > $out/declare.log 2>&1
echo "fds_after_declare $(ls /proc/$pid/fd | wc -l)" >> $out/phases.txt
echo "storm_start $(mono)" >> $out/phases.txt
for d in 0 1; do
  NQ=$NQ NCONN=$((NCONN / 2)) CHURN_RATE=$(python3 -c "print($CHURN_RATE / 2)") CONSUMERS=$((CONSUMERS / 2)) \
    DECLARE=0 FLAP=0 POOL_PUB=0 CONC=${CONC:-250} taskset -c $((2 + d)) $S/bench/driver storm $((secs + 600)) > $out/driver$d.log 2>&1 &
done
until [ "$(grep -l storm_end $out/driver0.log $out/driver1.log 2>/dev/null | wc -l)" = 2 ]; do
  kill -0 $pid 2>/dev/null || { echo "broker died"; break; }; sleep 0.2; done
echo "storm_end $(mono)" >> $out/phases.txt
echo "rss_kb_at_full $(awk '/VmRSS/{print $2}' /proc/$pid/status) fds $(ls /proc/$pid/fd | wc -l)" >> $out/phases.txt
if [ "${PERF:-1}" = 1 ]; then
  taskset -c 2,3 $S/brokers/lavinmqperf throughput -x 2 -y 2 -s 256 -r $PERF_RATE -z $((secs + 600)) -q -u perf > $out/perf.log 2>&1 &
  perfpid=$!
else
  : > $out/perf.log; perfpid=0
fi
sleep 10
echo "steady_start $(mono)" >> $out/phases.txt
sleep $secs
echo "steady_end $(mono)" >> $out/phases.txt
curl -s -u guest:guest http://127.0.0.1:15672/metrics > $out/metrics.end
echo "heap_bytes_at_end $(awk '$1 == "lavinmq_gc_heap_size_bytes" {print $2}' $out/metrics.end) connections $(awk '$1 == "lavinmq_connections" {print $2}' $out/metrics.end) rss_kb $(awk '/VmRSS/{print $2}' /proc/$pid/status)" >> $out/phases.txt
echo $out/census.txt > $out/gc.pauses.census-request
for i in $(seq 120); do [ -s $out/census.txt ] && break; sleep 1; done
cat /proc/$pid/smaps_rollup > $out/smaps_rollup.txt
[ $perfpid != 0 ] && kill $perfpid 2>/dev/null; pkill -f "$S/bench/driver storm"; [ $perfpid != 0 ] && wait $perfpid 2>/dev/null
sleep 2; kill $pid; wait $pid 2>/dev/null
rm -f $out/metrics.tmp $out/metrics.last
python3 -I $(dirname "$0")/summarize_sim.py $v $out

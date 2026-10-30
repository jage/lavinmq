#!/bin/bash
# run_small.sh <variant> <mode> <seconds>: run_broker.sh with 1 publisher/1 consumer at 1000 msg/s and RSS/smaps capture
set -u
S=$SCRATCH
v=$1; mode=$2; secs=$3
out=$S/runs/$v-$mode; rm -rf $out; mkdir -p $out/data
cat > $out/lavinmq.ini <<EOF
[main]
data_dir = $out/data
stats_interval = 500
stats_log_size = 120
log_level = warn
[mgmt]
bind = 127.0.0.1
[amqp]
bind = 127.0.0.1
EOF
GC_PAUSE_FILE=$out/gc.pauses $S/brokers/lavinmq-$v -c $out/lavinmq.ini > $out/broker.log 2>&1 &
pid=$!
until curl -s -o /dev/null -u guest:guest http://127.0.0.1:15672/api/overview; do sleep 0.2; done
# light load: 1000 msg/s, 1 publisher, 1 consumer
if [ "${PERF:-1}" = 1 ]; then
  $S/brokers/lavinmqperf throughput -x 1 -y 1 -s 256 -r 1000 -z $((secs + 30)) -q -u perf > $out/perf.log 2>&1 &
  perfpid=$!
else
  echo > $out/perf.log; perfpid=0
fi
if [ -n "${CENSUS_AT:-}" ]; then
  ( until grep -q measure_start $out/driver.log 2>/dev/null; do sleep 1; done
    sleep $CENSUS_AT; echo $out/census.txt > $out/gc.pauses.census-request ) &
fi
( while kill -0 $pid 2>/dev/null; do
    rss=$(awk '/VmRSS/{print $2}' /proc/$pid/status 2>/dev/null)
    tick=$(curl -s -u guest:guest http://127.0.0.1:15672/metrics | awk '/^lavinmq_stats_rates_collection_duration_seconds /{print $2}')
    echo "$(date +%s.%N) $rss $tick"
    sleep 1
  done ) > $out/samples.txt &
( until grep -q measure_start $out/driver.log 2>/dev/null; do sleep 0.2; done; awk '/VmRSS/{print $2}' /proc/$pid/status > $out/rss_start.txt ) &
FLAP=${FLAP:-1} $S/bench/driver $mode $secs > $out/driver.log 2>&1
[ $perfpid != 0 ] && { kill $perfpid 2>/dev/null; wait $perfpid 2>/dev/null; }
awk '/VmRSS/{print $2}' /proc/$pid/status > $out/rss_end.txt; cat /proc/$pid/smaps_rollup > $out/smaps_rollup.txt
kill $pid; wait $pid 2>/dev/null
python3 -I $S/bench/summarize_small.py $v $mode $out

#!/bin/bash
# plan.sh <first round> <last round>: interleaved rounds of the five variants, full load
# (churn 240 s, PERF=1, FLAP=1). Copies each run's output to runs/r<N>-<variant>/.
set -u
R=$SCRATCH/bench/run_broker.sh
res=$(cd "$(dirname "$0")" && pwd)
clean() {
  pkill -f 'brokers/lavinmq' ; pkill -f 'bench/driver'; sleep 2
  pkill -9 -f 'brokers/lavinmq'; pkill -9 -f 'bench/driver'
  while ss -ltn | grep -qE ':(5672|15672)\b'; do sleep 1; done
}
for i in $(seq "$1" "$2"); do
  echo "=== round $i $(date -u +%FT%TZ)"
  for v in main main-socket digest digest-socket digest-socket-1k; do
    clean
    d=$res/runs/r$i-$v; rm -rf "$d"; mkdir -p "$d"
    vmstat 1 5 > "$d/vmstat.txt"
    bin=$v; env=()
    [ $v = digest-socket-1k ] && { bin=digest-socket; env=(GC_BYTES_PER_FINALIZER=1000); }
    line=$(env "${env[@]}" $R $bin churn 240)
    echo "r$i $v | $line" | tee -a "$res/summary.txt"
    src=$SCRATCH/runs/$bin-churn
    cp "$src"/{driver.log,perf.log,samples.txt,broker.log,lavinmq.ini} "$d/"
    cp "$src"/gc.pauses* "$d/"
    rm -rf "$src"
  done
done
clean

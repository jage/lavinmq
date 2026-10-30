#!/bin/bash
# plan.sh <first round> <last round>: interleaved rounds of main / combo16k / combo32k, full load
# (churn 200/s, flapping queues, lavinmqperf ~20k msg/s), 240 s each. Copies each run's logs into
# runs/<variant>-r<round>/ and appends the summary line to summaries.txt.
set -u
here=$(cd "$(dirname "$0")" && pwd)
for r in $(seq $1 $2); do
  echo "== round $r $(date -u +%FT%TZ)" | tee -a $here/vmstat.txt
  vmstat 1 5 >> $here/vmstat.txt
  for v in main combo16k combo32k; do
    pkill -f 'lavinmq-|bench/driver|lavinmqperf' ; sleep 2
    while (exec 3<>/dev/tcp/127.0.0.1/5672) 2>/dev/null || (exec 3<>/dev/tcp/127.0.0.1/15672) 2>/dev/null; do sleep 1; done
    line=$(PERF=1 FLAP=1 $SCRATCH/bench/run_broker.sh $v churn 240)
    echo "r$r $line" | tee -a $here/summaries.txt
    d=$here/runs/$v-r$r; rm -rf $d; mkdir -p $d
    src=$SCRATCH/runs/$v-churn
    cp $src/gc.pauses* $src/driver.log $src/perf.log $src/samples.txt $src/broker.log $d/
  done
done

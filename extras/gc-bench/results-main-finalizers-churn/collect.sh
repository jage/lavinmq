#!/bin/bash
# collect.sh: runs analyze.py over every r*/<variant> dir into runs.jsonl
D=$(cd "$(dirname "$0")" && pwd)
for r in $D/r*/; do for v in main main-socket digest digest-socket digest-socket-1k; do
  [ -f $r$v/driver.log ] && python3 -I $D/analyze.py $r$v $(readlink -f $SCRATCH/brokers/lavinmq-$v)
done; done > $D/runs.jsonl

#!/bin/bash
set -eu
. $HOME/gcbench/env.sh
here=/home/user/lavinmq/extras/gc-bench
out=$here/results-main-finalizers-churn
cp $here/{summarize.py,phases.py,fincount.py,run_broker.sh,run_broker_forcegc.sh} $SCRATCH/bench/
CRYSTAL_PATH="$SCRATCH/src-main/lib:$(crystal env CRYSTAL_PATH)" crystal build --release $here/driver.cr -o $SCRATCH/bench/driver
(cd $SCRATCH/src-main && crystal build --release src/lavinmqperf.cr -o $SCRATCH/brokers/lavinmqperf)
echo built driver perf
for s in main digest; do
  src=$SCRATCH/src-$s
  sed 's|require "./typetable"|require "./zz_typetable"|' $here/gc_pauses.cr > $src/src/zz_gc_pauses.cr
  cp $here/typetable.cr $src/src/zz_typetable.cr
  cp $out/zz_socket_unregister.cr $src/src/zz_socket_unregister.cr
  for sock in "" "-socket"; do
    if [ -z "$sock" ]; then printf 'require "./zz_gc_pauses"\nrequire "./lavinmq"\n' > $src/src/zz_bench.cr
    else printf 'require "./zz_gc_pauses"\nrequire "./zz_socket_unregister"\nrequire "./lavinmq"\n' > $src/src/zz_bench.cr; fi
    (cd $src && crystal build --release src/zz_bench.cr -o $SCRATCH/brokers/lavinmq-$s$sock)
    echo built $s$sock
  done
  rm -f $src/src/zz_*.cr
done

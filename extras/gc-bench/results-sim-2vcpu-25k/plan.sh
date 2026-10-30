#!/bin/bash
# Plan: per round, variants interleaved (start rotated each round): storm + 300 s steady.
# Then one GC_PRINT_STATS storm run per variant (30 s steady).
set -u
res=$(cd "$(dirname "$0")" && pwd)
VS=(${VARIANTS:-main combo32k v2102})
n=${#VS[@]}
clean() {
  pkill -f "$SCRATCH/brokers/lavinmq-"; pkill -f "$SCRATCH/bench/driver"; pkill -f lavinmqperf
  for port in 5672 15672; do while (exec 3<>/dev/tcp/127.0.0.1/$port) 2>/dev/null; do sleep 1; done; done
  sleep 2
}
keep() { # keep <run dir> <dest>
  mkdir -p $2
  (cd $1 && cp gc.pauses gc.pauses.allocs gc.pauses.finalizers gc.pauses.watchdog gc_version.txt markers.txt limits.txt \
     phases.txt declare.log driver0.log driver1.log perf.log rss.txt scrapes.txt census.txt smaps_rollup.txt \
     metrics.end lavinmq.ini $2/ 2>/dev/null)
  gzip -c $1/broker.log > $2/broker.log.gz; gzip -c $1/gc.pauses.traces > $2/gc.pauses.traces.gz
  sed -i "s|$SCRATCH|\$SCRATCH|g" $2/lavinmq.ini
}
push() {
  if grep -rIl "cloudamqp\.com" $res; then echo "identifying string found, not pushing"; return 1; fi
  cd /home/user/lavinmq && git add extras/gc-bench && git commit -qm "$1" && \
  for d in 2 4 8 16 0; do git push -q -u origin gc-bench-sim-2vcpu-25k && break; [ $d = 0 ] || sleep $d; done
}
{ echo "nproc $(nproc)"; lscpu | head -20; crystal --version | head -1; grep "open files" /proc/self/limits;
  cat /proc/sys/net/ipv4/ip_local_port_range; } > $res/system.txt
for r in ${ROUNDS:-1 2}; do
  for k in $(seq 0 $((n - 1))); do
    v=${VS[$(( (k + r - 1) % n ))]}
    clean
    { echo "== r$r $v"; vmstat 1 5; } >> $res/vmstat.txt
    echo -n "r$r | " >> $res/summary.txt
    $res/run_sim.sh $v $SCRATCH/runs/r$r-$v ${STEADY:-300} | tee -a $res/summary.txt
    keep $SCRATCH/runs/r$r-$v $res/runs/r$r-$v
    push "Sim 2-vCPU many-connection cluster: round $r $v"
  done
done
if [ "${DIAGS:-1}" = 1 ]; then
  for v in ${VS[@]}; do
    clean
    { echo "== diag $v"; vmstat 1 5; } >> $res/vmstat.txt
    echo -n "diag | " >> $res/summary.txt
    DIAG=1 $res/run_sim.sh $v $SCRATCH/runs/diag-$v 30 | tee -a $res/summary.txt
    keep $SCRATCH/runs/diag-$v $res/runs/diag-$v
    grep -E "Mark stack overflow|Grew mark stack|mark stack" $SCRATCH/runs/diag-$v/broker.log | sort | uniq -c | sort -rn | head -20 > $res/runs/diag-$v/mark-stack.txt
  done
  push "Sim 2-vCPU many-connection cluster: GC_PRINT_STATS runs"
fi
clean
echo PLAN DONE

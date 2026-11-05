#!/usr/bin/env bash
# overhead.sh <pid> <runs> <seconds> -- <lavinmqperf throughput args>
#
# Runs the lavinmqperf load <runs> times with no tool attached and with each
# tool attached, printing per run the average publish rate and the broker's
# CPU time (ms per second of wall time), and the fiber switch rate.
#   extras/bpf/test/overhead.sh $(pidof lavinmq) 3 15 -- -x 2 -y 2 -s 256
# TOOLS="none evloop" limits the tools.
set -euo pipefail
dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
pid=$1 runs=$2 secs=$3
shift 4
perf=${LAVINMQPERF:-bin/lavinmqperf}
hz=$(getconf CLK_TCK)
cpu_ticks() { awk '{ print $14 + $15 }' "/proc/$pid/stat"; }

for tool in ${TOOLS:-none gc evloop stalls fibers oncpu sched}; do
  for run in $(seq "$runs"); do
    tpid=""
    if [ "$tool" != none ]; then
      log=$(mktemp)
      INTERVAL=3600 "$dir/lavinmq-bpf" "$tool" "$pid" > "$log" 2>&1 &
      tpid=$!
      until grep -q 'Ctrl-C to stop' "$log"; do sleep 0.5; done # attached
    fi
    sleep 5 # let the previous run's connections close
    c0=$(cpu_ticks) t0=$(date +%s%N)
    rate=$("$perf" amqp throughput -z "$secs" -q "$@" 2>&1 | awk '/publish rate/ { print $4 }')
    c1=$(cpu_ticks) t1=$(date +%s%N)
    cpu=$(((c1 - c0) * 1000 * 1000000000 / hz / (t1 - t0)))
    if [ -n "$tpid" ]; then
      pkill -INT -P "$tpid" bpftrace 2> /dev/null || true
      wait "$tpid" 2> /dev/null || true
      rm -f "$log"
    fi
    echo "$tool run=$run publish_rate=$rate broker_cpu_ms_per_s=$cpu"
  done
done

# fiber switches per second under the same load
out=$(mktemp)
bpftrace -q -p "$pid" -e "uprobe:/proc/$pid/exe:\"*Fiber::swapcontext<Pointer(Fiber::Context), Pointer(Fiber::Context)>:Nil\" { @s = count(); }
  interval:s:10 { exit(); }" 2> /dev/null > "$out" &
bt=$!
sleep 1
"$perf" amqp throughput -z 12 -q "$@" > /dev/null 2>&1 || true
wait $bt || true
awk '/@s:/ { print "fiber switches per second:", $2 / 10 }' "$out"
rm -f "$out"

#!/bin/bash
# run_throughput.sh <variant> <msg size> <seconds>: broker at full speed, 2 publishers and
# 2 consumers without a rate limit, then one summary line: publish and consume rates, broker CPU
# per consumed message, collections, GC time. lavinmqperf runs 5 s longer than the window and
# the window starts 5 s in, so connection setup and queue declaration are outside it.
# BPF=profile|record also runs extras/bpf/lavinmq-bpf <tool> over the window into the run dir.
set -u
S=$SCRATCH
v=$1; size=$2; secs=$3
out=$S/runs/tp-$v-$size-${RUN:-0}; rm -rf "$out"; mkdir -p "$out/data"
printf '[main]\ndata_dir = %s\nlog_level = warn\n[mgmt]\nbind = 127.0.0.1\n[amqp]\nbind = 127.0.0.1\n' "$out/data" > "$out/lavinmq.ini"
GC_PAUSE_FILE=$out/gc.pauses "$S/brokers/lavinmq-$v" -c "$out/lavinmq.ini" > "$out/broker.log" 2>&1 &
pid=$!
until curl -s -o /dev/null -u guest:guest http://127.0.0.1:15672/api/overview; do sleep 0.2; done
"$S/brokers/lavinmqperf" throughput -x 2 -y 2 -s "$size" -z $((secs + 5)) -q > "$out/perf.log" 2>&1 &
perfpid=$!
sleep 5
cpu() { awk '{print $14 + $15}' /proc/$pid/stat; }
mono() { python3 -Ic "import time; print(time.monotonic_ns())"; }
c0=$(cpu); t0=$(mono)
if [ -n "${BPF:-}" ]; then
  OUT=$out/$BPF timeout -s INT $((secs + 2)) "$S/bpf/lavinmq-bpf" "$BPF" $pid $secs > "$out/bpf.log" 2>&1 &
  bpfpid=$!
fi
rss=0
for _ in $(seq "$secs"); do
  r=$(awk '/VmRSS/{print $2}' /proc/$pid/status); [ "$r" -gt "$rss" ] && rss=$r
  sleep 1
done
c1=$(cpu); t1=$(mono)
wait $perfpid
# bpftrace resolves symbols from /proc/<pid>/exe when it exits: keep the broker until then
[ -n "${BPF:-}" ] && wait $bpfpid
sleep 1
kill $pid; wait $pid 2>/dev/null
wait
python3 -I - "$v" "$size" "$out" "$t0" "$t1" "$c0" "$c1" "$rss" "$(getconf CLK_TCK)" <<'EOF'
import sys, re
v, size, out = sys.argv[1:4]
t0, t1, c0, c1, rss, hz = map(int, sys.argv[4:10])
perf = open(f"{out}/perf.log").read()
pub = int(re.search(r"Average publish rate: (\d+)", perf).group(1))
con = int(re.search(r"Average consume rate: (\d+)", perf).group(1))
p = sorted(int(l.split()[1]) / 1e6 for l in open(f"{out}/gc.pauses") if t0 <= int(l.split()[0]) <= t1)
secs = (t1 - t0) / 1e9
cpu_ms = (c1 - c0) * 1000 / hz
pct = lambda q: p[min(len(p) - 1, int(len(p) * q))] if p else 0
print(f"{v:11} size {size:>6} pub/s {pub:7d} con/s {con:7d} | broker cpu {cpu_ms / secs / 10:5.1f}% "
      f"{cpu_ms * 1000 / max(con * secs, 1):6.2f} us/msg | gcs/s {len(p) / secs:5.1f} gc ms/s {sum(p) / secs:6.1f} "
      f"pause p50 {pct(.5):5.2f} max {max(p) if p else 0:6.2f} ms | rss peak {rss // 1024} MB")
EOF

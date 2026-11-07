#!/bin/bash
# tp-check.sh <lavinmq binary> <label>: 20 s of lavinmqperf throughput (2 publishers, 2 consumers,
# 16 B, no rate limit) against a fresh broker; prints "TP <label> pub <n> con <n> cpu <%>".
set -u
here=$(cd "$(dirname "$0")" && pwd); . "$here/env.sh"
bin=$1 label=$2
d=$(mktemp -d "$CB/runs/tp-XXXX"); mkdir -p "$d/data"
printf '[main]\ndata_dir = %s\nlog_level = warn\n[mgmt]\nbind = 127.0.0.1\nport = 15699\n[amqp]\nbind = 127.0.0.1\nport = 5699\n' "$d/data" > "$d/lavinmq.ini"
"$bin" -c "$d/lavinmq.ini" > "$d/broker.log" 2>&1 &
pid=$!
for _ in $(seq 100); do curl -s -o /dev/null -u guest:guest http://127.0.0.1:15699/api/overview && break; sleep 0.2; done
c0=$(awk '{print $14 + $15}' /proc/$pid/stat)
"$CB/lavinmqperf" throughput --uri=amqp://guest:guest@127.0.0.1:5699 -x 2 -y 2 -s 16 -z 20 -q > "$d/perf.log" 2>&1
c1=$(awk '{print $14 + $15}' /proc/$pid/stat)
kill $pid; wait $pid 2> /dev/null
pub=$(awk '/Average publish rate/{print $4}' "$d/perf.log"); con=$(awk '/Average consume rate/{print $4}' "$d/perf.log")
echo "TP $label pub ${pub:-0} con ${con:-0} cpu $(( (c1 - c0) * 100 / $(getconf CLK_TCK) / 20 ))%"
rm -rf "$d"

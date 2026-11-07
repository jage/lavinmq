#!/bin/bash
# spec-run.sh <results file> <label> <spec binary> <workload>: runs a spec binary built by
# measure.sh (KEEP_BIN=1) with GC_PRINT_STATS and /usr/bin/time from the workload's source dir;
# appends a summary line (wall, CPU, examples and failures, GC) to $CB/results/<file>.txt.
# GC_* env passes through (it applies to the spec process).
set -u
here=$(cd "$(dirname "$0")" && pwd); . "$here/env.sh"
file=$1 label=$2 bin=$3 wl=$4
case $wl in lmq-spec) dir=$LMQ; args="--order random" ;; crstd-spec|crsem-spec) dir=$CRSRC; args= ;; esac
out=$CB/runs/$file-$label-$wl-run; rm -rf "$out"; mkdir -p "$out"
cd "$dir"
GC_PRINT_STATS=1 /usr/bin/time -v "$bin" $args > "$out/stdout" 2> "$out/stderr"
rc=$?
python3 -I - "$label" "$wl" "$out" "$rc" <<'PY' | tee -a "$CB/results/$file.txt"
import re, sys
label, wl, out, rc = sys.argv[1:]
so = open(f"{out}/stdout", errors="replace").read(); se = open(f"{out}/stderr", errors="replace").read()
gc = [int(a) * 1e6 + int(b) for a, b in re.findall(r"Complete collection took (\d+) ms (\d+) ns", se)]
w = re.search(r"Elapsed \(wall clock\) time \(h:mm:ss or m:ss\): ([\d:.]+)", se)
wall = sum(float(x) * 60 ** i for i, x in enumerate(reversed(w.group(1).split(":")))) if w else 0
num = lambda p: float(re.search(p, se).group(1)) if re.search(p, se) else 0
cpu = num(r"User time \(seconds\): ([\d.]+)") + num(r"System time \(seconds\): ([\d.]+)")
rss = int(num(r"Maximum resident set size \(kbytes\): (\d+)")) // 1024
m = re.search(r"(\d+) examples, (\d+) failures, (\d+) errors", so)
ex = f"{m.group(1)} ex {m.group(2)} fail {m.group(3)} err" if m else "no summary"
print(f"RUN {label:20} {wl:12} rc={rc} wall {wall:7.1f} s cpu {cpu:7.1f} s | {ex} | gc {len(gc):4d} colls {sum(gc)/1e9:6.2f} s max {max(gc)/1e6 if gc else 0:5.0f} ms | rss {rss} MB")
PY

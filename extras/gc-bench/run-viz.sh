#!/bin/bash
# The bpf visualisations of PLAN-acton.md, after run-matrix.sh (they add probe overhead, so they
# are separate runs, not the measured ones). Output in $SCRATCH/viz:
#   b1-diff.svg, b1-report.html  CPU profiles of fix vs acton at full speed (16 B messages)
#   b3-report.html               20 s recordings of stock, fix and acton under full load
set -eu
: "${SCRATCH:?set SCRATCH}"
S=$SCRATCH; V=$S/viz; mkdir -p "$V"
export SCRATCH SOURCE_URL=https://github.com/cloudamqp/lavinmq/blob/359fab1c
for v in fix acton; do
  BPF=profile RUN=viz "$S/bench/run_throughput.sh" $v 16 30
  cp "$S/runs/tp-$v-16-viz/profile.folded" "$V/b1-$v.folded"
  cp "$S/runs/tp-$v-16-viz/profile.svg" "$V/b1-$v.svg"
done
OUT=$V/b1-diff "$S/bpf/lavinmq-bpf" diff "$V/b1-fix.folded" "$V/b1-acton.folded"
OUT=$V/b1-report "$S/bpf/lavinmq-bpf" report "$V/b1-fix.folded" "$V/b1-acton.folded"
for v in stock fix acton; do
  (cd "$S/bench" && BPF=record BPF_AT=60 BPF_SECS=20 ./run_broker.sh $v churn 120)
  cp "$S/runs/$v-churn/record.trace" "$V/b3-$v.trace"
  cp "$S/runs/$v-churn/record.lines" "$V/b3-$v.lines" 2>/dev/null || true
done
OUT=$V/b3-report "$S/bpf/lavinmq-bpf" report "$V/b3-stock.trace" "$V/b3-fix.trace" "$V/b3-acton.trace"
ls -la "$V"

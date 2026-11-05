#!/bin/bash
# Runs the scenarios of PLAN-acton.md, interleaving the variants within each round, and appends
# one line per run to $SCRATCH/matrix/<scenario>.txt. PHASES="M A B1 B2 B3" picks phases.
# A variant "acton+refill8" is the acton binary with GC_TL_REFILL_MAX=8.
set -u
: "${SCRATCH:?set SCRATCH}"
S=$SCRATCH; M=$S/matrix; mkdir -p "$M"
export SCRATCH
log() { echo "$(date +%T) $*" >&2; }
bin() { echo "${1%%+*}"; }                       # acton+refill8 -> acton
alias_bin() { [ "$1" = "$(bin "$1")" ] || ln -sfn "lavinmq-$(bin "$1")" "$S/brokers/lavinmq-$1"; }
envof() { case $1 in *+refill8) echo GC_TL_REFILL_MAX=8 ;; *+bpm4m) echo GC_BYTES_PER_MARKER=4M ;; *) echo X_=0 ;; esac; }

for phase in ${PHASES:-M A B1 B2 B3}; do
  case $phase in
  M)
    for r in $(seq ${MREPS:-5}); do
      for v in stock fix fix-pf acton acton-nopf acton-noinl; do
        for m in 1 4; do
          echo "M1 $v r$r $(TREE=1 GC_MARKERS=$m "$S/mark/mark-$v" 0 2000000)" >> "$M/M1.txt"
          echo "M2 $v r$r $(LEAVES=1 GC_MARKERS=$m "$S/mark/mark-$v" 0 2000000)" >> "$M/M2.txt"
        done
        echo "M3 $v r$r $(TREE=1 GC_MARKERS=4 "$S/mark/mark-$v" 6500 2000000)" >> "$M/M3.txt"
      done
      log "M round $r done"
    done ;;
  A)
    for r in $(seq ${AREPS:-5}); do
      for v in stock fix acton acton-noinl acton+refill8; do
        for t in 1 2 4; do
          echo "A1 $v r$r $(env $(envof $v) "$S/mark/alloc-$(bin $v)" $t 10 200000)" >> "$M/A1.txt"
        done
      done
      log "A round $r done"
    done ;;
  B1)
    for r in $(seq ${BREPS:-3}); do
      for size in 16 1024; do
        for v in stock fix fix-pf acton acton-nopf acton-noinl acton+refill8; do
          alias_bin "$v"
          echo "B1 r$r $(env $(envof $v) RUN=$r "$S/bench/run_throughput.sh" "$v" $size 30)" >> "$M/B1.txt"
        done
      done
      log "B1 round $r done"
    done ;;
  B2)
    for r in $(seq ${BREPS:-3}); do
      for v in stock fix fix-pf acton acton-nopf acton+bpm4m; do
        alias_bin "$v"
        line=$(cd "$S/bench" && env $(envof $v) PERF=0 FLAP=0 ./run_broker_forcegc.sh "$v" none 60 | head -1)
        mv "$S/runs/$v-none" "$S/runs/B2-$v-r$r"
        echo "B2 r$r $line" >> "$M/B2.txt"
      done
      log "B2 round $r done"
    done ;;
  B3)
    for r in $(seq ${BREPS:-3}); do
      for v in stock fix fix-pf acton; do
        line=$(cd "$S/bench" && ./run_broker.sh "$v" churn 240 | head -1)
        mv "$S/runs/$v-churn" "$S/runs/B3-$v-r$r"
        echo "B3 r$r $line" >> "$M/B3.txt"
      done
      log "B3 round $r done"
    done ;;
  B3U) # B3 with GC_UNMAP_THRESHOLD=1, as LavinMQ's Docker image runs
    for r in $(seq ${BREPS:-3}); do
      for v in fix acton; do
        line=$(cd "$S/bench" && GC_UNMAP_THRESHOLD=1 ./run_broker.sh "$v" churn 240 | head -1)
        mv "$S/runs/$v-churn" "$S/runs/B3U-$v-r$r"
        echo "B3U r$r $line" >> "$M/B3U.txt"
      done
      log "B3U round $r done"
    done ;;
  esac
done
log "matrix done"

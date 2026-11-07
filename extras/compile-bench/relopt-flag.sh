#!/bin/bash
# relopt follow-up: `--release` also defines flag?(:release), which LavinMQ uses to compile out
# debug logging. Builds -O3/-O2/-O1 (multi-module) with -Drelease and -O3 --single-module without it,
# so the throughput difference splits into the release flag and single-module optimization.
# SINGLE=1: single-module at -O2 and -O1 against --release (results in relopt-single*.txt).
set -u
here=$(cd "$(dirname "$0")" && pwd); . "$here/env.sh"
M=$here/measure.sh; P=/usr/bin/crystal; rounds=${1:-2}
f=relopt-flag; vs=("release lmq-release" "O3+rel lmq-O3 -Drelease" "O2+rel lmq-O2 -Drelease" "O1+rel lmq-O1 -Drelease" "O3+single lmq-O3 --single-module")
[ "${SINGLE:-0}" = 1 ] && f=relopt-single vs=("release lmq-release" "O2+single lmq-O2 --single-module -Drelease" "O1+single lmq-O1 --single-module -Drelease")
for r in $(seq $rounds); do
  for v in "${vs[@]}"; do
    set -- $v; label=$1 wl=$2; shift 2
    EXTRA="$*" KEEP_BIN=1 $M $f $label-r$r $wl $P
    for i in 1 2; do "$here/tp-check.sh" "$CB/runs/$f-$label-r$r-$wl/bin" "$label-r$r" >> "$CB/results/$f-tp.txt"; done
    rm -f "$CB/runs/$f-$label-r$r-$wl/bin"
  done
done
echo "$f done" >&2

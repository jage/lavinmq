#!/bin/bash
# Copies the kept runs (no data dirs) into runs/ next to this script and refreshes summaries
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p $here/runs
for d in $SCRATCH/keep/*; do
  n=$(basename $d); mkdir -p $here/runs/$n
  (cd $d && cp gc.pauses* driver.log perf.log samples.txt broker.log lavinmq.ini $here/runs/$n/ 2>/dev/null)
done
cp $SCRATCH/logs/plan.out $here/summaries.txt
python3 -I $here/analyze.py $(ls -d $here/runs/r* | sort -V) > $here/table.md
[ -n "$(ls -d $here/runs/diag-* 2>/dev/null)" ] && python3 -I $here/analyze.py $here/runs/diag-* > $here/table-diag.md
true

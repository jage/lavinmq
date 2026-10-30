#!/bin/bash
# Step 4: global broker, GC_MARKERS=4, full load for 900 s with GC_PRINT_STATS=1 and GC_LOG_FILE;
# samples the cumulative "Mark stack overflow" / "Grew mark stack" counts every 10 s.
set -u
RES=${RES:?}; mkdir -p $RES/gclog
cd $SCRATCH/bench
log=$RES/gclog/gc-stats.log; rm -f $log
sed "s|^GC_PAUSE_FILE=|GC_PRINT_STATS=1 GC_LOG_FILE=$log GC_PAUSE_FILE=|" run_broker_frozen.sh > run_broker_gclog.sh
chmod +x run_broker_gclog.sh
cp run_broker_gclog.sh $RES/gclog/
( t0=$(date +%s)
  while ! [ -f $log ]; do sleep 1; done
  while pgrep -f "lavinmq-global -c" > /dev/null; do
    echo "$(( $(date +%s) - t0 )) $(grep -c 'Mark stack overflow' $log) $(grep -c 'Grew mark stack' $log) $(grep -c 'Marking for collection' $log)"
    sleep 10
  done ) > $RES/gclog/counts.txt &
GC_MARKERS=4 ./run_broker_gclog.sh global churn 900 | tee $RES/gclog/summary.txt
python3 -I phases.py $SCRATCH/runs/global-churn "global m=4 gclog" | tee $RES/gclog/phases.txt
rm -rf $SCRATCH/runs/global-churn/data
cp -r $SCRATCH/runs/global-churn $RES/gclog/run
wait

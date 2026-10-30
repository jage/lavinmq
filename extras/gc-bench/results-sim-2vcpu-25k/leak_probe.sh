#!/bin/bash
# leak_probe.sh <variant> <minutes>: storm, then <minutes> of 37 reconnects/s and 830 msg/s with a
# census every 60 s (reachable objects by type, live fibers by name, and with GC_CENSUS_HOLDERS
# what holds closed TCPSockets and dead Fibers). Each census forces a collection.
res=$(cd "$(dirname "$0")" && pwd)
v=$1 mins=$2 out=$SCRATCH/runs/leak-$v
export GC_CENSUS_HOLDERS=1
$res/run_sim.sh $v $out $((mins * 60 + 30)) > $SCRATCH/leak-$v.json &
until grep -q steady_start $out/phases.txt 2>/dev/null; do sleep 1; done
for m in $(seq 1 $mins); do
  sleep 60
  echo $out/census-$m.txt > $out/gc.pauses.census-request
done
wait
dst=$res/runs/leak-$v; mkdir -p $dst
(cd $out && cp census*.txt phases.txt scrapes.txt rss.txt gc.pauses gc.pauses.watchdog driver0.log driver1.log $dst/)
python3 -I $res/leak_table.py $dst > $dst/per-minute.md

# Broker GC results: bdwgc 8.2.8 "global" mark-stack patch vs Crystal's bundled libgc

Measured 2026-10-30 on a 4-vCPU KVM VM (Intel Xeon @ 2.30GHz, 1 thread per core, 15 GB RAM).
Brokers: gc-heap-stats (d3e5aad) + password-digest-without-finalizer (8d9aee4) with the GC hook,
Crystal 1.21.0, built by `setup.sh`. `bundled` links Crystal's own libgc.a, `global` links bdwgc
8.2.8 with `bdwgc-mark-stack-overflow-global.patch`, `bigstack` links unpatched 8.2.8 with a
262,144-entry initial mark stack. Both libgc builds report version 8.2.8.

## Summary

- **Full load** (20k flapping queues, 200 reconnects/s, 20k msg/s, 240 s): pause p50 drops from
  **64–70 ms** (bundled, `GC_MARKERS=1`) to **30–33 ms** (global, 4 markers or default), and GC
  time from **273–290 ms/min** to **163–199 ms/min**. The global figure includes three ~100–145 ms
  collections right after the 2,000 connections open, while the mark stack is still growing; after
  them global pauses peak at 34–41 ms, like bigstack (max 35–37 ms, 87–96 ms/min). Mark phase p50:
  56–60 ms bundled vs 24–25 ms global and bigstack.
- **Idle broker, forced collection every 3 s, default markers**: pause p50 **92–97 ms** bundled vs
  **21–22 ms** global, GC time **1,872–2,043 ms/min** vs **648–700 ms/min** (bigstack 430–456; the
  difference is the same three slow collections). Bundled with 2 or more markers is about twice
  as slow as with 1 (92–98 ms vs 49–61 ms), the overflow problem; with the global patch more
  markers help: 46–48 ms at 1, 29–32 ms at 2, 21–22 ms at 4.
- **The stack stops growing.** Over 15 minutes of full load with the global patch, the mark stack
  overflowed in exactly three consecutive collections (#81–#83, the first three after the
  connection pool opened; 37, 34 and 20 overflows), grew 4,096 → 8,192 → 16,384 → 32,768 entries,
  and then never overflowed or grew again in the remaining 36 collections (~14 minutes).
- **Marker threads**: the broker reports `lavinmq_gc_marker_threads 3` for bundled, global and
  bigstack (the metric excludes the initiating thread, so 4 markers) on this 4-CPU VM, so
  "default" equals `GC_MARKERS=4` here and the two rows agree.

Noise: each 240 s load run has only 11–19 collections in its measurement window, so GC ms/min
varies by ±15% between runs (global default: 168 vs 199, 13 vs 19 collections). Pause p50 is
stable within ~3 ms across the two rounds. The first idle run (bundled m=1, round 1, 60.7 ms)
looks like a cold-start outlier; round 2 gave 49.4 ms. Idle bundled and global at m=1 are within
noise of each other (46–50 ms, excluding that outlier), so the two libgc builds are comparable
apart from the patch. Nothing failed.

## Idle broker, forced collections (`run_broker_forcegc.sh <broker> none 60`, PERF=0, FLAP=0)

Window: 60 s after the driver has declared 20k queues and opened 2,000 connections; a collection
is forced every 3 s. Times in ms. "max after 3rd" is the largest pause after the first three
collections of the window (where the global stack is still growing; the first collections after the
connection pool opens are somewhat larger for every libgc, so this column is only indicative).

| config | run | GCs | GCs/min | pause p50 | p99 | max | mark p50 | GC ms/min | max after 3rd |
|---|---|--:|--:|--:|--:|--:|--:|--:|--:|
| bundled-m1 | 1 | 20 | 20.0 | 60.7 | 101.6 | 101.6 | 57.6 | 1276 | 85.1 |
| bundled-m1 | 2 | 20 | 20.0 | 49.4 | 104.5 | 104.5 | 46.8 | 1151 | 78.9 |
| global-m1 | 1 | 20 | 20.0 | 47.8 | 96.4 | 96.4 | 45.5 | 1174 | 82.9 |
| global-m1 | 2 | 20 | 20.0 | 46.0 | 93.9 | 93.9 | 43.6 | 1100 | 67.2 |
| bigstack-m1 | 1 | 20 | 20.0 | 48.1 | 85.3 | 85.3 | 46.0 | 1066 | 85.3 |
| bigstack-m1 | 2 | 20 | 20.0 | 50.4 | 91.3 | 91.3 | 48.2 | 1157 | 91.3 |
| bundled-m2 | 1 | 19 | 19.0 | 97.9 | 135.8 | 135.8 | 95.6 | 1986 | 135.8 |
| bundled-m2 | 2 | 20 | 20.0 | 94.6 | 148.2 | 148.2 | 92.5 | 1958 | 148.2 |
| global-m2 | 1 | 20 | 20.0 | 32.1 | 112.9 | 112.9 | 29.6 | 853 | 42.7 |
| global-m2 | 2 | 20 | 20.0 | 28.7 | 99.5 | 99.5 | 26.5 | 800 | 36.9 |
| bigstack-m2 | 1 | 20 | 20.0 | 30.1 | 36.5 | 36.5 | 27.6 | 615 | 36.5 |
| bigstack-m2 | 2 | 20 | 20.0 | 29.0 | 35.4 | 35.4 | 26.8 | 603 | 35.4 |
| bundled-m4 | 1 | 20 | 20.0 | 92.8 | 134.5 | 134.5 | 90.5 | 1936 | 114.7 |
| bundled-m4 | 2 | 19 | 19.0 | 95.5 | 141.4 | 141.4 | 93.1 | 1999 | 141.4 |
| global-m4 | 1 | 20 | 20.0 | 21.4 | 152.7 | 152.7 | 19.1 | 748 | 28.9 |
| global-m4 | 2 | 20 | 20.0 | 22.3 | 144.3 | 144.3 | 20.0 | 746 | 32.9 |
| bigstack-m4 | 1 | 20 | 20.0 | 22.4 | 28.7 | 28.7 | 20.1 | 460 | 28.7 |
| bigstack-m4 | 2 | 20 | 20.0 | 22.1 | 31.4 | 31.4 | 19.6 | 454 | 31.4 |
| bundled-mdefault | 1 | 20 | 20.0 | 96.5 | 135.4 | 135.4 | 94.2 | 2043 | 135.4 |
| bundled-mdefault | 2 | 20 | 20.0 | 91.5 | 116.7 | 116.7 | 89.4 | 1872 | 116.7 |
| global-mdefault | 1 | 20 | 20.0 | 22.4 | 130.7 | 130.7 | 19.8 | 700 | 28.1 |
| global-mdefault | 2 | 20 | 20.0 | 20.8 | 97.8 | 97.8 | 18.7 | 648 | 27.6 |
| bigstack-mdefault | 1 | 20 | 20.0 | 22.0 | 29.5 | 29.5 | 19.3 | 456 | 29.5 |
| bigstack-mdefault | 2 | 20 | 20.0 | 21.0 | 26.4 | 26.4 | 18.7 | 430 | 26.4 |

Pause sequence of one run each (whole run, ms; the jump is the connection pool opening):

    bundled  m=4 r1: ... 12 20 12 16 18 15 134 89 89 110 93 93 92 90 96 115 101 102 96 93 91 91 89 90 89 93 14
    global   m=4 r1: ... 11 13 14 15 12 11 153 129 95 21 21 20 23 21 29 21 20 21 22 21 21 22 21 26 21 22 13
    bigstack m=4 r1: ... 14 15 14 12 21 28 21 21 23 23 21 20 29 20 24 21 22 22 22 24 26 22 24 25 13

`phases.py` output: `idle/phases.txt`; summarize.py lines: `idle/summary.txt` (in loop order
round → markers 1, 2, 4, default → bundled, global, bigstack).

## Full load (`run_broker_frozen.sh <broker> churn 240`)

20k queues flapping, 200 reconnects/s over a pool of 2,000 connections, ~20k msg/s through
lavinmqperf (pub/s 20000 in every run). Run order: bundled m=1, global m=4, global default,
bigstack m=4, then the same again.

| config | run | GCs | GCs/min | pause p50 | p99 | max | mark p50 | GC ms/min | max after 3rd |
|---|---|--:|--:|--:|--:|--:|--:|--:|--:|
| bundled-m1 | 1 | 14 | 3.5 | 63.9 | 129.5 | 129.5 | 56.2 | 290 | 122.7 |
| bundled-m1 | 2 | 13 | 3.2 | 69.9 | 150.1 | 150.1 | 60.3 | 273 | 111.7 |
| global-m4 | 1 | 12 | 3.0 | 33.3 | 127.6 | 127.6 | 25.0 | 163 | 33.9 |
| global-m4 | 2 | 14 | 3.5 | 31.2 | 117.9 | 117.9 | 23.8 | 167 | 37.3 |
| global-mdefault | 1 | 13 | 3.2 | 32.2 | 144.1 | 144.1 | 24.5 | 168 | 37.4 |
| global-mdefault | 2 | 19 | 4.7 | 30.2 | 111.2 | 111.2 | 23.6 | 199 | 41.2 |
| bigstack-m4 | 1 | 11 | 2.7 | 32.9 | 36.5 | 36.5 | 24.7 | 87 | 36.5 |
| bigstack-m4 | 2 | 13 | 3.2 | 30.2 | 34.9 | 34.9 | 23.6 | 96 | 34.9 |

Summary lines (`load/summary.txt`):

```
bundled m=1 r1 | bundled churn  gcs/min    3.5  pause p50   64.2 p99  129.5 max  129.5 ms  gc ms/min   290.5 | stats tick p50   4.4 max  135.6 ms | rss peak 313 end 265 MB | pub/s 20000 | alloc    3.2 MB/s
global m=4 r1 | global churn  gcs/min    3.0  pause p50   33.3 p99  127.6 max  127.6 ms  gc ms/min   163.5 | stats tick p50   4.4 max  118.3 ms | rss peak 338 end 287 MB | pub/s 20000 | alloc    3.3 MB/s
global m=default r1 | global churn  gcs/min    3.2  pause p50   32.2 p99  144.1 max  144.1 ms  gc ms/min   168.0 | stats tick p50   4.4 max    8.4 ms | rss peak 337 end 288 MB | pub/s 20000 | alloc    3.5 MB/s
bigstack m=4 r1 | bigstack churn  gcs/min    2.7  pause p50   32.9 p99   36.5 max   36.5 ms  gc ms/min    86.7 | stats tick p50   4.4 max    8.7 ms | rss peak 321 end 269 MB | pub/s 20000 | alloc    3.1 MB/s
bundled m=1 r2 | bundled churn  gcs/min    3.2  pause p50   69.9 p99  150.1 max  150.1 ms  gc ms/min   273.2 | stats tick p50   4.4 max    6.8 ms | rss peak 330 end 270 MB | pub/s 20000 | alloc    3.5 MB/s
global m=4 r2 | global churn  gcs/min    3.5  pause p50   31.8 p99  117.9 max  117.9 ms  gc ms/min   167.1 | stats tick p50   4.3 max    6.3 ms | rss peak 321 end 272 MB | pub/s 20000 | alloc    3.5 MB/s
global m=default r2 | global churn  gcs/min    4.7  pause p50   30.2 p99  111.2 max  111.2 ms  gc ms/min   198.9 | stats tick p50   4.4 max    7.0 ms | rss peak 319 end 268 MB | pub/s 20000 | alloc    2.8 MB/s
bigstack m=4 r2 | bigstack churn  gcs/min    3.2  pause p50   30.2 p99   34.9 max   34.9 ms  gc ms/min    95.9 | stats tick p50   4.4 max   10.0 ms | rss peak 319 end 253 MB | pub/s 20000 | alloc    3.1 MB/s
```

Phase split (`load/phases.txt`):

```
bundled m=1 r1               n= 14  total p50   63.9 ms  stop-world   0.1 ms  mark   56.2 ms  other   7.5 ms
global m=4 r1                n= 12  total p50   33.3 ms  stop-world   0.1 ms  mark   25.0 ms  other   8.2 ms
global m=default r1          n= 13  total p50   32.2 ms  stop-world   0.1 ms  mark   24.5 ms  other   7.6 ms
bigstack m=4 r1              n= 11  total p50   32.9 ms  stop-world   0.1 ms  mark   24.7 ms  other   8.1 ms
bundled m=1 r2               n= 13  total p50   69.9 ms  stop-world   0.1 ms  mark   60.3 ms  other   9.5 ms
global m=4 r2                n= 14  total p50   31.2 ms  stop-world   0.1 ms  mark   23.8 ms  other   7.3 ms
global m=default r2          n= 19  total p50   30.2 ms  stop-world   0.1 ms  mark   23.6 ms  other   6.4 ms
bigstack m=4 r2              n= 13  total p50   30.2 ms  stop-world   0.1 ms  mark   23.6 ms  other   6.6 ms
```

Bundled under load also has a few 100–150 ms collections spread through the run (not only at the
start), which global and bigstack do not have.

## Mark stack growth over 15 minutes (global, GC_MARKERS=4)

`run_gclog.sh`: `run_broker_frozen.sh` copied with `GC_PRINT_STATS=1 GC_LOG_FILE=...` added to the
broker's environment, `churn 900`. A sampler counted log lines every 10 s.

| seconds since start | "Mark stack overflow" | "Grew mark stack" | collections |
|--:|--:|--:|--:|
| 1 | 0 | 0 | 35 |
| 11 | 0 | 0 | 75 |
| 21 | 37 | 1 | 81 |
| 31 | 91 | 3 | 83 |
| 41 | 91 | 3 | 83 |
| 61 | 91 | 3 | 85 |
| 121 | 91 | 3 | 88 |
| 301 | 91 | 3 | 96 |
| 902 | 91 | 3 | 119 |
| 912 | 91 | 3 | 119 |

Per collection: #81 37 overflows, grew to 8,192; #82 34 overflows, grew to 16,384; #83 20
overflows, grew to 32,768; #84–#120: none. The first three collections in the measurement window
took 104, 104 and 109 ms, the rest 36 ms p50, 48 ms max (89 ms/min). Whole window: 39 collections,
pause p50 36.6 ms, max 108.9 ms, 108.8 ms/min. The p50 is a few ms above the 240 s runs, mostly in
the "other" phase (10.6 vs 6–8 ms); likely the GC_PRINT_STATS logging, not measured separately.

```
global churn  gcs/min    2.6  pause p50   36.6 p99  108.9 max  108.9 ms  gc ms/min   108.8 | stats tick p50   4.5 max   11.3 ms | rss peak 411 end 338 MB | pub/s 20000 | alloc    3.5 MB/s
global m=4 gclog             n= 39  total p50   36.6 ms  stop-world   0.1 ms  mark   25.9 ms  other  10.6 ms
```

## Marker threads

`curl -s -u guest:guest localhost:15672/metrics | grep gc_marker_threads` with GC_MARKERS unset
(`marker-threads.txt`):

```
bundled: lavinmq_gc_marker_threads 3
global: lavinmq_gc_marker_threads 3
bigstack: lavinmq_gc_marker_threads 3
```

`nproc`: 4 (`cpus.txt` has lscpu).

## Changes to the scripts

- `setup.sh`: `apt-get install liblz4-dev` failed on the fresh VM (`Unable to locate package`)
  because the package lists were empty; the script now runs `apt-get update` first. The failure
  was masked by `|| true`; I installed the packages by hand while setup ran, before the broker
  builds needed them. Everything else worked unchanged.
- The batch scripts here (`run_idle.sh`, `run_load.sh`, `run_gclog.sh`) wrap the existing ones and
  copy each run directory (minus `data/`) into this folder; `tables.py` builds the tables above.

## Exact commands

```
cd ~/lavinmq   # repo root, branch gc-bench-results-broker
SCRATCH=$HOME/gcbench BROKERS="bundled global bigstack" extras/gc-bench/setup.sh
source $HOME/gcbench/env.sh
export RES=$PWD/extras/gc-bench/results-broker
# marker threads (see marker-threads.txt for the loop): start each broker with GC_MARKERS unset, then
curl -s -u guest:guest localhost:15672/metrics | grep gc_marker_threads
# step 2, 24 runs: for r in 1 2; for m in 1 2 4 default; for b in bundled global bigstack:
#   cd $SCRATCH/bench && GC_MARKERS=$m PERF=0 FLAP=0 ./run_broker_forcegc.sh $b none 60
#   python3 -I phases.py $SCRATCH/runs/$b-none "$b m=$m r$r"      (default: env -u GC_MARKERS)
$RES/run_idle.sh
# step 3, 8 runs: for r in 1 2; for cfg in bundled:1 global:4 global:default bigstack:4:
#   GC_MARKERS=$m ./run_broker_frozen.sh $b churn 240; python3 -I phases.py $SCRATCH/runs/$b-churn ...
$RES/run_load.sh
# step 4
$RES/run_gclog.sh
python3 -I $RES/tables.py $RES
```

## Files

- `idle/<broker>-m<markers>-r<round>/`, `load/<broker>-m<markers>-r<round>/`, `gclog/run/`: raw run
  directories (gc.pauses, gc.pauses.*, driver.log, perf.log, samples.txt, broker.log, lavinmq.ini).
- `gclog/gc-stats.log`: the full GC_PRINT_STATS log; `gclog/counts.txt`: the 10 s samples.
- `*-run.log`: console output of the batch scripts.

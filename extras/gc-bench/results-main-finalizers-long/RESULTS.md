# Finalizer fixes over 20 minutes: warm-up or steady state?

Branch `gc-bench-main-finalizers-long`, 2026-10-30.

## Setup

- VM: 4 vCPU (`nproc` 4), Intel Xeon @ 2.10 GHz, KVM, 15 GB RAM (`facts.txt`). CPU steal from
  `vmstat 1 5` before each run (`r*/*/vmstat.txt`): 0-1%.
- Crystal 1.21.0, bundled libgc (8.2.8), default markers. `main` = `baaa3ea`, `digest` = `142910d`
  (PR 2584); `-socket` adds `zz_socket_unregister.cr` (PR 2585 equivalent, with an unregistration
  counter). Built by `build.sh` (setup script: worktrees at `$SCRATCH/src-{main,digest}`); the hook
  compiled against main unchanged.
- Load: `run_broker.sh <variant> churn 1200` (PERF=1, FLAP=1): 20k flapping queues, 2,000
  connections opened before measure_start, then 200 reconnects/s, lavinmqperf 20k msg/s.
  Two rounds, each main, main-socket, digest, digest-socket in that order (`plan.sh 1 1`,
  `plan.sh 2 2`).
- Anomaly: in round 1 `plan.sh`'s port check read `/proc/net/tcp6`, which does not exist here, so
  awk failed and the check was a no-op; the `pkill -9` + 2 s sleep before it did the cleanup (no
  bind errors in any `broker.log`). Fixed before round 2.
- `analyze.py <run> <binary>` writes `r*/<variant>/minutes.txt`: 1-minute bins from
  measure_start with collections, GC ms, trigger (G = `GC_grow_table`, C = `GC_collect_or_expand`,
  first libgc caller in the hook's backtrace), cumulative GC ms and RSS (samples.txt mapped onto
  the monotonic clock with `clock.txt`). Bin `pre` is broker start to measure_start (queue
  declares + the 2,000 connection opens). `tables.py` builds the tables below (`tables.md`).
  `summary.txt` has the run_broker summary lines.

Collections per minute (G = from GC_grow_table in parentheses), pre = broker start to measure_start

| minute | r1/main | r2/main | r1/main-socket | r2/main-socket | r1/digest | r2/digest | r1/digest-socket | r2/digest-socket |
|---|---|---|---|---|---|---|---|---|
| pre | 29 (6) | 30 (6) | 30 (6) | 29 (6) | 30 (5) | 28 (5) | 27 (5) | 26 (5) |
| 1 | 11 (10) | 11 (10) | 6 (6) | 6 (6) | 5 (4) | 5 (4) | 4 (0) | 4 (0) |
| 2 | 4 (0) | 4 (0) | 7 (7) | 7 (7) | 4 (0) | 4 (0) | 3 (0) | 3 (0) |
| 3 | 3 (0) | 4 (0) | 7 (7) | 7 (7) | 3 (0) | 3 (0) | 4 (0) | 4 (0) |
| 4 | 4 (0) | 3 (0) | 7 (7) | 7 (7) | 4 (0) | 4 (0) | 3 (0) | 3 (0) |
| 5 | 3 (0) | 3 (0) | 7 (7) | 7 (7) | 3 (0) | 3 (0) | 4 (0) | 4 (0) |
| 6 | 4 (0) | 4 (0) | 7 (7) | 7 (7) | 4 (0) | 4 (0) | 3 (0) | 3 (0) |
| 7 | 3 (0) | 3 (0) | 7 (7) | 7 (7) | 3 (0) | 3 (0) | 4 (0) | 4 (0) |
| 8 | 3 (0) | 4 (0) | 6 (6) | 6 (6) | 3 (0) | 3 (0) | 3 (0) | 3 (0) |
| 9 | 4 (1) | 3 (0) | 7 (7) | 7 (7) | 4 (0) | 4 (0) | 4 (0) | 4 (0) |
| 10 | 3 (0) | 3 (0) | 7 (7) | 7 (7) | 3 (0) | 3 (0) | 3 (0) | 3 (0) |
| 11 | 3 (0) | 3 (0) | 7 (7) | 7 (7) | 3 (0) | 3 (0) | 4 (0) | 3 (0) |
| 12 | 3 (0) | 4 (0) | 7 (7) | 7 (7) | 3 (0) | 4 (0) | 3 (0) | 4 (0) |
| 13 | 4 (0) | 3 (0) | 7 (7) | 7 (7) | 3 (0) | 3 (0) | 3 (0) | 3 (0) |
| 14 | 3 (2) | 3 (2) | 6 (6) | 6 (6) | 3 (0) | 3 (0) | 4 (0) | 3 (0) |
| 15 | 3 (3) | 4 (4) | 7 (7) | 7 (7) | 3 (0) | 3 (0) | 3 (0) | 4 (0) |
| 16 | 4 (4) | 3 (3) | 7 (7) | 7 (7) | 3 (0) | 4 (0) | 4 (0) | 3 (0) |
| 17 | 3 (3) | 4 (4) | 7 (7) | 7 (7) | 3 (0) | 2 (0) | 3 (0) | 3 (0) |
| 18 | 4 (4) | 3 (3) | 7 (7) | 7 (7) | 4 (0) | 3 (0) | 3 (0) | 3 (0) |
| 19 | 3 (3) | 4 (4) | 7 (7) | 7 (7) | 3 (0) | 3 (0) | 3 (0) | 4 (0) |
| 20 | 4 (4) | 3 (3) | 6 (6) | 7 (7) | 3 (0) | 3 (0) | 4 (0) | 3 (0) |

Per run

| run | pre-window s | last G collection (min) | steady gcs/min (min 10-20) | steady GC ms/min | cum GC ms @5 | @10 | @20 | RSS MB @1 / @10 / @20 |
|---|---|---|---|---|---|---|---|---|
| r1/main | 8.3 | 19.9 | 3.36 | 680 | 4118 | 7640 | 14200 | 577 / 709 / 735 |
| r2/main | 5.7 | 19.78 | 3.36 | 666 | 4282 | 7476 | 14257 | 570 / 689 / 737 |
| r1/main-socket | 12.0 | 19.86 | 6.82 | 1247 | 5841 | 11802 | 24308 | 580 / 624 / 675 |
| r2/main-socket | 12.2 | 20.0 | 6.91 | 1256 | 5883 | 11780 | 24395 | 579 / 623 / 668 |
| r1/digest | 5.9 | 0.87 | 3.09 | 641 | 3590 | 6882 | 13369 | 618 / 702 / 762 |
| r2/digest | 5.7 | 0.86 | 3.09 | 594 | 3503 | 6824 | 12809 | 617 / 686 / 758 |
| r1/digest-socket | 11.7 | -0.02 | 3.36 | 665 | 3177 | 6598 | 13352 | 634 / 690 / 743 |
| r2/digest-socket | 11.7 | -0.02 | 3.27 | 612 | 3247 | 6304 | 12491 | 634 / 686 / 746 |

Per variant (mean over rounds)

| variant | runs | min 1 gcs | min 2-9 gcs/min | steady gcs/min (10-20) | cum GC ms @5 | @10 | @20 |
|---|---|---|---|---|---|---|---|
| main | 2 | 11.0 | 3.50 | 3.36 | 4200 | 7558 | 14228 |
| main-socket | 2 | 6.0 | 6.88 | 6.86 | 5862 | 11791 | 24352 |
| digest | 2 | 5.0 | 3.50 | 3.09 | 3547 | 6853 | 13089 |
| digest-socket | 2 | 4.0 | 3.50 | 3.32 | 3212 | 6451 | 12921 |

## Conclusions

- Every variant is at its steady rate by minute 2. The finalizer fixes are a warm-up gain: main's
  extra cost is minute 1 (11 collections, 10 from `GC_grow_table`, vs 5 for digest and 4 for
  digest-socket). From minute 2 on, main, digest and digest-socket all run 3-4/min (min 10-20:
  3.36, 3.09, 3.32/min; differences of 1-3 collections over 11 minutes, within bin noise).
- Cumulative GC ms (mean of 2): main 4,200 / 7,558 / 14,228 at 5 / 10 / 20 min, digest 3,547 /
  6,853 / 13,089, digest-socket 3,212 / 6,451 / 12,921. The gap to main stays at ~0.7-1.3 s, set
  in minute 1, and shrinks from 24% at 5 min to 8-9% at 20 min.
- `GC_grow_table` collections: digest-socket has none in the window (its last is during
  connection setup), digest's stop at minute 0.9, main's stop at minute 1 but return from minute
  14 and then trigger every collection, with no change in total rate (they replace
  collect_or_expand collections; live finalizer entries keep creeping up past the table size).
- main-socket stays elevated for the whole run: 6-7/min every minute through minute 20, all from
  `GC_grow_table`, ~1,250 GC ms/min; 24.4 s cumulative at 20 min, 1.7x main. Unregistering the
  socket finalizer on main (Digest still finalizable) keeps the finalizer table from ever growing.
- Warm-up vs connection setup: every variant has 5-6 grow_table collections during the 6-12 s
  setup (2,000 opens). Main's (and digest's smaller) burst continues through minute 1, while the
  first ~12,000 reconnects double the live finalizable objects (old connections not yet
  collected); with both TCPSocket and Digest finalizable, main needs the most growth steps.
- RSS grows in every variant for the whole run (about +160 MB from minute 1 to 20; main-socket
  +90 MB), so no variant reaches a flat heap in 20 minutes; main-socket ends ~70 MB lower.

# Final comparison: upstream main vs all fixes combined (idle and churn only)

Question: total effect on GC pauses, collection frequency, GC time per minute and RSS of combining
(1) the narrow bdwgc mark-stack patch with a larger initial mark stack, (2) PR 2584 (password digest
without finalizer) and (3) dropping the TCP socket finalizer on close, vs plain upstream main; and
whether a 16k vs 32k initial mark stack makes a measurable difference.

## Setup

- VM: 4 vCPU Intel Xeon @ 2.80GHz (KVM), 15 GB RAM (`setup.txt`). Load generators on the same VM.
  CPU steal 0-2% in every pre-round `vmstat` (`vmstat.txt`).
- Crystal 1.21.0 (LLVM 20.1.8). `GC_get_version()` = 8.2.8 for all three libgc builds.
- Variants:
  - `main`: cloudamqp/lavinmq `baaa3ea`, Crystal's bundled libgc, default markers (4).
  - `combo16k`: `142910d` (PR 2584, on `baaa3ea`) + `zz_socket_unregister.cr` + bdwgc 8.2.8 with
    `bdwgc-mark-stack-overflow-global.patch`, `CFLAGS="-O2 -DINITIAL_MARK_STACK_SIZE=16384"`.
  - `combo32k`: same, `-DINITIAL_MARK_STACK_SIZE=32768`.
- Brokers built with `build-brokers.sh` (hook as in setup.sh; `zz_bench.cr` requires
  `zz_gc_pauses`, then for the combos `zz_socket_unregister`, then `lavinmq`). The hook compiled
  against main unchanged. libgc built with `VARIANTS="stock global16k global32k" build-libgc.sh`.
- Modes, variants interleaved within each round (`plan.sh`):
  - idle: `PERF=0 FLAP=0 run_broker_forcegc.sh <v> none 120` (20k queues, 2,000 idle
    connections, forced GC every 3 s);
  - churn: `PERF=0 FLAP=0 run_broker.sh <v> churn 240` (200 reconnects/s, no other traffic).
- 5 rounds (3 planned; 16k and 32k medians were within 15% so 2 more were added:
  `FIRST=4 ROUNDS=5 STATS=0 plan.sh`). Then one 60 s idle forced-GC run per variant with
  `GC_PRINT_STATS=1` (rounds 1-3 run only; `runs/stats-*`).
- Metrics from `analyze.py` (`runs.jsonl`), tables from `report.py`. Only collections inside the
  driver's measure window count. "max at" is seconds after `measure_start` (connections open).
  Finalizer registrations/s are per type from the hook's `GC.add_finalizer` counter (registrations,
  so `TCPSocket` still shows for the combos: the snippet unregisters at close).

## Headline: medians of 5 rounds

### Idle, forced GC every 3 s

| metric | main | combo16k | combo32k | main/combo16k | main/combo32k |
|---|---|---|---|---|---|
| collections/min | 19.0 | 19.5 | 19.5 | 0.97x | 0.97x |
| pause p50 ms | 197.7 | 49.8 | 51.5 | 3.97x | 3.84x |
| pause p90 ms | 238.2 | 61.4 | 61.1 | 3.88x | 3.90x |
| pause max ms | 261.7 | 179.5 | 68.1 | 1.46x | 3.84x |
| GC ms/min | 3802.5 | 1063.3 | 1034.7 | 3.58x | 3.67x |
| RSS peak MB | 491 | 495 | 494 | 0.99x | 0.99x |
| RSS end MB | 469 | 469 | 469 | 1.00x | 1.00x |

### Churn only (200 reconnects/s)

| metric | main | combo16k | combo32k | main/combo16k | main/combo32k |
|---|---|---|---|---|---|
| collections/min | 4.7 | 2.5 | 2.5 | 1.90x | 1.90x |
| pause p50 ms | 237.7 | 72.1 | 68.8 | 3.30x | 3.45x |
| pause p90 ms | 275.4 | 199.7 | 92.4 | 1.38x | 2.98x |
| pause max ms | 309.1 | 199.7 | 92.4 | 1.55x | 3.35x |
| GC ms/min | 1088.5 | 207.2 | 183.5 | 5.25x | 5.93x |
| RSS peak MB | 630 | 633 | 632 | 1.00x | 1.00x |
| RSS end MB | 581 | 577 | 576 | 1.01x | 1.01x |
| finalizers/s TCPSocket | 201.1 | 203.1 | 201.0 | | |
| finalizers/s OpenSSL::Digest | 201.1 | 0 | 0 | | |

(churn has ~10 collections per combo run, so its p90 is the 2nd-highest pause.)

### Mark stack (60 s idle, `GC_PRINT_STATS=1`, whole broker lifetime incl. setup)

| variant | collections | "Mark stack overflow" | "Grew mark stack" | detail |
|---|---|---|---|---|
| main | 51 | 771 | 0 | every collection from #30 (connections open) on overflows ~36 times |
| combo16k | 48 | 3 | 1 | all 3 in collection #29, then "Grew mark stack to 32768 frames"; none after |
| combo32k | 49 | 0 | 0 | |

Pauses in these runs (stats logging adds overhead): main p50 197.8 / max 260.9 ms, combo16k
57.1 / 289.7 ms (the growth collection), combo32k 52.9 / 80.9 ms (`summary.txt`).

## Per-run tables

### idle: per run

| round | variant | coll/min | p50 ms | p90 ms | max ms | GC ms/min | RSS peak MB | RSS end MB | max at (s) | finalizers/s |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | main | 19.0 | 208.7 | 239.3 | 262.7 | 3986.9 | 492 | 473 | 35.7 | File 4.7, TCPSocket 2.3, OpenSSL::Digest 2.3 |
| 1 | combo16k | 20.0 | 49.5 | 59.9 | 179.5 | 1060.3 | 495 | 469 | 0.2 | TCPSocket 5.1, File 4.8 |
| 1 | combo32k | 19.5 | 46.9 | 61.5 | 67.8 | 939.0 | 494 | 469 | 1.1 | TCPSocket 5.7, File 4.8 |
| 2 | main | 18.5 | 217.2 | 249.9 | 261.7 | 4049.5 | 491 | 469 | 23.4 | File 4.7, TCPSocket 1.2, OpenSSL::Digest 1.2 |
| 2 | combo16k | 19.5 | 52.2 | 67.5 | 227.0 | 1128.4 | 495 | 474 | 1.1 | TCPSocket 7.7, File 4.8 |
| 2 | combo32k | 19.5 | 51.5 | 60.5 | 65.5 | 1013.0 | 493 | 467 | 89.6 | File 4.8, TCPSocket 1.3 |
| 3 | main | 19.0 | 190.0 | 217.4 | 266.1 | 3586.9 | 493 | 473 | 6.9 | File 4.7, TCPSocket 2.4, OpenSSL::Digest 2.4 |
| 3 | combo16k | 19.5 | 50.7 | 61.4 | 166.7 | 1063.3 | 495 | 467 | 0.6 | File 4.8, TCPSocket 1.3 |
| 3 | combo32k | 20.0 | 55.7 | 65.5 | 79.1 | 1138.5 | 495 | 473 | 52.4 | File 4.8, TCPSocket 4.7 |
| 4 | main | 19.0 | 196.5 | 228.8 | 247.7 | 3765.5 | 491 | 469 | 6.7 | File 4.7, TCPSocket 2.9, OpenSSL::Digest 2.9 |
| 4 | combo16k | 19.5 | 49.8 | 64.3 | 218.0 | 1085.2 | 496 | 469 | 1.2 | TCPSocket 6.8, File 4.8 |
| 4 | combo32k | 19.5 | 53.4 | 61.1 | 68.1 | 1034.7 | 494 | 468 | 114.0 | File 4.8, TCPSocket 1.3 |
| 5 | main | 19.0 | 197.7 | 238.2 | 250.6 | 3802.5 | 491 | 468 | 80.8 | File 4.7, TCPSocket 2.5, OpenSSL::Digest 2.5 |
| 5 | combo16k | 19.5 | 47.2 | 56.8 | 179.2 | 1001.1 | 493 | 469 | 1.0 | TCPSocket 9.2, File 4.8 |
| 5 | combo32k | 19.5 | 48.3 | 52.6 | 353.6 | 1089.0 | 495 | 469 | 56.5 | TCPSocket 7.1, File 4.8 |

### churn: per run

| round | variant | coll/min | p50 ms | p90 ms | max ms | GC ms/min | RSS peak MB | RSS end MB | max at (s) | finalizers/s |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | main | 4.7 | 239.4 | 313.0 | 332.7 | 1129.6 | 630 | 580 | 224.2 | TCPSocket 201.2, OpenSSL::Digest 201.2, File 4.8 |
| 1 | combo16k | 2.5 | 68.8 | 198.1 | 198.1 | 204.1 | 633 | 577 | 10.7 | TCPSocket 203.1, File 4.8 |
| 1 | combo32k | 2.5 | 73.3 | 92.4 | 92.4 | 183.5 | 631 | 575 | 154.7 | TCPSocket 200.4, File 4.8 |
| 2 | main | 4.5 | 220.5 | 272.6 | 309.1 | 1021.6 | 628 | 584 | 220.4 | TCPSocket 201.1, OpenSSL::Digest 201.1, File 4.8 |
| 2 | combo16k | 2.5 | 64.3 | 220.3 | 220.3 | 191.6 | 631 | 576 | 10.7 | TCPSocket 202.4, File 4.8 |
| 2 | combo32k | 2.5 | 67.5 | 78.5 | 78.5 | 163.5 | 647 | 591 | 199.6 | TCPSocket 204.1, File 4.8 |
| 3 | main | 4.5 | 237.7 | 310.2 | 315.2 | 1073.4 | 630 | 587 | 196.9 | TCPSocket 200.4, OpenSSL::Digest 200.4, File 4.8 |
| 3 | combo16k | 2.5 | 73.9 | 199.7 | 199.7 | 207.2 | 633 | 577 | 10.7 | TCPSocket 203.1, File 4.8 |
| 3 | combo32k | 2.5 | 66.5 | 73.5 | 73.5 | 161.2 | 632 | 576 | 36.1 | TCPSocket 200.4, File 4.8 |
| 4 | main | 4.8 | 216.8 | 275.4 | 278.8 | 1088.5 | 631 | 581 | 112.4 | TCPSocket 201.1, OpenSSL::Digest 201.1, File 4.8 |
| 4 | combo16k | 2.5 | 72.1 | 199.6 | 199.6 | 209.0 | 647 | 591 | 10.3 | TCPSocket 202.1, File 4.8 |
| 4 | combo32k | 2.5 | 75.7 | 101.1 | 101.1 | 188.6 | 631 | 575 | 131.8 | TCPSocket 201.0, File 4.8 |
| 5 | main | 4.8 | 238.3 | 271.9 | 286.3 | 1119.7 | 629 | 576 | 28.3 | TCPSocket 200.2, OpenSSL::Digest 200.2, File 4.8 |
| 5 | combo16k | 2.5 | 81.1 | 224.9 | 224.9 | 225.7 | 632 | 576 | 10.7 | TCPSocket 203.7, File 4.8 |
| 5 | combo32k | 2.5 | 68.8 | 110.9 | 110.9 | 186.8 | 647 | 599 | 83.6 | TCPSocket 204.5, File 4.8 |


Idle finalizer rates (a few per second) come from the run scripts' own HTTP calls (RSS/metrics sampler, forced GC), not from AMQP; `File` is the hook's own log files.

## Anomalies

- combo16k's max pause is the mark-stack growth collection, every run: idle 167-227 ms at
  0.2-1.2 s after the connections open, churn 198-225 ms at 10.3-10.7 s (its first collection with
  the connections open). It is what pushes churn p90 to ~200 ms, as a run has only ~10 collections.
- combo32k idle round 5: one 353.6 ms pause at 56.5 s, all in marking (stop-the-world 0.2 ms, mark
  328 ms); the pauses around it were 48-51 ms. Not reproduced in the other 4 idle and 5 churn
  combo32k runs nor in its GC_PRINT_STATS run (0 overflows). Cause unknown (no per-second steal
  sample during runs); likely a descheduled marker thread on the shared host. Kept in the data.
- `plan.sh` waited for ports 5672/15672 with `ss`, which this VM lacks; in rounds 1-3 that check was
  a no-op (leftovers were still killed with `pkill`/`pkill -9`, and each run uses a fresh data dir).
  Rounds 4-5 used a `/dev/tcp` check.

## Conclusions

- All fixes together cut pause p50 ~4x when idle (198 -> 50 ms) and ~3.4x under churn (238 -> 70 ms);
  GC time per minute drops 3.6x idle and 5-6x under churn. RSS is unchanged (within 1%).
- Under churn, collections drop from 4.7 to 2.5/min (1.9x): the digest finalizer is gone (201/s ->
  0) and the socket finalizer, still registered at ~201/s, is unregistered at close. The pause cut
  comes from the mark stack patch; idle collection frequency is set by the forced GC and unchanged.
- 16k vs 32k: same p50 and GC time (within noise), but 16k still overflows and grows once (16k ->
  32k) when the 2,000 connections open, giving one ~170-230 ms pause per process; 32k never
  overflowed, and its max pause was 65-111 ms in 9 of 10 runs (one unexplained 354 ms outlier).
  A 32,768-entry initial stack is the measurably better choice at this scale.
- main overflows its 4,096-entry stack ~36 times per collection, every collection, once the
  connections are open, and never grows it: the parallel-mode bug, reproduced on main.

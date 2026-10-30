# Final comparison under full load: upstream main vs all GC fixes combined

Question: total effect of (1) the narrow bdwgc mark-stack patch with a larger initial mark stack,
(2) PR 2584 (password digest without finalizer) and (3) dropping the `TCPSocket` finalizer on close,
against plain upstream main. And does a 16k vs 32k initial mark stack matter?

## Setup

- VM: 4 vCPU Intel Xeon @ 2.80GHz (KVM), 16 GB, load generators on the same machine
  (`system.txt`). CPU steal 0-1% before every round (`vmstat.txt`).
- Crystal 1.21.0, LLVM 20.1.8. `GC_get_version()` 8.2.8 for all three libgc builds.
- Variants (default markers, i.e. 4):
  - `main`: upstream main `baaa3ea`, Crystal's bundled libgc.
  - `combo16k`: PR 2584 `142910d` (on `baaa3ea`) + `zz_socket_unregister.cr` + bdwgc 8.2.8 with
    `bdwgc-mark-stack-overflow-global.patch`, `CFLAGS="-O2 -DINITIAL_MARK_STACK_SIZE=16384"`.
  - `combo32k`: same, `-DINITIAL_MARK_STACK_SIZE=32768`.
- Brokers built by `setup-final.sh` the same way as `setup.sh` (hook `gc_pauses.cr`/`typetable.cr`
  as `src/zz_*.cr`, `crystal build --release src/zz_bench.cr`). The hook compiled against main
  unchanged. `build-libgc.sh` gained `global16k`/`global32k` variants and a `VARIANTS` selector.
- Load per run: `run_broker.sh <variant> churn 240` with PERF=1, FLAP=1: 20k flapping queues,
  2,000 connections, 200 reconnects/s, lavinmqperf ~20k msg/s. Metrics over the 240 s measure window.
- 5 rounds, interleaved main, combo16k, combo32k (`plan.sh`). Logs per run in `runs/<variant>-r<n>/`;
  summary lines in `summaries.txt`; tables from `tables.py` (uses `analyze.py`).

## Headline: medians over 5 runs

| metric (median, range) | main (n=5) | combo16k (n=5) | combo32k (n=5) | main/combo16k | main/combo32k |
|---|---|---|---|---|---|
| GCs/min | 5.25 (5.24-5.5) | 3.5 (3.5-3.75) | 3.5 (3.5-3.75) | 1.50x | 1.50x |
| pause p50 ms | 240.7 (229.5-244.2) | 74.2 (69.4-78.1) | 72.5 (69.9-81.2) | 3.24x | 3.32x |
| pause p90 ms | 274.5 (270.2-292.8) | 89.6 (84.9-93.4) | 79.8 (74.4-86.9) | 3.06x | 3.44x |
| pause max ms | 311.1 (285.4-359.5) | 225.4 (203.8-241) | 85.1 (75.6-90.5) | 1.38x | 3.66x |
| GC ms/min | 1270.9 (1267-1296.8) | 304.5 (283.1-323.8) | 266.1 (244.5-272.3) | 4.17x | 4.78x |
| RSS peak MB | 663 (662-664) | 655 (655-671) | 655 (654-669) | 1.01x | 1.01x |
| RSS end MB | 595 (594-602) | 587 (579-595) | 594 (579-602) | 1.01x | 1.00x |

## Per run

"max at s" is the time of the largest pause from measure start. "warm-up GCs" are the collections
before the measure window (queue declaration and opening 2,000 connections), with their max.

| run | GCs/min | p50 ms | p90 ms | max ms | max at s | GC ms/min | RSS peak/end MB | finalizer registrations/s | warm-up GCs (max ms) |
|---|---|---|---|---|---|---|---|---|---|
| main-r1 | 5.5 | 229.5 | 276.3 | 289.5 | 197.0 | 1290.2 | 664/595 | TCPSocket 201.5, OpenSSL::Digest 201.5, File 5.5 | 30 (240.4) |
| combo16k-r1 | 3.75 | 74.2 | 91.1 | 228.3 | 6.9 | 323.8 | 664/594 | TCPSocket 200.4, File 5.5 | 29 (50.1) |
| combo32k-r1 | 3.75 | 69.9 | 76.2 | 89.7 | 189.5 | 258.6 | 669/602 | TCPSocket 200.8, File 5.5 | 31 (42.1) |
| main-r2 | 5.24 | 240.7 | 270.4 | 316.9 | 77.5 | 1270.9 | 663/594 | TCPSocket 200.6, OpenSSL::Digest 200.6, File 5.4 | 29 (188.6) |
| combo16k-r2 | 3.5 | 70.9 | 89.6 | 204.1 | 7.8 | 286.7 | 671/595 | TCPSocket 200.9, File 5.5 | 29 (42.1) |
| combo32k-r2 | 3.5 | 78.2 | 86.9 | 90.5 | 192.8 | 270.4 | 655/600 | TCPSocket 201, File 5.5 | 31 (62.0) |
| main-r3 | 5.24 | 233.0 | 274.5 | 359.5 | 60.6 | 1269.3 | 663/602 | TCPSocket 202.1, OpenSSL::Digest 202.1, File 5.4 | 34 (217.1) |
| combo16k-r3 | 3.5 | 69.4 | 88.4 | 203.8 | 7.3 | 283.1 | 655/587 | TCPSocket 200.6, File 5.5 | 30 (45.8) |
| combo32k-r3 | 3.75 | 71.8 | 79.8 | 80.4 | 55.6 | 266.1 | 663/594 | TCPSocket 203.2, File 5.5 | 30 (47.4) |
| main-r4 | 5.25 | 244.2 | 292.8 | 311.1 | 77.4 | 1296.8 | 662/601 | TCPSocket 202.1, OpenSSL::Digest 202.1, File 5.4 | 31 (204.9) |
| combo16k-r4 | 3.5 | 76.5 | 84.9 | 241.0 | 7.8 | 304.5 | 655/579 | TCPSocket 203.4, File 5.5 | 32 (52.5) |
| combo32k-r4 | 3.5 | 81.2 | 83.6 | 85.1 | 75.7 | 272.3 | 654/594 | TCPSocket 200.4, File 5.4 | 30 (42.3) |
| main-r5 | 5.25 | 243.0 | 270.2 | 285.4 | 110.1 | 1267.0 | 663/594 | TCPSocket 201.3, OpenSSL::Digest 201.3, File 5.4 | 30 (220.0) |
| combo16k-r5 | 3.75 | 78.1 | 93.4 | 225.4 | 7.3 | 321.2 | 655/579 | TCPSocket 204.4, File 5.5 | 28 (62.8) |
| combo32k-r5 | 3.5 | 72.5 | 74.4 | 75.6 | 75.6 | 244.5 | 655/579 | TCPSocket 200.6, File 5.5 | 31 (39.7) |

## Conclusions

- Combined, the fixes cut GC time per minute 4.2x (16k) to 4.8x (32k): from ~1,270 ms/min on main
  to ~305 / ~266 ms/min. Pause p50 drops ~3.3x (241 -> 72-74 ms), collections/min 1.5x (5.25 -> 3.5).
- RSS is unchanged (peak ~655-663 MB, end ~580-600 MB on all variants).
- 16k vs 32k: same p50 and frequency, but combo16k has one 204-241 ms collection ~7 s into every run
  (5/5); combo32k's max is 76-91 ms and lands at random times. Consistent with the 16k stack
  overflowing once under load and recovering by a heap rescan while doubling to 32k; 32k never
  overflows here. That one collection is also most of the 16k/32k gap in GC ms/min. Use 32768.
- Finalizer registrations: main registers `TCPSocket` and `OpenSSL::Digest` at ~201/s each; the
  combos only `TCPSocket` (~201/s). The socket snippet unregisters on close, so it does not lower
  the registration count that drives Boehm's collect-vs-grow decision; this experiment does not
  separate its effect from the digest fix.
- Anomaly: main r2 had one stats-collection tick of 267 ms (others <=71 ms), coinciding with nothing
  unusual in vmstat; left in.

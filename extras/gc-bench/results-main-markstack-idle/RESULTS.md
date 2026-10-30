# Mark stack fix on upstream main, idle with forced GC

Question: on upstream main, how do GC pauses compare between Crystal's bundled libgc and bdwgc
8.2.8 with the narrow mark stack patch? Does a 32,768-entry initial mark stack remove the
growth spikes the patched build shows right after the connections open?

## Setup

- VM: 4 vCPU Intel Xeon @ 2.80GHz (KVM), Crystal 1.21.0 (LLVM 20.1.8); see `setup.txt`.
- Brokers: upstream main `baaa3ea` (no digest fix), built as `setup.sh` does with the
  `zz_gc_pauses.cr`/`zz_typetable.cr`/`zz_bench.cr` hook, `--release`. The hook compiled
  against main unchanged.
- `GC_get_version()` is 8.2.8 for every broker.
- Variants:
  - `bundled`: Crystal's bundled libgc, default markers (4).
  - `bundled-m1`: the same binary with `GC_MARKERS=1`.
  - `global`: 8.2.8 + `bdwgc-mark-stack-overflow-global.patch`.
  - `global32k`: the same patch, `CFLAGS="-O2 -DINITIAL_MARK_STACK_SIZE=32768"`; added to
    `build-libgc.sh` (`VARIANTS=` picks a subset).
- Load: `PERF=0 FLAP=0 run_broker_forcegc.sh <v> none 120`. That is 20k queues and 2,000 idle
  connections, a forced GC every 3 s over the window, and no publishing.
- Order: 5 rounds with the variants interleaved in each round (`plan.sh`). Rounds 4 and 5
  were added because `global` and `global32k` were within 15%.
- CPU steal before each round (`vmstat`, column `st`): 0-2%.

## Columns

| Column | Meaning |
|---|---|
| gc/min | Collections per minute in the measure window |
| p50, p90, max | Pause percentiles in ms, measure window only |
| max @ s | Second of the window's max pause, counted from `measure_start` |
| GC ms/min | Total pause time per minute in the window |
| RSS | Peak / end, MB |
| whole-run max @ s | Largest pause in the whole run, including queue and connection setup. A negative second is before `measure_start`. |
| spikes | Pauses in the whole run longer than 2x the window p50 |
| GCs | Total collections in the run |
| finalizers/s | Finalizer registrations per second in the window, by type |

## Per run

All runs were made with `analyze.py`; the summary lines are in `summaries.txt` and the raw files in `runs/`.

| run | gc/min | p50 | p90 | max | max @ s | GC ms/min | RSS | whole-run max @ s | spikes | GCs | finalizers/s |
|---|---|---|---|---|---|---|---|---|---|---|---|
| r1-bundled | 19.0 | 195.7 | 215.5 | 285.5 | 62 | 3736 | 494 / 475 | 285.5 @ 62 | 0 | 68 | File 4.71, TCPSocket 1.25, OpenSSL::Digest 1.25 |
| r1-bundled-m1 | 19.5 | 106.1 | 130.3 | 138.3 | 44 | 2109 | 495 / 476 | 233.7 @ -0 | 1 | 71 | File 4.82, TCPSocket 1.29, OpenSSL::Digest 1.29 |
| r1-global | 19.5 | 51.7 | 58.6 | 68.3 | 31 | 1016 | 497 / 471 | 173.9 @ -0 | 3 | 75 | File 4.81, TCPSocket 1.30, OpenSSL::Digest 1.30 |
| r1-global32k | 19.5 | 57.0 | 67.1 | 75.0 | 108 | 1119 | 498 / 472 | 75.0 @ 108 | 0 | 73 | File 4.81, TCPSocket 1.30, OpenSSL::Digest 1.30 |
| r2-bundled | 19.0 | 200.3 | 238.4 | 298.5 | 10 | 3902 | 492 / 468 | 298.5 @ 10 | 0 | 67 | File 4.68, TCPSocket 2.21, OpenSSL::Digest 2.21 |
| r2-bundled-m1 | 19.5 | 110.5 | 132.4 | 148.5 | 73 | 2215 | 495 / 472 | 206.1 @ -0 | 0 | 71 | File 4.80, TCPSocket 1.29, OpenSSL::Digest 1.29 |
| r2-global | 19.5 | 53.7 | 69.4 | 379.7 | 1 | 1230 | 494 / 471 | 379.7 @ 1 | 3 | 72 | File 4.79, TCPSocket 1.30, OpenSSL::Digest 1.30 |
| r2-global32k | 20.0 | 52.5 | 60.0 | 68.3 | 43 | 1049 | 497 / 471 | 68.3 @ 43 | 0 | 71 | File 4.81, OpenSSL::Digest 1.92, TCPSocket 1.91 |
| r3-bundled | 19.0 | 208.6 | 242.0 | 247.1 | 29 | 3979 | 491 / 471 | 247.1 @ 29 | 0 | 67 | File 4.69, OpenSSL::Digest 2.77, TCPSocket 2.76 |
| r3-bundled-m1 | 19.5 | 110.9 | 157.8 | 233.0 | 1 | 2311 | 494 / 472 | 233.0 @ 1 | 1 | 68 | OpenSSL::Digest 5.15, TCPSocket 5.14, File 4.81 |
| r3-global | 19.5 | 57.0 | 65.9 | 210.6 | 0 | 1200 | 497 / 470 | 259.0 @ -0 | 3 | 71 | File 4.81, TCPSocket 2.72, OpenSSL::Digest 2.72 |
| r3-global32k | 19.5 | 55.9 | 66.6 | 75.7 | 38 | 1111 | 496 / 468 | 75.7 @ 38 | 0 | 69 | File 4.79, TCPSocket 1.30, OpenSSL::Digest 1.30 |
| r4-bundled | 18.5 | 212.1 | 263.2 | 266.5 | 7 | 4066 | 493 / 468 | 303.0 @ -0 | 0 | 67 | File 4.66, TCPSocket 2.60, OpenSSL::Digest 2.60 |
| r4-bundled-m1 | 19.0 | 128.2 | 159.2 | 299.1 | 1 | 2504 | 494 / 470 | 299.1 @ 1 | 1 | 66 | File 4.76, TCPSocket 1.27, OpenSSL::Digest 1.27 |
| r4-global | 19.5 | 58.9 | 74.0 | 220.2 | 0 | 1225 | 497 / 469 | 220.2 @ 0 | 3 | 70 | File 4.81, TCPSocket 3.10, OpenSSL::Digest 3.10 |
| r4-global32k | 19.5 | 55.9 | 65.9 | 73.1 | 50 | 1110 | 498 / 472 | 73.1 @ 50 | 0 | 70 | TCPSocket 7.41, OpenSSL::Digest 7.41, File 4.81 |
| r5-bundled | 18.5 | 243.6 | 294.8 | 332.9 | 118 | 4567 | 494 / 468 | 332.9 @ 118 | 0 | 69 | File 4.62, TCPSocket 1.22, OpenSSL::Digest 1.22 |
| r5-bundled-m1 | 19.0 | 118.2 | 151.5 | 219.5 | 1 | 2354 | 495 / 472 | 239.4 @ -0 | 1 | 68 | File 4.79, TCPSocket 4.60, OpenSSL::Digest 4.60 |
| r5-global | 20.0 | 55.5 | 63.1 | 192.3 | 0 | 1182 | 497 / 471 | 216.4 @ -0 | 3 | 73 | File 4.79, TCPSocket 2.83, OpenSSL::Digest 2.83 |
| r5-global32k | 19.5 | 55.9 | 63.9 | 67.3 | 50 | 1088 | 497 / 471 | 67.3 @ 50 | 0 | 73 | File 4.80, TCPSocket 1.29, OpenSSL::Digest 1.29 |

## Per-variant median (5 runs)

| variant | runs | gc/min | p50 | p90 | max | GC ms/min | RSS peak | whole-run max | spikes (sum) |
|---|---|---|---|---|---|---|---|---|---|
| bundled | 5 | 19.0 | 208.6 | 242.0 | 285.5 | 3979 | 493 | 298.5 | 0 |
| bundled-m1 | 5 | 19.5 | 110.9 | 151.5 | 219.5 | 2311 | 495 | 233.7 | 4 |
| global | 5 | 19.5 | 55.5 | 65.9 | 210.6 | 1200 | 497 | 220.2 | 15 |
| global32k | 5 | 19.5 | 55.9 | 65.9 | 73.1 | 1110 | 497 | 73.1 | 0 |

## Mark stack overflow diagnostic

`diag.sh` ran one 60 s run per variant with `GC_PRINT_STATS=1`. These runs were not timed.
Their rows are in `table-diag.md`, the summaries in `diag-summaries.txt` and the logs in
`runs/diag-*`.

| variant | "Mark stack overflow" lines | "current size" reported | collections with overflows |
|---|---|---|---|
| bundled | 776 | 4096 (all 776) | every collection from #29 (connections open) to the end; 36 per collection |
| bundled-m1 | 57 | 4096 x26, 8192 x23, 16384 x8 | #30, #31, #32 only |
| global | 63 | 4096 x27, 8192 x25, 16384 x11 | #31, #32, #33 only |
| global32k | 0 | - | none |

- The `global` spikes are its three growth collections (4,096 -> 8,192 -> 16,384 -> 32,768).
  They come at -1 s to +1 s around `measure_start`, as the last connections open and the first
  forced GC runs:
  - r1: 170-174 ms, all before the window.
  - r2: 380 ms at +1 s.
  - r3: 259 ms at -0 s and 211 ms at 0 s.
  - r4: 220 ms at 0 s.
  - r5: 216 ms at -0 s and 192 ms at 0 s.

  So in 4 of 5 runs the window max is a growth collection.
- `global32k` has no overflows and no spikes. Its whole-run max is the same as its window
  max (67-76 ms), at a random second.
- `bundled-m1` grows the same way (one spike of 200-300 ms per run).
- `bundled` never grows and overflows on every collection.

## Conclusions

- On main the narrow patch cuts the idle forced-GC pause p50 from 209 ms (bundled, 4 markers) to 55 ms, about 3.8x. GC time per minute drops from 3,979 to 1,110-1,200 ms. `GC_MARKERS=1` only halves it (111 ms).
- `-DINITIAL_MARK_STACK_SIZE=32768` removes the growth spikes. There are 0 overflows and 0 spikes versus 3 spikes per run (192-380 ms) with `global`. The max pause falls from 211 to 73 ms (median).
- Steady state is the same for `global` and `global32k` (p50 55.5 vs 55.9 ms, p90 65.9 both). The bigger initial stack costs nothing measurable here, RSS included.
- Pauses on main are about 2.5x longer than on the gc-heap-stats base in the handover (bundled 92-107 -> ~209 ms, patched 21-24 -> ~55 ms). This is the bigger scanned heap, so the fix matters more on main.
- Recommendation stands: ship the narrow patch together with the 32,768-entry initial stack.

## Anomalies

- `bundled` r5 p50 was 244 ms against 196-212 ms in r1-r4. Steal before the round was 0-2%, so the cause is not known. The run is kept.
- `bundled-m1` r3 and r4 window maxes (233 and 299 ms) are its growth collection landing at +1 s. They are not steady-state pauses.
- TCPSocket and OpenSSL::Digest registrations vary from 1.2 to 7.4/s between runs. The idle
  baseline is ~1.3/s: the sampler's 1/s and the 1/3 s forced-GC HTTP requests, each with basic
  auth. Higher values come from finalizer snapshots near `measure_start`, which take in the tail
  of the connection setup. File is about 4.8/s (`/proc` reads by the hook and the sampler).
- Every pause except the growth collections stays well under 100 ms on the patched builds, so collection frequency (~19.5/min) is set by the forced GC, not by allocation (0.3 MB/s).

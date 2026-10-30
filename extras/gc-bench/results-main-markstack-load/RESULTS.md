# Mark stack fix on upstream main, full load

Question: on upstream main under full load (20k flapping queues, 200 reconnects/s churn, ~20k msg/s
lavinmqperf), how do GC pauses, collection frequency and GC time compare between Crystal's bundled
libgc and bdwgc 8.2.8 with the narrow mark-stack patch, with and without a 32,768-entry initial
mark stack?

## Setup

- VM: 4 vCPU Intel Xeon @ 2.80 GHz (KVM), 16 GB RAM; `setup-facts.txt` has `lscpu`. CPU steal
  from `vmstat 1 5` before each round: 0-3% (in `summary-*.txt`).
- Crystal 1.21.0 (LLVM 20.1.8). All brokers report `GC_get_version()` 8.2.8.
- Brokers: upstream main `baaa3ea` (no digest fix), built by `setup-main.sh` exactly as `setup.sh`
  does (`zz_gc_pauses.cr`, `zz_typetable.cr`, `zz_bench.cr`, `--release`,
  `CRYSTAL_LIBRARY_PATH=<variant lib>:<crystal lib>`). The hook compiled against main unchanged.
- Variants:
  - `bundled`: Crystal 1.21's bundled libgc, default markers (4).
  - `bundled-m1`: same binary, `GC_MARKERS=1`.
  - `global`: 8.2.8 + `bdwgc-mark-stack-overflow-global.patch`.
  - `global32k`: same patch, `CFLAGS="-O2 -DINITIAL_MARK_STACK_SIZE=32768"` (new variant in
    `build-libgc.sh`).
- Per run: `run_broker.sh <variant> churn 240` (PERF=1, FLAP=1). 5 rounds, variants interleaved
  in each round (`plan.sh`). Measurement window = the driver's 240 s after its 2,000 connections
  are open; times "@ s" are seconds from the window start (negative = during connect).
- Files: `r<round>-<variant>/` hold `gc.pauses` (end ns, duration ns, stop-the-world ns, mark ns),
  `.allocs`, `.finalizers`, `driver.log`, `perf.log`, `samples.txt`, `broker.log`;
  `summary-*.txt` are the raw summary lines; `analyze.py` builds the tables below.
- Round 1 ran with a port check that used `ss`, which is not installed (the check was a no-op);
  fixed to `/dev/tcp` from round 2. `run_broker.sh` kills and waits for its broker, so no
  leftovers were seen.

## Per run

All runs held 20,000 msg/s publish rate and ~6.0 MB/s allocation.

| run | variant | GCs/min | p50 | p90 | max (window) | max after 10 s | max (incl. connect) at s | top 3 pauses ms @ s | GC ms/min | RSS peak MB | pub/s | finalizers/s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | bundled | 5.2 | 214.5 | 228.6 | 246.2 | 246.2 | 246.2 @ 94 | 246 @ 94, 230 @ 159, 229 @ 174 | 1111 | 662 | 20000 | Digest 202, TCPSocket 202, File 5 |
| 1 | bundled-m1 | 5.5 | 130.3 | 151.7 | 229.1 | 177.1 | 229.1 @ 4 | 229 @ 4, 190 @ -0, 179 @ -1 | 742 | 664 | 20000 | TCPSocket 201, Digest 201, File 5 |
| 1 | global | 5.2 | 72.1 | 80.2 | 257.6 | 84.0 | 257.6 @ 4 | 258 @ 4, 205 @ -1, 190 @ -0 | 414 | 672 | 20000 | Digest 202, TCPSocket 202, File 5 |
| 1 | global32k | 5.5 | 69.8 | 86.7 | 88.7 | 88.7 | 88.7 @ 197 | 89 @ 197, 88 @ 147, 87 @ 215 | 388 | 671 | 20000 | TCPSocket 202, Digest 202, File 5 |
| 2 | bundled | 5.2 | 260.4 | 300.5 | 333.2 | 333.2 | 333.2 @ 25 | 333 @ 25, 311 @ 231, 300 @ 79 | 1381 | 663 | 20000 | TCPSocket 201, Digest 201, File 5 |
| 2 | bundled-m1 | 5.5 | 149.4 | 172.5 | 187.1 | 182.2 | 198.7 @ -1 | 199 @ -1, 188 @ -1, 187 @ 1 | 804 | 664 | 20000 | TCPSocket 201, Digest 201, File 5 |
| 2 | global | 5.5 | 68.2 | 86.9 | 197.2 | 90.3 | 197.2 @ 4 | 197 @ 4, 185 @ -0, 166 @ -1 | 409 | 672 | 20000 | TCPSocket 200, Digest 200, File 5 |
| 2 | global32k | 5.5 | 71.7 | 81.4 | 90.1 | 90.1 | 90.1 @ 131 | 90 @ 131, 88 @ 215, 81 @ 6 | 390 | 670 | 20000 | TCPSocket 200, Digest 200, File 5 |
| 3 | bundled | 5.2 | 243.8 | 273.0 | 366.1 | 366.1 | 366.1 @ 60 | 366 @ 60, 318 @ 33, 273 @ 208 | 1306 | 663 | 20000 | TCPSocket 201, Digest 201, File 5 |
| 3 | bundled-m1 | 5.5 | 129.9 | 159.4 | 242.5 | 242.5 | 242.5 @ 115 | 243 @ 115, 208 @ -0, 207 @ 4 | 762 | 664 | 20000 | TCPSocket 200, Digest 200, File 5 |
| 3 | global | 5.2 | 72.3 | 86.3 | 200.9 | 92.9 | 200.9 @ 4 | 201 @ 4, 188 @ -0, 176 @ -0 | 407 | 673 | 20000 | TCPSocket 201, Digest 201, File 5 |
| 3 | global32k | 5.5 | 70.3 | 95.2 | 105.1 | 105.1 | 105.1 @ 212 | 105 @ 212, 99 @ 229, 95 @ 130 | 409 | 671 | 20000 | TCPSocket 203, Digest 203, File 5 |
| 4 | bundled | 5.5 | 256.5 | 294.9 | 323.0 | 323.0 | 323.0 @ 214 | 323 @ 214, 298 @ 38, 295 @ 162 | 1420 | 663 | 20000 | TCPSocket 201, Digest 201, File 5 |
| 4 | bundled-m1 | 5.5 | 146.5 | 182.4 | 195.3 | 186.4 | 226.3 @ -0 | 226 @ -0, 200 @ -1, 195 @ 4 | 815 | 664 | 20000 | TCPSocket 201, Digest 201, File 5 |
| 4 | global | 5.5 | 75.5 | 97.9 | 199.3 | 100.8 | 199.3 @ 1 | 199 @ 1, 196 @ -1, 171 @ -1 | 447 | 670 | 20000 | Digest 202, TCPSocket 202, File 5 |
| 4 | global32k | 5.2 | 70.5 | 84.6 | 91.2 | 91.2 | 91.2 @ 228 | 91 @ 228, 87 @ 11, 85 @ 43 | 379 | 671 | 20000 | TCPSocket 202, Digest 202, File 5 |
| 5 | bundled | 5.2 | 235.0 | 265.9 | 444.4 | 444.4 | 444.4 @ 61 | 444 @ 61, 273 @ -0, 268 @ 51 | 1286 | 663 | 20000 | TCPSocket 201, Digest 201, File 5 |
| 5 | bundled-m1 | 5.7 | 131.6 | 163.5 | 233.9 | 163.5 | 233.9 @ 1 | 234 @ 1, 229 @ -1, 222 @ -1 | 794 | 663 | 20000 | TCPSocket 200, Digest 200, File 5 |
| 5 | global | 5.2 | 63.1 | 73.9 | 170.7 | 77.9 | 171.8 @ -0 | 172 @ -0, 171 @ 4, 152 @ -0 | 351 | 673 | 20000 | TCPSocket 202, Digest 202, File 5 |
| 5 | global32k | 5.5 | 69.3 | 76.0 | 86.5 | 86.5 | 86.5 @ 214 | 86 @ 214, 82 @ 51, 76 @ 114 | 369 | 671 | 20000 | TCPSocket 201, Digest 201, File 5 |

## Per variant (median of 5 runs)

| variant | runs | GCs/min | p50 | p90 | max (window) | max after 10 s | max (incl. connect) | GC ms/min | RSS peak MB |
|---|---|---|---|---|---|---|---|---|---|
| bundled | 5 | 5.2 | 243.8 | 273.0 | 333.2 | 333.2 | 333.2 | 1306 | 663 |
| bundled-m1 | 5 | 5.5 | 131.6 | 163.5 | 229.1 | 182.2 | 229.1 | 794 | 664 |
| global | 5 | 5.2 | 72.1 | 86.3 | 199.3 | 90.3 | 199.3 | 409 | 672 |
| global32k | 5 | 5.5 | 70.3 | 84.6 | 90.1 | 90.1 | 90.1 | 388 | 671 |

## Conclusions

- The narrow patch cuts pause p50 on main from 244 ms (bundled, 4 markers) to 70-72 ms and GC time
  from ~1,300 to ~390-410 ms/min (-69%). `GC_MARKERS=1` sits in between (132 ms, 794 ms/min).
- `global` has 3 growth collections around connect (152-258 ms, at -1 to +4 s, in all 5 runs) while
  its mark stack doubles; after the first 10 s its max is 78-101 ms. `bundled-m1` shows the same
  connect spikes (stack grows there too).
- `global32k` has no growth collections: max pause 86-105 ms over the whole run, all in steady
  state. Steady-state p50/p90 and GC ms/min are the same as `global` within noise (70 vs 72 ms,
  388 vs 409 ms/min).
- Collection frequency (5.2-5.7/min) and RSS (663-673 MB peak) do not depend on the libgc variant;
  finalizers are ~201/s each of `TCPSocket` and `OpenSSL::Digest` in every run.
- Recommendation stands: narrow patch + `-DINITIAL_MARK_STACK_SIZE=32768`.

## Anomalies

- `bundled` has occasional long outliers in steady state: 444 ms at 61 s in r5 and 366 ms at 60 s
  in r3 (stop-the-world 0.2-1.1 ms, i.e. all marking), not tied to a steal spike in the vmstat
  samples taken before the round.
- Stats tick max of 218 ms (r4 `global`) and 224 ms (r5 `global32k`): single samples, not
  matching any GC pause; likely scheduling noise.
- `bundled` r1 had a lower p50 (215 ms) than later rounds (235-260 ms).

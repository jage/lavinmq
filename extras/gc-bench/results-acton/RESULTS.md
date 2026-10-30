# LavinMQ with Acton's bdwgc fork vs bdwgc 8.2.8 (bundled and patched)

Measured on 2026-10-30 on a 4-vCPU, 15 GB cloud VM (Ubuntu 24.04, kernel 6.18), Crystal 1.21.0.
Fork: [actonlang/bdwgc](https://github.com/actonlang/bdwgc) at `2b99b72c` ("Grow the mark stack
without dropping entries", 2026-10-14). Note: Acton's own `Makefile` now pins a later fork commit
(`b5c707b9`, 21 commits on top of `2b99b72`, including "Grow the mark ring instead of dropping
entries"). That commit was not measured.

## Summary

- **Steady state: no difference in pause p50 or mark time.** Once the mark stack is big enough,
  the patched 8.2.8 (`global`) and the fork mark the broker equally fast. Idle broker with
  4 markers: p50 21–24 ms for all three (`global`, `acton-default`, `acton-opts`). Full load:
  p50 31–35 ms and mark p50 24–27 ms for all three. mark.cr agrees: within noise of `global`
  at every fiber count and marker count.
- **Max pause: the fork wins clearly.** It removes the ~100–140 ms collections that patched
  8.2.8 still has. 8.2.8 needs one overflow-and-rescan collection per doubling of the mark
  stack. In every broker run the first 3 measured collections took 96–152 ms (4,096 → 32,768
  entries), whatever the marker count. The fork moves the full stack into a larger one in the
  middle of a collection, without dropping entries. It logs exactly one "Moved … entries" and
  one "Grew" event in mark.cr, and no "Mark stack overflow" at all.
  - Idle, 4 markers: max 27–46 ms (fork) vs 109–141 ms (`global`).
  - Full load: max 38–45 ms (fork, apart from one 511 ms outlier, below) vs 117–138 ms.
  - After the 3rd collection, `global` and the fork have the same max (idle 24–32 ms, load
    38–45 ms).
- **GC time per minute: about 35% lower with the fork**, but only because those first
  collections are gone. In these short runs the growth collections make up a large share of
  all collections, which makes the gap look bigger than it would be on a broker that runs for
  days.
  - Idle, 4 markers: 415–463 ms/min vs 684–733 ms/min.
  - Full load: 85–110 ms/min vs 162–180 ms/min.
  - A long-running broker pays the growth cost again only when its roots outgrow the stack, for
    example when connections pile up. The 262,144-entry initial stack (`bigstack` in
    `build-libgc.sh`) gives 8.2.8 the same effect.
- **`acton-opts` vs `acton-default`: no measurable pause difference.** Under load `acton-opts`
  ran 2.7–3.0 collections/min instead of 3.2 and used ~20 MB more RSS, from the heap growth
  divisor's larger heap. mark.cr showed `acton-opts` 10–20% slower in the first matrix. A
  rerun with one option per build (`mark-options.txt`) did not reproduce that beyond noise:
  steal, bigstack, growdiv and opts all landed within ±15% of default.
- **One 511 ms pause** in `acton-default` full-load run 2: collection 93 of 98, mid-run. Its
  stop-the-world phase took 227 ms (usually 0.1–0.2 ms) and its mark phase 153 ms (usually
  ~25 ms); every phase was inflated. A slow thread suspend points at the VM (this host has CPU
  steal: 5–8 s per 5-minute run) more than at the collector, but this is not proven. Two more
  `acton-default` full-load runs and 12 idle fork runs showed nothing like it.
- **Crystal 1.21 works with the fork as is.** It linked statically against bdwgc master's API
  without changes, and no GC warnings or crashes showed up in any run. All brokers held the
  target 20,000 msg/s (lavinmqperf is rate-limited, so throughput does not tell them apart).
- **`make check` passed for both variants:** 38/38 tests, 0 failures (`raw/make-check-*.log`).
- **Fork tuning options under full load** (one run each, 9–11 collections per 4-minute window,
  so ±1 collection is ±0.25/min):
  - `GC_BYTES_PER_MARKER=4M`: no effect. Every phase is far above 4 MB per marker, so all
    4 markers are used anyway.
  - `GC_ALLOC_BUDGET_PERCENT=100` or `250`: 2.5 collections/min instead of 2.7–3.0, GC time
    78–82 ms/min, RSS +20–40 MB, p50 unchanged.
  - `GC_MIN_BYTES_ALLOCD=128M`: 2.2 collections/min, the same GC time, RSS +40 MB, and a p50
    5 ms higher (fewer, larger collections).
  - At this load (3.5 MB/s allocated) collections are already rare; none of these options is
    worth it for LavinMQ here.

Bottom line: on pause p50 and steady-state mark speed the fork performs like our patched 8.2.8.
On pause max and GC time it beats patched 8.2.8 with the default stack, because it grows the
mark stack without rescanning. A larger initial stack on 8.2.8 gets most of that benefit too.
The bundled libgc with 4 markers stays the worst at every point (~100 ms pauses every
collection).

## mark.cr (`TREE=1 GC_MARKERS=<m> mark-<v> <fibers> 2000000 0`, collect p50 ms over 10 collections)

From `mark-results.txt`. Run-to-run noise on this VM is about ±10–15%, and machine speed drifted
between sessions: the same binaries measured 20–40% slower in `mark-options.txt` an hour later.
Compare within one table only.

| variant | 0 fibers m1 / m2 / m4 | 6,500 fibers m1 / m2 / m4 | 30,000 fibers m1 / m2 / m4 |
|---|---|---|---|
| bundled | 238 / 115 / 51 | 238 / **283 / 275** | 247 / **300 / 300** |
| global | 213 / 108 / 46 | 223 / 112 / 55 | 236 / 127 / 66 |
| acton-default | 223 / 107 / 52 | 224 / 119 / 50 | 238 / 130 / 62 |
| acton-opts | 235 / 122 / 59 | 247 / 120 / 58 | 264 / 133 / 76 |

Heap size: 120 MB, except `acton-opts`, which reached 141 MB (`GC_HEAP_GROWTH_DIVISOR=4`), and
fibers=30,000 on bundled and global (136–137 MB; the fork stayed at 121 MB).

Mark stack log lines with `GC_PRINT_STATS=1` (one process: heap build plus 11 collections;
`raw/mark-stats/`):

| variant | 6,500 fibers m1 / m2 / m4 | 30,000 fibers m1 / m2 / m4 |
|---|---|---|
| bundled | 5 overflow, grew 1× (8,192) / 55 overflow, never grows / 55, never grows | 121 overflow, grew 3× (32,768) / 561, never grows / 561, never grows |
| global | 5 overflow, grew 1× (8,192), same at m1/m2/m4 | 121 overflow, grew 3× (32,768), same at m1/m2/m4 |
| acton-default | 0 overflow, 1 move, grew 1× (16,384), same at m1/m2/m4 | 0 overflow, 1 move, grew 1× (32,768), same at m1/m2/m4 |
| acton-opts | nothing logged (4M-entry initial stack) | nothing logged |

Fork log lines counted: "Mark stack overflow (", "Local mark stack overflow", "Moved N entries of
full mark stack to a larger one", "Grew mark stack to N frames". 8.2.8 lines counted:
"Mark stack overflow; current size", "Grew mark stack to". No "Local mark stack overflow" lines
appeared in any run.

## Broker, idle with forced collections (60 s, 20k queues, 2,000 connections, GC every 3 s)

`GC_MARKERS=<m> PERF=0 FLAP=0 ./run_broker_forcegc.sh <broker> none 60`, two rounds,
interleaved across all 12 configurations. `default` means GC_MARKERS unset (4 markers on this
VM). Pauses in ms. Every pause in each run is in `idle-pause-sequences.txt`.

| config | run | GCs | pause p50 | max | max after 3rd GC | mark p50 | GC ms/min | RSS peak/end MB |
|---|---|---|---|---|---|---|---|---|
| bundled m1 | 1 | 20 | 50.7 | 115.1 | 68 | 47.9 | 1210 | 172/154 |
| bundled m1 | 2 | 20 | 56.6 | 108.9 | 77 | 53.7 | 1251 | 173/155 |
| bundled m4 | 1 | 20 | 98.2 | 133.7 | 134 | 94.8 | 2022 | 172/154 |
| bundled m4 | 2 | 20 | 106.9 | 150.8 | 151 | 103.4 | 2236 | 167/145 |
| bundled default | 1 | 19 | 101.9 | 128.4 | 128 | 99.3 | 2033 | 172/154 |
| bundled default | 2 | 20 | 102.6 | 137.0 | 137 | 99.2 | 2114 | 171/154 |
| global m1 | 1 | 20 | 52.0 | 151.6 | 74 | 49.2 | 1268 | 175/156 |
| global m1 | 2 | 20 | 58.0 | 122.2 | 70 | 54.4 | 1310 | 172/147 |
| global m4 | 1 | 20 | 22.7 | 108.9 | 26 | 20.0 | 684 | 174/156 |
| global m4 | 2 | 20 | 23.6 | 121.5 | 27 | 20.3 | 726 | 174/147 |
| global default | 1 | 20 | 22.4 | 140.9 | 28 | 19.7 | 733 | 173/146 |
| global default | 2 | 20 | 22.5 | 113.3 | 26 | 19.7 | 699 | 175/156 |
| acton-default m1 | 1 | 20 | 50.3 | 70.8 | 71 | 47.4 | 1047 | 184/173 |
| acton-default m1 | 2 | 20 | 53.1 | 75.3 | 75 | 49.6 | 1141 | 182/164 |
| acton-default m4 | 1 | 20 | 21.6 | 29.7 | 30 | 18.7 | 451 | 182/165 |
| acton-default m4 | 2 | 20 | 21.4 | 26.7 | 27 | 19.1 | 441 | 185/174 |
| acton-default default | 1 | 20 | 21.2 | 24.1 | 24 | 18.6 | 425 | 185/173 |
| acton-default default | 2 | 20 | 23.7 | 28.2 | 28 | 20.5 | 463 | 185/173 |
| acton-opts m1 | 1 | 20 | 54.4 | 66.4 | 66 | 50.7 | 1082 | 178/160 |
| acton-opts m1 | 2 | 20 | 48.7 | 63.4 | 63 | 45.8 | 1039 | 180/168 |
| acton-opts m4 | 1 | 20 | 21.0 | 24.4 | 24 | 17.9 | 415 | 179/161 |
| acton-opts m4 | 2 | 20 | 20.8 | 46.2 | 26 | 17.9 | 443 | 183/169 |
| acton-opts default | 1 | 20 | 21.1 | 25.7 | 26 | 17.9 | 425 | 179/169 |
| acton-opts default | 2 | 20 | 20.7 | 31.5 | 32 | 18.0 | 422 | 179/161 |

Every bundled and global run starts with three collections of 90–152 ms, even with
GC_MARKERS=1: serial marking on 8.2.8 also overflows and rescans once per doubling. After that,
global with 4 markers settles at ~22 ms, the same as the fork. Bundled with 4 markers stays at
~100 ms on every collection, because it never grows the stack. The fork's RSS is ~10 MB higher
when idle.

## Broker, full load (240 s, 20k flapping queues, 200 reconnects/s, 20k msg/s)

`GC_MARKERS=4 ./run_broker_frozen.sh <broker> churn 240` (bundled: `GC_MARKERS=1`), one run at a
time. Runs 1–2 were interleaved (bundled, global, acton-default, acton-opts). Runs 3–4 came from
a second batch, interleaved with the option runs. All configurations held 20,000 msg/s.
Every pause in each run is in `load-pause-sequences.txt` and `load-extra-pause-sequences.txt`.

| config | run | GCs | GCs/min | pause p50 | p99 = max | max after 3rd GC | mark p50 | GC ms/min | RSS peak/end MB | pub/s |
|---|---|---|---|---|---|---|---|---|---|---|
| bundled m1 | 1 | 13 | 3.2 | 71.3 | 120.0 | 95 | 62.2 | 267 | 330/269 | 20000 |
| bundled m1 | 2 | 13 | 3.2 | 87.4 | 160.7 | 96 | 75.5 | 301 | 330/284 | 20000 |
| global m4 | 1 | 13 | 3.2 | 32.7 | 117.0 | 39 | 25.2 | 162 | 336/286 | 20000 |
| global m4 | 2 | 13 | 3.2 | 34.3 | 121.3 | 40 | 26.7 | 173 | 322/255 | 20000 |
| global m4 | 3 | 13 | 3.2 | 32.4 | 137.8 | 41 | 25.8 | 180 | 322/255 | 20000 |
| acton-default m4 | 1 | 14 | 3.5 | 32.7 | 38.4 | 38 | 25.2 | 110 | 340/272 | 20000 |
| acton-default m4 | 2 | 13 | 3.2 | 31.6 | **511.4** | 511 | 24.3 | 221 | 338/288 | 20000 |
| acton-default m4 | 3 | 13 | 3.2 | 34.8 | 45.3 | 45 | 26.0 | 107 | 338/280 | 20000 |
| acton-default m4 | 4 | 13 | 3.2 | 33.6 | 43.5 | 43 | 27.2 | 109 | 338/271 | 20000 |
| acton-opts m4 | 1 | 12 | 3.0 | 35.0 | 43.1 | 43 | 25.2 | 99 | 358/310 | 20000 |
| acton-opts m4 | 2 | 11 | 2.7 | 31.7 | 41.3 | 41 | 24.0 | 85 | 356/295 | 20000 |

With only 11–14 collections per run, p99 equals max. Pauses grow from ~25 ms to ~40 ms over each
run as the heap grows; this happens with every libgc.

The 511 ms pause (`raw/load/acton-default-m4-r2/gc.pauses`, line 93): total 511 ms,
stop-the-world 227 ms, mark 153 ms, other 131 ms. The collections around it took 29–32 ms
(0.1–0.2 ms stop-the-world, 22–25 ms mark).

## Fork options under full load (step 7, acton-opts broker, GC_MARKERS=4, one run each)

| config | GCs | GCs/min | pause p50 | max | mark p50 | GC ms/min | RSS peak/end MB |
|---|---|---|---|---|---|---|---|
| acton-opts (runs 1, 2, for reference) | 12, 11 | 3.0, 2.7 | 35.0, 31.7 | 43.1, 41.3 | 25.2, 24.0 | 99, 85 | 358/310, 356/295 |
| `GC_BYTES_PER_MARKER=4194304` | 11 | 2.7 | 31.6 | 42.6 | 24.3 | 90 | 358/298 |
| `GC_ALLOC_BUDGET_PERCENT=250` (Acton's default) | 10 | 2.5 | 35.8 | 42.2 | 24.6 | 82 | 378/318 |
| `GC_ALLOC_BUDGET_PERCENT=100` | 10 | 2.5 | 33.4 | 37.6 | 23.8 | 78 | 394/335 |
| `GC_MIN_BYTES_ALLOCD=128M` | 9 | 2.2 | 40.4 | 42.7 | 27.6 | 82 | 395/335 |

CPU steal recorded per run in this batch: 5.2–8.3 s per ~5.5-minute run (`load-extra.txt`).

## Builds

- **bundled:** the libgc shipped with Crystal 1.21.0 (8.2.8).
- **global:** bdwgc 8.2.8 with `bdwgc-mark-stack-overflow-global.patch`, built by
  `../build-libgc.sh`. `CFLAGS=-O2`, then `./configure --disable-debug --disable-shared
  --enable-large-config --enable-threads=posix --enable-parallel-mark
  --with-libatomic-ops=none`.
- **acton-default:** actonlang/bdwgc `2b99b72c85ac89f580dc7353e078290f83e8b065`, built by
  `../build-libgc-acton.sh`: `./autogen.sh`, then the same configure flags as above,
  `CFLAGS=-O2`.
- **acton-opts:** as acton-default, with
  `CFLAGS="-O2 -DINITIAL_MARK_STACK_SIZE=4194304 -DSTEAL_MARK_STACK_RANGES -DGC_TL_REFILL_MAX=16
  -DGC_NO_THREAD_LOCAL_WARMUP -DGC_HEAP_GROWTH_DIVISOR=4"`. These are the macros that the Acton
  `base/build.zig` defaults (`gc_initial_mark_stack_size=4194304`,
  `gc_mark_range_stealing=true`, `gc_thread_local_refill_blocks=16`,
  `gc_no_thread_local_warmup=true`, `gc_heap_growth_divisor=4`) turn into, through the fork's
  `build.zig`. Acton defaults left out, and why:
  - `GC_ALLOC_BUDGET_PERCENT=250` and `GC_BYTES_PER_MARKER=4194304`: policy knobs, tested at
    run time through their environment variables instead (step 7).
  - `HBLKSIZE=16384` (with matching `MINHINCR`/`MAXHINCR`) and the `GC_TINY_FREELISTS` that go
    with it: they change the heap layout.
  - `DONT_ADD_BYTE_AT_END`: not safe to assume for Crystal, which can hold pointers just past
    the end of a buffer.
  - `GC_REALLOC_NO_FREE`: changes how Crystal's `GC_realloc`-heavy Array/String growth frees
    memory.
  - Memory limit and heap ceiling: these are Acton runtime settings, not libgc macros.
- **acton-steal, acton-bigstack, acton-growdiv** (used for `mark-options.txt` only): one of
  `-DSTEAL_MARK_STACK_RANGES`, `-DINITIAL_MARK_STACK_SIZE=4194304`, `-DGC_HEAP_GROWTH_DIVISOR=4`.
- **mark and broker binaries:**
  `CRYSTAL_LIBRARY_PATH=<prefix>/lib:$(crystal env CRYSTAL_LIBRARY_PATH) crystal build --release
  ...`. The broker is `$SCRATCH/broker-src` (gc-heap-stats + password-digest-without-finalizer)
  with the zz_ hook files re-added, as in `../setup.sh`. `nm` confirms the fork is linked
  (`GC_set_bytes_per_marker` present).
- **`make check`:** `make -j4 check` in each fork source tree: 38 of 38 passed for both
  variants, including markstackgrowthtest, serialgrowthtest, finalizemarktest, allocbudgettest
  and markercounttest.

## Commands

    SCRATCH=$HOME/gcbench BROKERS="bundled global" extras/gc-bench/setup.sh
    source $HOME/gcbench/env.sh
    RUN_CHECK=1 extras/gc-bench/build-libgc-acton.sh $SCRATCH/gcbuild-acton
    # mark-acton-* and lavinmq-acton-* built as described under Builds
    cd extras/gc-bench/results-acton
    ./run_mark.sh > mark-results.txt                     # step 4
    ./run_idle.sh > idle-results.txt                     # step 5: 4 brokers x m in {1,4,default} x 2 rounds
    ./run_load.sh > load-results.txt                     # step 6: bundled m1, global/acton-* m4, 2 rounds
    RUN_START=3 RUNS=1 CONFIGS="acton-default:4::acton-default-m4 global:4::global-m4 \
      acton-opts:4:GC_BYTES_PER_MARKER=4194304:opts-bpm4M \
      acton-opts:4:GC_ALLOC_BUDGET_PERCENT=250:opts-budget250" ./run_load.sh > load-extra.txt
    RUN_START=4 RUNS=1 CONFIGS="acton-default:4::acton-default-m4 \
      acton-opts:4:GC_ALLOC_BUDGET_PERCENT=100:opts-budget100 \
      acton-opts:4:GC_MIN_BYTES_ALLOCD=128M:opts-minalloc128M" ./run_load.sh >> load-extra.txt
    python3 -I tables.py idle-results.txt                # tables above

## Files

- `mark-results.txt`, `mark-options.txt`: mark.cr output. `raw/mark-stats/`: the
  `GC_PRINT_STATS=1` logs.
- `idle-results.txt`, `load-results.txt`, `load-extra.txt`: summarize.py and phases.py lines,
  one pair per run.
- `*-pause-sequences.txt`: every pause in the measurement window, in ms.
- `raw/idle/`, `raw/load/`: each run's directory (gc.pauses, allocs, finalizers, samples,
  driver, perf and broker logs). Trace and map files were dropped; they are only useful with the
  binaries.
- `raw/make-check-*.log`: the fork's `make check` output.

## Changes to the scripts

- `setup.sh`: `apt-get install liblz4-dev` failed on this fresh VM ("Unable to locate package")
  without an `apt-get update` first; it now runs `apt-get update`. The broker build needs
  liblz4 for clustering. Here I installed it by hand before the broker step.
- New `build-libgc-acton.sh`, plus `results-acton/run_mark.sh`, `run_idle.sh`, `run_load.sh`
  and `tables.py`.
- `run_load.sh` records CPU steal per run; only the second batch (`load-extra.txt`) has it.

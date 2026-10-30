# bdwgc 8.2.8 mark-stack-overflow patches: validation and measurements

Machine: 4 vCPU, 15 GB RAM, Linux 6.18, gcc 13.3, `vm.max_map_count` 65530, Crystal 1.21.0
(bundled libgc is also 8.2.8, per `GC_get_version`). libgc built with `extras/gc-bench/build-libgc.sh`
(static, `--enable-parallel-mark --enable-large-config --enable-threads=posix`). Both patches
applied without fuzz. Date: 2026-10-30.

## Summary

- **`make check`: all three variants pass, 16/16 tests** (stock, broad, global). gctest also
  passes 3/3 runs with `GC_MARKERS=4` and with `GC_MARKERS=1` on every variant. Collection counts
  and "Grew mark stack" patterns look the same as stock. **Caveat:** bdwgc's own tests never reach
  the patched function. There are 0 "Mark stack overflow" lines across all 18 gctest
  `GC_PRINT_STATS` runs; gctest's stack growth comes from `typd_mlc.c`. So `make check` only shows
  the patches break nothing else. To exercise the patched branch, `overflow_test.c` (below) pushes
  200,000 roots with `GC_push_all_eager` from a `push_other_roots` callback, as Crystal does for
  fiber stacks. It checks every object after each of 100 collections. **0 bad objects on stock,
  broad and global with 1, 2 and 4 markers.**
- **global fixes the slowdown as well as broad.** With `TREE=1`, parallel marking and parked
  fibers, stock or bundled libgc takes 345–390 ms per collection with 2 or 4 markers. That is slower
  than 1 marker, and the stack never grows. global and broad both bring this back to the 0-fiber
  numbers: about 155–178 ms with 2 markers and 85–112 ms with 4. They match the `bigstack` build.
  Single-run differences between broad and global (e.g. 112 vs 94 ms at 30000/4) are within
  run-to-run noise; in the 250-collection stress runs the p50s are 95–101 ms for both. Overflow and
  growth logs are identical for broad and global in every mark.cr run. In these workloads the
  only overflows that matter are on the global stack, so broad's extra coverage of helper-local
  stacks made no observable difference.
- **No runaway growth.** In 260 collections at 30000 fibers with `TREE=1`, global (4, 2 and 1
  markers) and broad (4 markers) grow the stack 3 times (8192 → 16384 → 32768) during collections
  #11–#13, then never overflow or grow again. Stock overflows in all 250 collections after the
  fibers exist, 51 times each (12,750 lines), and never grows. The live structure (2M nodes,
  arrays and strings) verified intact after 250 collections on all three. In the C test, both
  patches grow to 262,144 entries (the size that holds all 200k roots) by collection #7, then stop.
- **One honest negative**, from the synthetic C test only. That heap is 200k tiny root-only
  objects with almost no transitive work. There, parallel marking (2 or 4 markers) is slower than
  1 marker on every build. With 4 markers, broad/global/bigstack mark in about 21–22 ms against
  14.5 ms for stock (total run 2.5 s vs 1.4 s). `bigstack` (unpatched, big stack from the start)
  shows the same cost, so it comes from parallel-marking a large global stack. It is not the
  patch's flag logic. With 1 marker all builds are equal. mark.cr, which has a real object graph
  behind the roots, shows the opposite: 4x faster.
- `30000` fibers worked on this machine (no `max_map_count` failure), so nothing was skipped.

## 1. bdwgc test suite

| variant | `make check` | gctest `GC_MARKERS=4` (3 runs) | gctest `GC_MARKERS=1` (3 runs) | "Mark stack overflow" lines (PRINT_STATS) |
|---|---|---|---|---|
| stock  | 16/16 PASS | 3/3 PASS, ~5.4–5.7 s | 3/3 PASS, ~5.7 s | 0 |
| broad  | 16/16 PASS | 3/3 PASS, ~5.4–5.7 s | 3/3 PASS, ~5.6–5.9 s | 0 |
| global | 16/16 PASS | 3/3 PASS, ~5.5–5.7 s | 3/3 PASS, ~5.7–6.0 s | 0 |

In every variant, gctest's `GC_PRINT_STATS` logs show 37–44 "Grew mark stack" lines, with a last
size of 524,288 or 1,048,576 frames. gctest runs several GC test phases and the stack restarts
from 8192 several times. These all come from typed-array marking (`typd_mlc.c`), not from
`GC_signal_mark_stack_overflow`. The ranges overlap fully between variants; this is run-to-run
variation, not a patch effect. With `GC_MARKERS=1` the log says "Single marker thread, turning off
parallel marking", so both modes ran. Logs: `logs/make-check-<v>.txt`, `logs/gctest-<v>-m<m>-r<n>.txt`,
`logs/gctest-stats-<v>-m<m>-r<n>.txt`.

## 2. Direct test of the patched branch (`overflow_test.c`)

200,000 roots, each pointing to an object that points to a child, pushed with `GC_push_all_eager`.
Each of 100 rounds allocates 100k garbage objects (filled with 0xff), collects, and checks every
root and child. All runs `exit 0`, `bad 0`.

| variant | markers | result | collections with overflow | "Grew mark stack" | mean mark ms (coll. ≥ #20) | wall s (5 runs, no stats) |
|---|---:|---|---:|---|---:|---|
| stock    | 4 | PASS | 105 of 106 | none | 14.5 | 1.37–1.54 |
| stock    | 2 | PASS | 105 of 106 | none | 15.3 | |
| stock    | 1 | PASS | 6 | 8192 … 262144 | 5.7 | 0.74–0.83 |
| broad    | 4 | PASS | 6 | 8192 … 262144 | 21.4 | 2.48–2.53 |
| broad    | 2 | PASS | 6 | 8192 … 262144 | 16.5 | |
| broad    | 1 | PASS | 6 | 8192 … 262144 | 5.6 | 0.75–0.85 |
| global   | 4 | PASS | 6 | 8192 … 262144 | 21.3 | 2.40–2.52 |
| global   | 2 | PASS | 6 | 8192 … 262144 | 15.0 | |
| global   | 1 | PASS | 6 | 8192 … 262144 | 5.1 | 0.65–0.74 |
| bigstack | 4 | PASS | 0 | none | 22.5 | 2.50–2.66 |
| bigstack | 1 | PASS | 0 | none | 5.6 | 0.72–0.90 |

This reproduces the bug in C. With parallel marking, stock overflows on every collection and never
grows; with 1 marker it grows (the `!GC_parallel` path). Logs: `logs/overflow/`.

## 3. mark.cr: collect p50 (ms), with (overflow lines / last "Grew mark stack" size)

`./mark <fibers> 2000000 0`. The p50 comes from a plain run. Overflow lines and growth come from a
second run with `GC_PRINT_STATS=1`; its p50 is in `mark-matrix.txt` as `stats_p50` and agrees
within noise. One run per cell, p50 of 10 collections. Expect ±10% noise per cell (compare the
0-fiber rows across variants, which are the same code path).

### TREE=1 (1000 lists)

| fibers | markers | bundled | stock | broad | global | bigstack |
|---:|---:|---:|---:|---:|---:|---:|
| 0 | 1 | 311.1 (0/-) | 306.0 (0/-) | 286.7 (0/-) | 308.6 (0/-) | 302.0 (0/-) |
| 0 | 2 | 167.4 (0/-) | 151.1 (0/-) | 149.3 (0/-) | 152.5 (0/-) | 153.6 (0/-) |
| 0 | 4 | 87.5 (0/-) | 86.1 (0/-) | 79.4 (0/-) | 81.1 (0/-) | 79.1 (0/-) |
| 6500 | 1 | 335.9 (5/8192) | 299.6 (5/8192) | 291.9 (5/8192) | 289.9 (5/8192) | 301.4 (0/-) |
| 6500 | 2 | 369.3 (55/-) | 345.6 (55/-) | 154.2 (5/8192) | 156.5 (5/8192) | 159.4 (0/-) |
| 6500 | 4 | 371.9 (55/-) | 354.2 (55/-) | 95.4 (5/8192) | 85.3 (5/8192) | 88.0 (0/-) |
| 20000 | 1 | 328.7 (64/32768) | 307.6 (64/32768) | 317.3 (64/32768) | 317.3 (64/32768) | 300.4 (0/-) |
| 20000 | 2 | 359.9 (352/-) | 362.6 (352/-) | 162.3 (64/32768) | 167.7 (64/32768) | 153.0 (0/-) |
| 20000 | 4 | 372.5 (352/-) | 361.2 (352/-) | 94.3 (64/32768) | 91.8 (64/32768) | 89.1 (0/-) |
| 30000 | 1 | 337.4 (121/32768) | 322.7 (121/32768) | 332.3 (121/32768) | 323.8 (121/32768) | 313.6 (0/-) |
| 30000 | 2 | 383.1 (561/-) | 369.4 (561/-) | 164.7 (121/32768) | 178.1 (121/32768) | 175.4 (0/-) |
| 30000 | 4 | 390.5 (561/-) | 388.9 (561/-) | 112.2 (121/32768) | 93.5 (121/32768) | 109.9 (0/-) |

With the patches, overflows occur only in the first 1–3 collections after the fibers are spawned
(#11–#13 of 21). Stock and bundled overflow in all 11 of those collections. Example from
`ovsummary.sh`:

    tree1-stock-f30000-m4.stats   collections=21 with_overflow=11 overflow_lines=561 last_overflow=#21 grew=-
    tree1-global-f30000-m4.stats  collections=21 with_overflow=3  overflow_lines=121 last_overflow=#13 grew=8192,16384,32768
    tree1-broad-f30000-m4.stats   collections=21 with_overflow=3  overflow_lines=121 last_overflow=#13 grew=8192,16384,32768

### No TREE (one long list), sanity check

| fibers | markers | bundled | stock | broad | global | bigstack |
|---:|---:|---:|---:|---:|---:|---:|
| 0 | 1 | 61.4 (0/-) | 64.1 (0/-) | 73.7 (0/-) | 61.2 (0/-) | 56.3 (0/-) |
| 0 | 2 | 61.7 (0/-) | 59.9 (0/-) | 61.7 (0/-) | 65.3 (0/-) | 65.3 (0/-) |
| 0 | 4 | 58.5 (0/-) | 67.2 (0/-) | 63.8 (0/-) | 65.2 (0/-) | 64.4 (0/-) |
| 6500 | 1 | 63.1 (5/8192) | 70.0 (5/8192) | 69.1 (5/8192) | 66.9 (5/8192) | 61.3 (0/-) |
| 6500 | 2 | 108.0 (55/-) | 95.9 (55/-) | 68.0 (5/8192) | 72.6 (5/8192) | 63.3 (0/-) |
| 6500 | 4 | 99.9 (55/-) | 106.3 (55/-) | 80.1 (5/8192) | 68.9 (5/8192) | 63.4 (0/-) |

A single list cannot be marked in parallel, so markers don't help. The fiber overflow still costs
stock/bundled about 35–45 ms, and the patches remove most of it.

## 4. Stress: 250 timed collections, TREE=1, 30000 fibers (`mark_stress.cr`)

`mark_stress.cr` is mark.cr with 250 collections, 1000 garbage nodes allocated before each, and a
full walk of the live structure at the end. 260 collections in total, including those during setup.

| variant | markers | block p50 ms (colls 1–50 / 51–100 / … / 201–250) | overflowing collections | growth | verify |
|---|---:|---|---|---|---|
| global | 4 | 101.4 / 99.5 / 101.3 / 97.1 / 100.7 | 3 (#11–#13), none after | 8192, 16384, 32768 | PASS |
| global | 2 | … 169.4 (last block) | 3 (#11–#13) | 8192, 16384, 32768 | PASS |
| global | 1 | … 326.8 (last block) | 3 (#11–#13) | 8192, 16384, 32768 | PASS |
| broad  | 4 | 99.8 / 94.0 / 98.0 / 96.4 / 95.5 | 3 (#11–#13), none after | 8192, 16384, 32768 | PASS |
| stock  | 4 | 366.1 / 367.4 / 374.5 / 360.0 / 373.4 | 250 (every one, #11–#260) | none | PASS |

The first block's max (445–473 ms) for global and broad is from the overflowing collections #11–#13.
After that the max per block is 112–131 ms. Mean world-stopped mark time over collections ≥ #20:
global m4 98.7 ms, broad m4 96.0 ms, stock m4 367.6 ms. Logs: `logs/stress/`.

## Commands

    # Crystal 1.21 and libgc variants
    mkdir -p $HOME/gcbench/cr
    curl -sSfL https://github.com/crystal-lang/crystal/releases/download/1.21.0/crystal-1.21.0-1-linux-x86_64.tar.gz | tar xz -C $HOME/gcbench/cr
    export PATH=$HOME/gcbench/cr/crystal-1.21.0-1/bin:$PATH
    extras/gc-bench/build-libgc.sh $HOME/gcbench/gcbuild

    # 1. bdwgc test suite
    for v in stock broad global; do (cd $HOME/gcbench/gcbuild/src-$v && make -j4 check); done
    for v in stock broad global; do for m in 4 1; do for r in 1 2 3; do
      GC_MARKERS=$m ./src-$v/gctest; GC_MARKERS=$m GC_PRINT_STATS=1 ./src-$v/gctest
    done; done; done      # in $HOME/gcbench/gcbuild

    # 2. overflow_test.c (also built against bigstack)
    gcc -O2 -Wall -I$HOME/gcbench/gcbuild/install-$v/include overflow_test.c \
        $HOME/gcbench/gcbuild/install-$v/lib/libgc.a -lpthread -o overflow-$v
    GC_MARKERS=$m GC_PRINT_STATS=1 ./overflow-$v 200000 100

    # 3. mark.cr against each libgc, and the matrix
    base=$(crystal env CRYSTAL_LIBRARY_PATH)
    crystal build --release extras/gc-bench/mark.cr -o $HOME/gcbench/mark/mark-bundled
    CRYSTAL_LIBRARY_PATH=$HOME/gcbench/gcbuild/install-$v/lib:$base \
        crystal build --release extras/gc-bench/mark.cr -o $HOME/gcbench/mark/mark-$v
    ./run-mark.sh $HOME/gcbench/mark logs/mark > mark-matrix.txt
    #   per cell: [TREE=1] GC_MARKERS=<m> ./mark-<v> <fibers> 2000000 0   (plain, then GC_PRINT_STATS=1)

    # 4. stress
    CRYSTAL_LIBRARY_PATH=$HOME/gcbench/gcbuild/install-$v/lib:$base \
        crystal build --release mark_stress.cr -o $HOME/gcbench/mark/stress-$v
    TREE=1 GC_MARKERS=$m GC_PRINT_STATS=1 ./stress-$v 30000 2000000 0

    # summaries
    ./ovsummary.sh logs/mark/*.stats logs/stress/*.stats logs/overflow/*.stats
    ./marktime.sh  logs/overflow/*.stats logs/stress/*.stats

## Files

- `mark-matrix.txt`: one line per mark.cr cell. `logs/mark/<tree>-<v>-f<fibers>-m<m>.{out,stats}`: raw output.
- `logs/stress/`, `logs/overflow/` (incl. `timing.txt`), `logs/make-check-*.txt`, `logs/gctest-*.txt`.
- `run-mark.sh`, `mark_stress.cr`, `overflow_test.c`, `ovsummary.sh`, `marktime.sh`: the scripts above.

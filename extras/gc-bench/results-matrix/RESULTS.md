# What Acton's bdwgc commits give LavinMQ beyond the mark stack fix

Plan and scenarios: `../PLAN-acton.md`. All tables with ranges: `tables.md`. Raw lines: `raw/`.
4-vCPU Firecracker VM (Intel Xeon, 15 GB), load generators on the same machine, Crystal 1.22.2,
LavinMQ main `359fab1`, brokers built with `--frame-pointers always` and the `gc_pauses.cr` hook.
Medians; microbenchmarks 5 runs (AX 3), broker scenarios 3 runs (B3U 2), variants interleaved.

## Answer

- **Nothing in the fork beats the mark stack fix on what LavinMQ does today.** On top of `fix`
  (8.2.12 + global patch + 32k initial stack), the fork head `9ad2afa2` leaves pause p50, pause
  max and GC time per minute within ±5% in both broker scenarios with many connections (B2, B3),
  and costs ~100 MB more RSS (+16%), also with `GC_UNMAP_THRESHOLD=1`.
- **At full message rate it cuts GC time by a third, which is ~1% of broker CPU.** B1 16 B:
  GC 34 → 23 ms/s; libgc in 4.4% → 3.1% of CPU samples; throughput +2% (within noise).
- **The one large effect is multi-threaded allocation: 3.4-4x at 4 threads, and an 8.2.12
  backport of 2 lines gets most of it.** 8.2.12 holds the mark lock across the allocator unlock
  when a free-list refill registers as a builder; every waiting allocator then queues behind
  the mark lock (31% of CPU in kernel futex wakes). Releasing the mark lock first
  (`../bdwgc-8.2.12-fl-builder-unlock-order.patch`, found by bisecting to `27c37207`, `make check`
  16/16) takes 4 allocating threads from 667 to 205 ns per step; the fork does 173. **LavinMQ
  doesn't benefit yet**: under load it runs one mutator thread (86% CPU, markers ~0.5% each). It
  matters once LavinMQ runs Crystal's multi-threaded scheduler.
- **Prefetch on push (843bb7e6) shows no gain here**, in the fork or backported: mark times within
  ±6% (noise) with 1 and 4 markers, also for a heap with pointer-free leaves. Acton's -51% was
  16 markers on a 16-core Ryzen, where marking is bandwidth bound; 4 vCPUs aren't.

## Matrix (change of the median against `fix`)

| scenario | metric | stock | fix-pf | fix-fl | acton | acton-nopf | acton-noinl | acton +refill8 |
|---|---|---|---|---|---|---|---|---|
| M1 mark, 1 marker | collect p50 (262 ms) | ±0% | -6% | | -3% | +1% | -3% | |
| M1 mark, 4 markers | collect p50 (67 ms) | ±0% | ±0% | | -1% | ±0% | -1% | |
| M2 pointer-free leaves, 1 marker | collect p50 (347 ms) | ±0% | -6% | | ±0% | -3% | ±0% | |
| M2 pointer-free leaves, 4 markers | collect p50 (86 ms) | +2% | ±0% | | +2% | +6% | ±0% | |
| M3 6,500 fibers, 4 markers | collect p50 (67 ms) | **+344%** | +3% | | +4% | +8% | +5% | |
| A1 alloc, 1 thread | ns/step (38) | +3% | | -2%¹ | -11% | | -1% | -14% |
| A1 alloc, 2 threads | ns/step (71) | -5% | | +1%¹ | -15% | | -6% | -32% |
| A1 alloc, 4 threads | ns/step (550) | -4% | | **-69%**¹ | **-77%** | | **-75%** | **-84%** |
| B1 16 B full speed | consume rate (987k/s) | ±0% | +1% | | +2% | +1% | +1% | +2% |
| B1 16 B full speed | GC ms/s (34) | -1% | -1% | | **-34%** | -32% | -37% | -36% |
| B1 1 KiB full speed | consume rate (251k/s) | -1% | -1% | | -3% | -2% | ±0% | +1% |
| B1 1 KiB full speed | GC ms/s (7.3) | +14% | +4% | | -16% | -12% | -16% | -10% |
| B2 idle, 2k conns, forced GC | pause p50 (31 ms) | **+309%** | -3% | | +4% | +6% | | |
| B2 idle | pause max (36 ms) | **+353%** | +17% | | +13% | +14% | | |
| B2 idle | RSS peak (502 MB) | ±0% | +1% | | **+17%** | +19% | | |
| B3 full load | pause p50 (40 ms) | **+265%** | -2% | | ±0% | | | |
| B3 full load | GC ms/min (236) | **+265%** | -3% | | +5% | | | |
| B3 full load | RSS peak (611 MB) | ±0% | ±0% | | **+16%** | | | |
| B3U full load, unmap threshold 1 | pause p50 (38 ms) / GC ms/min (225) / RSS (609 MB) | | | | -2% / +5% / **+16%** | | | |

¹ From the AX phase (3 runs, after a container restart; absolute times ~25% slower than A1,
compare within AX): `fix` 667, `master` 627, `fix-fl` 205, `acton` 173, `acton-noatomicfl` 186,
`acton-noidlecv` 172 ns/step at 4 threads.

`acton+bpm4m` (`GC_BYTES_PER_MARKER=4M`, fewer markers for small phases): B2 within ±5% of `acton`;
every phase here is large enough for all 4 markers.

## Findings

1. **The mark stack fix is the whole pause win.** `stock` 8.2.12 rescans the heap on every
   collection with 2,000 connections: 126 ms vs 31 ms idle, 144 vs 40 ms under full load. With the
   32k initial stack, `fix` has no growth collections at start-up any more (B2 max 36 ms; the 8.2.8
   runs of October had 96-152 ms there).
2. **Allocator lock convoy in 8.2.12 and upstream master.** Bisect of the fork (`bisect-alloc4.txt`):
   first fast commit `27c37207` "Update free-list builder count atomically". Its atomic count is
   not what matters (`acton-noatomicfl` is as fast); its fallback path, which releases the mark
   lock before the allocator lock, is. Profiles: `viz/a1-fix.svg` (31% `_raw_spin_unlock_irqrestore`
   under `__lll_lock_wake` from `GC_generic_malloc_many` and `GC_release_mark_lock`) against
   `viz/a1-acton.svg` (7%). Upstream master has the same ordering (`master` as slow as `fix`): an
   upstream bdwgc issue with the 2-line patch and `alloc.cr` numbers is warranted.
3. **Thread-local refills from several blocks (`GC_TL_REFILL_MAX=8`, b17b72fd) add another
   -14% to -32%** on top of the fork in A1, nothing measurable in the broker.
4. **RSS +16% with the fork, from heap sizing, not leaks.** RSS follows libgc's heap size, which
   is set during the start-up burst (20k queue declarations, 2,000 connections) and doesn't
   shrink. Heap size varies between runs for both (`fix` 224-416 MB, `acton` 401-498 MB at the same
   point in 3 runs each), but the fork lands higher in every matrix run. Not bisected.
5. **Message path: GC is ~4% of broker CPU at 1M msg/s** (`viz/b1-diff.svg`, `viz/b1-report.html`):
   the fork takes a third of that (cheaper allocation and sweeping), which doesn't show in throughput.
6. **Prefetch, inlining, cache-line layout: no measurable effect on 4 vCPUs.** Expected to matter on
   machines with many markers; not testable here.

## Recommendation

1. Ship `fix` (global patch + 32k initial stack) in the 84codes/crystal libgc, as planned.
2. Add `bdwgc-8.2.12-fl-builder-unlock-order.patch` to it: 2 lines, no effect single-threaded,
   3x for parallel allocation, which LavinMQ will hit with the multi-threaded scheduler (and
   lavinmqperf, other Crystal services, already do). Propose both upstream.
3. Don't adopt the fork: no gain for LavinMQ's current workload, +16% RSS. Re-evaluate the
   prefetch on a 16+ core machine before dismissing it for large deployments.

## Visualisations (`viz/`, open in a browser)

- `b3-report.html`: 20 s `lavinmq-bpf record` of `stock`, `fix` and `acton` under full load
  (60 s into the window): timeline per thread with collections and stop-the-world bands, memory,
  allocation flame graphs, Compare tab.
- `b1-report.html`, `b1-diff.svg`: CPU profiles of `fix` vs `acton` at full speed (16 B), the
  diff red where `acton` spends more.
- `a1-fix.svg`, `a1-acton.svg`, `a1-acton-noatomicfl.svg`: the 4-thread allocation profiles.

## Not covered

More than 4 cores (prefetch, cache-line layout, efficiency cores), aarch64, LavinMQ under the
multi-threaded scheduler, the cause of the fork's larger heap.

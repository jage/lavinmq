# Plan: what do Acton's bdwgc commits give LavinMQ, beyond the mark stack fix?

The mark stack fix (narrow patch + 32,768-entry initial stack) is settled: 3.3x lower pause p50
and 4-5x less GC time under full load (`results-final-load`). Acton's fork at `2b99b72` matched
the patched 8.2.8 on steady-state pause p50 (`results-acton`). That fork has since gained ~100
commits, and the earlier runs only measured pauses at a capped 20k msg/s, so the CPU and
throughput effects of the allocator commits were never measured.

Question: on top of the fix, how much does each group of Acton commits give, and does any of it
justify carrying more than the fix?

## Variants (`build-libgc-matrix.sh`)

All are static `libgc.a`, built with 84codes/crystal-packages' flags (`--enable-large-config`,
`-O2 -fPIC -std=gnu17`), parallel marking and thread-local allocation on, linked into the same
LavinMQ main (`359fab1`) with Crystal 1.22.2.

| variant | what | isolates |
|---|---|---|
| `stock` | bdwgc 8.2.12, what LavinMQ ships today | today |
| `fix` | 8.2.12 + global mark stack patch + 32k initial stack | the baseline |
| `fix-pf` | `fix` + prefetch on push, backported (8 lines, `bdwgc-8.2.12-prefetch-on-push.patch`, `make check` 16/16) | 843bb7e6 on 8.2.12 |
| `acton` | fork head `9ad2afa2` (2026-11-04), no defines | all the fork's defaults |
| `acton-nopf` | `acton` + `-DGC_NO_PUSH_PREFETCH` | 843bb7e6 inside the fork |
| `acton-noinl` | `acton` + `-DGC_NO_TL_MALLOC_FAST_PATH -DGC_ATTR_ALWAYS_INLINE=` | 9b7544f2, 827001c9, 3d2f7797 |

Runtime options of `acton` (off by default), as extra rows where they target the scenario:
`GC_TL_REFILL_MAX=8` (b17b72fd, refills from several blocks), `GC_BYTES_PER_MARKER=4M`
(b51001bf, fewer markers for small phases).

Attribution: `acton - fix` is everything; `acton - acton-nopf` the prefetch;
`acton - acton-noinl` the inlining; the rest (cache-line layout 85b97f89, free block runs
d544a64e, header walks 99818f66, mark ring e5dc41c0, merge_unmapped c5aa6c3e, ...) has no
switch and is the remainder.

## Scenarios

| id | what | targets | metric |
|---|---|---|---|
| M1 | `mark.cr`, `TREE=1`, 2M nodes, no fibers, markers 1 and 4 | mark loop: inlining, prefetch, cache lines | collect p50 |
| M2 | `mark.cr`, `LEAVES=1`, 2M nodes each with a String and a 64 B buffer, markers 1 and 4 | prefetch on push (pointer-free targets, LavinMQ's shape) | collect p50 |
| M3 | `mark.cr`, `TREE=1`, 6,500 parked fibers, markers 4 | root push and mark stack (regression check vs `fix`) | collect p50 |
| A1 | `alloc.cr`, 1, 2 and 4 threads, 10M steps each, 200k kept per thread | allocation fast path, refills under the allocator lock, write-hot shared data | ns/step |
| B1 | broker at full speed, `lavinmqperf throughput -x 2 -y 2`, 16 B and 1 KiB, 30 s | everything end to end on the message path | msg/s, broker CPU us/msg, GC ms/s |
| B2 | broker, 20k queues + 2,000 connections, idle, forced GC every 3 s (`run_broker_forcegc.sh`) | pause with many fiber roots | pause p50 / max |
| B3 | broker, full load: 20k flapping queues, 200 reconnects/s, 20k msg/s (`run_broker.sh churn`) | pauses and GC time in a realistic mix | pause p50 / p90 / max, GC ms/min, RSS |

Repetitions: microbenchmarks 5 runs each, broker scenarios 3 runs, interleaved across variants
so drift hits all of them alike. Same 4-vCPU VM as the earlier rounds, load generators on the
same machine.

## Visualisation (`extras/bpf`)

- B1 16 B: `lavinmq-bpf profile` on `fix` and `acton` (brokers built with frame pointers), then
  `lavinmq-bpf diff` and the `report` comparison: where the CPU share moves (`GC_mark_from`,
  `GC_malloc*`, `GC_generic_malloc_many`, lock spinning).
- B3: `lavinmq-bpf record` for 20 s on `stock`, `fix` and `acton`: timeline with collections
  and stop-the-world bands, memory lane, allocation flame graph; `report` compares them.
- `lavinmq-bpf gc` (TSV) alongside the `gc_pauses.cr` hook, to cross-check pause counts.
  Its heap size read assumes the 8.x `GC_arrays` layout, which the fork changed: ignore its
  `heap_kb` for `acton*`.

## Not covered

Incremental and generational modes (the fork's manual write barrier, sliced marking): Crystal
doesn't enable them. Heap sizing by memory limit and the allocation budget: measured in
`results-acton` at 20k msg/s, no gain worth it. Efficiency cores: this VM has none. aarch64.

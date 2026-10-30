# Finalizers and collection frequency on upstream main, connection churn only

Connection churn as the only load: `PERF=0 FLAP=0 run_broker.sh <variant> churn 240` (20k idle
queues, 2,000 pooled connections, 200 reconnects/s, a fifth of the pool publishing now and then),
bundled libgc 8.2.8, default markers. 5 rounds, variants interleaved and rotated per round.

## Setup

- VM: 4 vCPU Intel Xeon @ 2.80GHz (KVM/Firecracker), kernel 6.18.44; `facts.txt` has `lscpu`.
- Crystal 1.21.0 (LLVM 20.1.8); every broker links Crystal's bundled `libgc.a`; `GC_get_version()`
  of a program linked the same way (`gcver.cr`) reports 8.2.8.
- CPU steal (`r*/vmstat.txt`, `vmstat 1 5` before each round): 0-1%.
- Brokers built as in `setup.sh` (hook `zz_gc_pauses.cr` + `zz_typetable.cr` + `zz_bench.cr`,
  `--release`), from upstream `baaa3ea` (main) and `142910d` (PR 2584, digest without finalizer);
  `build_all.sh` is the exact build. The hook compiled against main unchanged.
- `+socket` variants also require `zz_socket_unregister.cr` (the colleague's snippet plus an
  `Atomic(UInt64)` counter written to `gc.pauses.unregs` each second and an `at_exit` line in
  `broker.log`) before `./lavinmq`.
- `digest-socket-1k` is the `digest-socket` binary with `GC_BYTES_PER_FINALIZER=1000`.

Variants: `main` (baaa3ea), `main-socket` (+ snippet), `digest` (142910d), `digest-socket`
(+ snippet), `digest-socket-1k` (+ 1 KB per-finalizer weight).

## Method and files

- `plan.sh` ran rounds 1-3, `plan-r4-5.sh` rounds 4-5. The only difference: `ss` is not
  installed, so plan.sh's "wait until 5672/15672 are free" loop was a no-op in rounds 1-3 (the
  `pkill` / `pkill -9` before each run still ran, and no run shows a startup problem);
  plan-r4-5.sh checks `/proc/net/tcp` instead.
- `summary.txt`: `summarize.py` line per run. `analyze.py` -> `runs.jsonl` (via `collect.sh`)
  -> `tables.py` -> `tables.md` (the tables below). Raw per-run files in `r<round>/<variant>/`.
- All metrics are over the driver's 240 s measurement window (`measure_start`..`measure_end`).
  "2nd half" is the last 120 s of it. RSS med is the median of the last 240 one-second samples.
- Trigger path: the hook records a backtrace at each collection start (`gc.pauses.traces`, one
  per line in `gc.pauses`, so they pair by index). Frames are symbolized with `nm` and the PIE base
  from `gc.pauses.maps`; each collection is labelled by its innermost libgc caller:
  `GC_grow_table` (finalizer hash table full, called from `GC_register_finalizer_inner`) or
  `GC_collect_or_expand` (allocation slow path; `GC_allocobj`/`GC_alloc_large`). No collection
  had another path (non-incremental mode never goes through `GC_collect_a_little_inner`).
  The traces cannot tell which clause inside `GC_collect_or_expand` fired (finalizer term vs
  `GC_should_collect()`).

## Per-variant medians (5 runs each)

| variant | runs | gcs/min | gcs/min 2nd half | p50 ms | max ms | GC ms/min | GC ms/min 2nd half | RSS med MB | TCPSocket reg/s | Digest reg/s | socket unreg/s | collections via grow_table / collect_or_expand (all runs) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| main | 5 | 4.5 | 2.5 | 235.9 | 308.6 | 1096 | 618.2 | 623 | 200.8 | 200.8 | - | 68 (73%) / 25 (27%) |
| main-socket | 5 | 6.75 | 7 | 231.8 | 296.7 | 1590.6 | 1646.3 | 556 | 200.9 | 200.9 | 200.9 | 135 (100%) / 0 (0%) |
| digest | 5 | 3.25 | 2.5 | 233.4 | 284.2 | 789.8 | 615.4 | 623 | 200.7 | 0 | - | 25 (38%) / 40 (62%) |
| digest-socket | 5 | 2.5 | 2.5 | 240.8 | 300.9 | 605.5 | 620.8 | 623 | 200.7 | 0 | 200.7 | 0 (0%) / 50 (100%) |
| digest-socket-1k | 5 | 2.5 | 2.5 | 242.2 | 319.1 | 619.1 | 662.1 | 625 | 200.8 | 0 | 201.0 | 0 (0%) / 50 (100%) |

## Per run

| run | gcs/min | gcs/min 2nd half | p50 | p90 | max ms | GC ms/min | GC ms/min 2nd half | RSS med / peak MB | alloc MiB/s | finalizer registrations/s | socket unreg/s | trigger (whole window) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| r1/main | 4.5 | 2.5 | 247.1 | 327.1 | 331.7 | 1096 | 709.3 | 624 / 631 | 4.28 | TCPSocket 200.8, OpenSSL::Digest 200.8, File 4.8 | - | grow_table 13, collect_or_expand 5 |
| r2/main | 4.5 | 2.5 | 231.6 | 262.3 | 267.8 | 1043.9 | 590.9 | 624 / 632 | 4.28 | TCPSocket 200.7, OpenSSL::Digest 200.7, File 4.8 | - | grow_table 13, collect_or_expand 5 |
| r3/main | 5 | 2.5 | 235.9 | 290.5 | 333.3 | 1207.7 | 650.3 | 623 / 632 | 4.28 | TCPSocket 201, OpenSSL::Digest 201, File 4.8 | - | grow_table 15, collect_or_expand 5 |
| r4/main | 4.75 | 2.5 | 246.5 | 291.1 | 294.8 | 1150.6 | 612.5 | 621 / 631 | 4.28 | TCPSocket 200.8, OpenSSL::Digest 200.8, File 4.8 | - | grow_table 14, collect_or_expand 5 |
| r5/main | 4.5 | 2.5 | 223.1 | 276.4 | 308.6 | 988.6 | 618.2 | 622 / 630 | 4.28 | TCPSocket 201.2, OpenSSL::Digest 201.2, File 4.8 | - | grow_table 13, collect_or_expand 5 |
| r1/main-socket | 6.75 | 7 | 224.3 | 268.1 | 294.9 | 1577.4 | 1639.8 | 556 / 562 | 4.28 | TCPSocket 200.9, OpenSSL::Digest 200.9, File 4.8 | 200.9 | grow_table 27 |
| r2/main-socket | 6.75 | 7 | 239.2 | 275.2 | 291 | 1637.9 | 1692.2 | 556 / 562 | 4.28 | TCPSocket 200.9, OpenSSL::Digest 200.9, File 4.8 | 200.9 | grow_table 27 |
| r3/main-socket | 6.75 | 7 | 231.8 | 262.6 | 301.1 | 1596.1 | 1646.3 | 557 / 563 | 4.28 | TCPSocket 200.9, OpenSSL::Digest 200.9, File 4.8 | 200.9 | grow_table 27 |
| r4/main-socket | 6.75 | 7 | 221.4 | 250.2 | 359 | 1538.3 | 1540.8 | 555 / 560 | 4.28 | TCPSocket 200.8, OpenSSL::Digest 200.8, File 4.8 | 200.8 | grow_table 27 |
| r5/main-socket | 6.75 | 7 | 243.5 | 282.2 | 296.7 | 1590.6 | 1670 | 555 / 561 | 4.27 | TCPSocket 200.6, OpenSSL::Digest 200.6, File 4.8 | 200.6 | grow_table 27 |
| r1/digest | 3.25 | 2.5 | 252.6 | 309.9 | 318.5 | 830.2 | 674.4 | 623 / 640 | 4.26 | TCPSocket 200.9, File 4.8 | - | collect_or_expand 8, grow_table 5 |
| r2/digest | 3.25 | 2.5 | 232 | 278.7 | 312.7 | 794.7 | 671.1 | 623 / 641 | 4.26 | TCPSocket 200.7, File 4.8 | - | collect_or_expand 8, grow_table 5 |
| r3/digest | 3.25 | 2.5 | 239.5 | 283.6 | 284.2 | 789.8 | 613.1 | 623 / 640 | 4.26 | TCPSocket 200.7, File 4.8 | - | collect_or_expand 8, grow_table 5 |
| r4/digest | 3.25 | 2.5 | 233.4 | 264.6 | 267.8 | 750.2 | 602.9 | 622 / 639 | 4.26 | TCPSocket 200.7, File 4.8 | - | collect_or_expand 8, grow_table 5 |
| r5/digest | 3.25 | 2.5 | 229 | 258.2 | 271.3 | 762.7 | 615.4 | 622 / 639 | 4.26 | TCPSocket 200.8, File 4.8 | - | collect_or_expand 8, grow_table 5 |
| r1/digest-socket | 2.5 | 2.5 | 265.4 | 323.8 | 323.8 | 671.1 | 730.6 | 623 / 640 | 4.25 | TCPSocket 200.5, File 4.8 | 200.5 | collect_or_expand 10 |
| r2/digest-socket | 2.5 | 2.5 | 260.7 | 394.3 | 394.3 | 674.2 | 675.3 | 623 / 640 | 4.26 | TCPSocket 200.8, File 4.8 | 200.8 | collect_or_expand 10 |
| r3/digest-socket | 2.5 | 2.5 | 215.5 | 259.6 | 259.6 | 561.6 | 553.6 | 623 / 640 | 4.26 | TCPSocket 200.7, File 4.8 | 200.7 | collect_or_expand 10 |
| r4/digest-socket | 2.5 | 2.5 | 235.5 | 300.9 | 300.9 | 605.5 | 614.4 | 623 / 640 | 4.26 | TCPSocket 200.9, File 4.8 | 200.9 | collect_or_expand 10 |
| r5/digest-socket | 2.5 | 2.5 | 240.8 | 273 | 273 | 583.7 | 620.8 | 622 / 639 | 4.26 | TCPSocket 200.7, File 4.8 | 200.7 | collect_or_expand 10 |
| r1/digest-socket-1k | 2.5 | 2.5 | 267.5 | 312.8 | 312.8 | 677.1 | 664.3 | 625 / 642 | 4.26 | TCPSocket 200.7, File 4.8 | 201.0 | collect_or_expand 10 |
| r2/digest-socket-1k | 2.5 | 2.5 | 235.2 | 298.8 | 298.8 | 580.8 | 588.5 | 625 / 642 | 4.27 | TCPSocket 201.1, File 4.8 | 201.1 | collect_or_expand 10 |
| r3/digest-socket-1k | 2.5 | 2.5 | 291.7 | 319.1 | 319.1 | 696.1 | 708.9 | 625 / 642 | 4.26 | TCPSocket 200.8, File 4.8 | 200.8 | collect_or_expand 10 |
| r4/digest-socket-1k | 2.5 | 2.5 | 242.2 | 328.8 | 328.8 | 607.4 | 612 | 623 / 640 | 4.25 | TCPSocket 200.5, File 4.8 | 200.5 | collect_or_expand 10 |
| r5/digest-socket-1k | 2.5 | 2.5 | 241 | 331.9 | 331.9 | 619.1 | 662.1 | 623 / 640 | 4.26 | TCPSocket 201, File 4.8 | 201.0 | collect_or_expand 10 |

(p90 equals max for runs with 10 collections in the window. File finalizers are the broker's own
4.8/s in every variant.)

## Conclusions

- The finalizer cost on main is not `GC_collect_or_expand`'s per-finalizer weight but
  `GC_grow_table`: whenever live finalizer entries exceed the table size, bdwgc forces a full
  collection and only grows the table if >= 80% of entries survive it. On `main` 73% of
  collections came that way; the weight term cannot fire here at all, since 400 registrations/s
  x 10 KB = 4.0 MB/s is below the real 4.5 MB/s (4.28 MiB/s) allocation rate, which is why
  `digest-socket-1k` changes nothing.
- `digest` vs `main`: collections 4.5 -> 3.25/min (-28%), GC time 1096 -> 790 ms/min (-28%).
  All of the gain is in the first ~2 minutes while the table grows; in the 2nd half both run at
  2.5/min (~22.5 s cadence, about 100 MB allocated per cycle) and ~615 ms/min.
- The socket snippet alone makes main worse: 6.75/min, 1591 ms/min (+45%), every collection via
  `GC_grow_table`, at a fixed ~9 s cadence. Unregistering keeps live entries just under 80% of the
  table after each collection, so the table never grows while the 200 digests/s refill it
  (inferred: ~2,000 sockets + ~1,800 digests per 9 s = a 4,096-entry table). RSS is 67 MB lower
  (556 vs 623 MB) because of the extra collections.
- `digest-socket` vs `digest`: 3.25 -> 2.5/min (-23%), 790 -> 606 ms/min (-23%); vs `main`
  -44% collections and -45% GC time. It removes every `GC_grow_table` collection; the steady
  state is unchanged (2.5/min in the 2nd half for digest, digest-socket and digest-socket-1k).
- Pause length does not change (median p50 232-242 ms, median max 284-319 ms across variants), and RSS is the
  same (622-625 MB) for all variants except main-socket.
- Order matters: ship the digest fix (PR 2584) first; the socket unregistration only helps on top
  of it and hurts without it.

## Anomalies

- Port-free check no-op in rounds 1-3 (see Method).
- An early `analyze.py` took the finalizer/unregistration snapshot nearest `measure_end`, which
  sometimes fell after the driver closed its 2,000 pooled connections (+8/s unregistrations);
  it now uses the last snapshot inside the window. The `at_exit` line in `broker.log` counts the
  whole broker lifetime (including setup and teardown), so its rate is lower.
- Stats tick max up to 358 ms in `r4/digest-socket-1k` (in `summary.txt`); GC pauses in that run
  are normal, so not GC.
- No steal spikes; no outliers dropped. Run-to-run spread of collections/min is 0-0.5/min.

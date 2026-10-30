# GC pauses and scheduler stalls around a failover: production-like 2-vCPU, many-connection cluster

Question: on a production-like 2-vCPU, 25k-connection cluster leader (LavinMQ 2.10.2) that loses its
etcd lease (10 s TTL, renewed every ~3.3 s from a fiber), can GC pauses or scheduler stalls during a
failover reconnect storm or the steady state after it come near 10 s? What do the GC fixes change,
and how does the simulated heap compare with production's (~5.3 GB within an hour of becoming
leader, 8-11 GB before each lease loss, ~216-450 KB per connection)?

## Setup

- 4-vCPU KVM VM (Xeon @ 2.8 GHz, x86_64; production is Graviton), Crystal 1.21.0, bdwgc 8.2.8
  (`GC_get_version()` 0x80208 in every broker). `system.txt`, `vmstat.txt`.
- Broker pinned to CPUs 0-1 (`taskset -c 0,1`) with `GC_MARKERS=2`: bdwgc sizes its markers from the
  online CPU count, not the affinity mask, so taskset alone gave 4 markers. `lavinmq_gc_marker_threads`
  was 1 (2 markers) in every run, as in production. Load generators ran on CPUs 2-3.
- Variants: `main` (upstream `baaa3ea`, bundled libgc); `combo32k` (`142910d` PR 2584 +
  `zz_socket_unregister.cr`, libgc 8.2.8 + `bdwgc-mark-stack-overflow-global.patch` +
  `-DINITIAL_MARK_STACK_SIZE=32768`); `v2102` (tag v2.10.2, bundled libgc, the production version).
  Built by `setup-sim.sh` with the GC hook.
- Shape: 1,150 queues, 770 consumers (one per connection), one channel per connection, info logging,
  default stats settings, a 15 s Prometheus-like scrape of `/metrics`.
- **Connections: 19,500, not 25,000.** The container's hard `RLIMIT_NOFILE` is 20,000 and it lacks
  `CAP_SYS_RESOURCE`, so the broker can't hold more. Per-connection figures are used for comparison.
- Run (`run_sim.sh`, `plan.sh`): start broker, declare queues, then two drivers (one per CPU) open
  19,500 connections as fast as they can with 500 handshakes in flight and a 10 s handshake timeout
  (**storm**); then 37 reconnects/s and lavinmqperf 830 msg/s (`-x 2 -y 2 -r 415 -s 256`) for 300 s
  (**steady**, measured from 10 s after the storm); then a heap census with all connections open.
- Stall watchdog (in the hook): a fiber looping `sleep 1.second`, recording each wakeup's lateness,
  as the lease keepalive fiber would see it. "Late > 1 s stretch" is the longest run of consecutive
  wakeups each more than 1 s late.
- 3 rounds, variants interleaved, start rotated. Rounds 1-2 lost ~1,000-1,750 idle connections 90 s
  after the storm: every connection's TCP keepalive probe fired at once and overflowed the loopback
  backlog (`netdev_max_backlog` 1000; 139k drops on the driver CPUs, `check-conc50.txt`), a test
  artifact. Round 3 ran with the backlog at 100,000 and held all 19,506 connections. Storm results
  are unaffected, and rounds 1-2 match round 3 otherwise.

## Headline (ranges over 3 rounds; per-run rows in `tables.md`)

| | main | combo32k | v2.10.2 |
|---|---|---|---|
| **Storm** (19,500 connections) | | | |
| Time to open all | 4.9-5.3 s | 3.3-4.7 s | 6.8-7.1 s |
| Collections | 20-22 | 14 | 26-30 |
| GC pause p50 / max | 76-100 / 149-250 ms | 39-53 / 137-179 ms | 89-94 / 250-317 ms |
| GC time total | 1.66-2.11 s | 0.63-0.86 s | 2.48-3.25 s |
| Watchdog max lateness | 0.03-0.18 s | 0.02-0.07 s | 0.09-0.28 s |
| Late > 1 s / > 3 s / > 7 s stretch | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 |
| Handshake p99, timeouts, broker EOF lines | 1.1-1.4 s, 0, 0 | 1.2 s, 0, 0 | 1.3 s, 0, 0 |
| **Steady** (300 s, 37 reconnects/s, 830 msg/s) | | | |
| Collections/min | 0.6-0.8 | 0.8 | 1.2 |
| GC pause p50 / max | 255-310 / 258-335 ms | 155-165 / 171-190 ms | 341-414 / 416-566 ms |
| GC ms/min | 149-227 | 117-120 | 410-455 |
| Watchdog max / p99 lateness | 0.05-0.23 / 0.03-0.07 s | 0.03-0.18 / 0.03-0.05 s | 0.06-0.11 / 0.03-0.05 s |
| Late > 1 s stretch | 0 | 0 | 0 |
| **Heap at ~19,500 connections** | | | |
| GC heap after the storm, 30 s in (diag runs) | 434 MB | 405 MB | 1,234 MB |
| GC heap / RSS after 5 min steady (r3) | 497 / 941 MB | 485 / 983 MB | 1,681 / 1,520 MB |
| Heap per connection, 30 s / 5 min | 22 / 25 KB | 21 / 25 KB | 63 / 86 KB |
| Reachable: scanned + pointer-free (r3) | 97 + 293 MB | 94 + 285 MB | 93 + 1,253 MB |
| Mark stack (GC_PRINT_STATS, storm + 30 s) | 3,579 overflows in 34 collections, stays 4,096 | 10 overflows while it grew 32k -> 262k entries, then none | 3,780 in 43, stays 4,096 |

Handshake p99 of ~1.2 s in every variant is TCP SYN retransmission: the listen backlog (Crystal's
default 128) overflows at 500 handshakes in flight. With 50 in flight it doesn't, and the storm took
5.5 s on main (`check-conc50.txt`).

Census at 5 min (`runs/r3-*/census.txt`), what a connection costs on main: ~14 stats-history
buffers of 1-2 KB (273k pointer-free buffers, matching 271k `Deque(Float64)`: 267 MB, 69% of the
reachable heap), `AMQP::Channel` 1 KB, `TCPSocket`, `Client`, `Fiber`, `AMQ::Protocol::Stream`,
mutexes, ~20 KB in all. Marking scans only ~94 MB at 19,500 connections. v2.10.2 adds two 16 KB
pointer-free socket buffers per connection (610 MB; main has none) and pointer-free memory that
grows with churn (below). The live fiber list shows one fiber per connection ("Accept TCP socket").
Every variant also keeps ~11k dead `Fiber` + `TCPSocket` pairs from 5 minutes of churn
(30.8k of each for 19.5k connections).

## v2.10.2's heap grows with connection churn; main's doesn't

- At 37 reconnects/s v2.10.2's GC heap grew 1.15 -> 1.65 GB in 5 minutes (~100 MB/min, ~46 KB per
  reconnect) in all 3 rounds; main and combo32k grew ~0.1 GB, mostly in the first 2 minutes.
- Removing one load at a time (`growth-check.txt`, 150 s each): without churn the heap ended at
  1.2 GB with 9 MB of `String`; with churn 1.44 GB and 195 MB of `String`, with or without
  lavinmqperf and with or without the scrapes. Churn alone drives it. The growth is pointer-free
  memory (census attribution of pointer-free blocks by header is approximate). The cause is not
  identified; the next step is a bisect of v2.10.2..baaa3ea (48 commits) with the 150 s churn run.
- At 300 reconnects/s (`bigheap.sh`) the heap levelled off at 3.4 GB after ~8 minutes (2.5 GB
  reachable, still only 114 MB scanned). This growth is not unbounded at that rate. Where it levels
  off at 37/s over hours is not measured.

## Pauses at a larger heap (v2.10.2, 300 reconnects/s for 600 s, `runs/bigheap-*`)

| Heap | bundled libgc: GCs, pause p50 / max | patched + 32k stack: GCs, pause p50 / max |
|---|---|---|
| 1-2 GB | 7, 428 / 559 ms | 7, 210 / 234 ms |
| 2-3 GB | 9, 635 / 839 ms | 10, 328 / 389 ms |
| 3-3.4 GB | 21, 751 / 910 ms | 21, 382 / 468 ms |
| Watchdog max / p99 lateness over the 600 s | 0.67 / 0.41 s | 0.38 / 0.23 s |
| Late > 1 s stretch | 0 | 0 |

Pause time grows with heap size even though scanned bytes stay ~110 MB: ~160 ms per GB with bundled
libgc and ~85 ms per GB with the patch. A straight-line extrapolation (unmeasured) to production's
8-11 GB gives ~1.5-2 s pauses on bundled libgc and under 1 s with the patch.

## Unpaged list polling (`runs/poll-*`)

Same shape (19,506 connections, 37 reconnects/s, 830 msg/s) plus a poller: two unpaged
`GET /api/connections` 5 s apart every 60 s, as production's "Result set truncated: 10000/36500"
suggests. 20 minutes per variant after the storm (`poll_plan.sh`, `per_minute.py`; per-minute
tables in `runs/poll-*/per-minute.md`).

| 20 min steady | v2.10.2 | v2.10.4 | combo32k (main) |
|---|---|---|---|
| GC heap start -> end | 1.28 -> 2.98 GB | 1.28 -> 3.07 GB | 0.45 -> 0.53 GB |
| Collections, pause p50 / max | 15, 576 / 1,085 ms | 16, 561 / 1,116 ms | 17, 199 / 280 ms |
| Watchdog max lateness | 0.60 s | 1.12 s | 0.21 s |
| Poll latency p50 / max | 144 / 925 ms | 110 / 770 ms | 113 / 386 ms |
| Anything over 7 s | no | no | no |

- At this size unpaged polling is not what grows the heap: v2.10.4 (with #2452) grows exactly like
  v2.10.2, at the churn rate. Pauses grow with the heap and reach ~1.1 s after 20 minutes.
- Pistvakt (labs.duh.se/lavinmq-performance, 1,000 connections) agrees on the cost per request:
  unpaged `/api/connections` allocates 2.12 MB on 2.9.0-2.10.3 and 0.92 MB on 2.10.4/main (~2.1 KB
  per item on 2.10.2, ~77 MB per request at production's 36.5k items). It also shows 56 KB RSS per
  idle connection on 2.10.x vs 34 KB on main (#2343).
- A second round was cut short: the v2.10.4 rerun lost its load drivers at minute 6 (excluded), and
  the `/api/channels` run didn't happen.

## What fixed the churn growth on main: #2343

Bisect probe (`churn_probe.sh`, storm + 150 s churn, no message load; `bisect.txt`): the parent of
#2343 (socket buffer pooling, on main only, not in any 2.10.x) grows 113 MB/min, #2343 28 MB/min.
With pooled buffers a retained closed socket no longer holds its 2 x 16 KB buffers.

## Closed connections stay reachable (`runs/leak-*`)

16 minutes of churn at 19,506 connections with a census every minute (`leak_probe.sh`,
`leak_table.py`). The census now also finds what holds closed `TCPSocket`s and dead `Fiber`s
(interior pointers included) and follows headerless holders upwards (`../gc_pauses.cr`,
`GC_CENSUS_HOLDERS=1`). Live fibers stayed at ~19,533 in every run (one "Accept TCP socket" read
loop per connection), so nothing is stuck. At minute 16:

| Variant | Closed sockets reachable | Dead fibers reachable | GC heap |
|---|---|---|---|
| main | 33,460, +1.9k/min | 28,285 | 497 MB |
| main + `zz_fiber_drop_proc.cr` | 4,561, flat after ~9 min | 28,382 | 480 MB |
| main + `zz_socket_unregister.cr` | 28,741 | 28,607 | 497 MB |
| main + both | 672, flat from minute 5 | 28,651 | 481 MB |
| v2.10.2 | 33,100 | 28,222 | 2,545 MB |
| v2.10.2 + `zz_socket_unregister.cr` | 29,719 | 28,669 | 2,449 MB |
| v2.10.2 + both | 5,691, flat from minute 11 | 28,804 | 1,569 MB, flat from minute 13 (v2.10.2: 2,609 MB and climbing) |

- Dead read-loop fibers stay reachable: no heap object holds them; live read-loop fibers' stacks
  do, through interior pointers 40 and 96 bytes from the stack bottom (the frames a fiber starts
  in), so each new fiber appears to pin the fiber that first switched to it. They keep piling up
  in every variant (2.2k/min early, 1.2k/min at 16 minutes). Zeroing reused stacks
  (`zz_clear_reused_stacks.cr`) changed nothing. This is in Crystal's fiber start-up, not fixed here.
- Two leaks hang off that. (1) Crystal's `Fiber#run` never clears `@proc`, so a dead fiber keeps
  its closure and the closure the client socket: `zz_fiber_drop_proc.cr` clears it when the fiber
  ends (~29k sockets fewer). (2) A closed `TCPSocket` that reaches itself through another object
  (a 64-127 B headerless object) is never finalized, as `GC_register_finalizer_ignore_self` ignores
  only direct self-pointers, so it is never freed: dropping the finalizer on close
  (`zz_socket_unregister.cr`, PR 2585) removes the last ~4k. Alone it barely helps, since the dead
  fibers' closures still hold almost all sockets (consistent with the earlier combo32k runs).
- On main the leaked sockets cost little (~17 MB here) because #2343 pools their buffers. On 2.10.x
  each keeps its buffers: that is the ~46 KB per reconnect and the multi-GB leader heap.

## Conclusions

Added after the polling and retention runs:

- Unpaged `/api/connections` polling at 19,500 connections doesn't stall the broker or drive the
  heap on 2.10.2, and 2.10.4 behaves the same. The 2.10.x leader heap grows from connection churn:
  every closed connection's socket stays reachable, and with its buffers costs ~46 KB.
- Two fixes stop it: clear a finished fiber's proc (`zz_fiber_drop_proc.cr`, a Crystal stdlib
  issue) and drop the socket's finalizer on close (`zz_socket_unregister.cr`, PR 2585). On v2.10.2
  both together level the heap off at 1.57 GB instead of 2.6 GB and climbing after 16 minutes. On
  main, #2343 already hides most of the cost.
- Dead fibers still pile up (~200 B each, ~6 MB at 28k after 16 minutes), pinned from live fibers'
  entry frames. That needs a Crystal-side look.

Earlier conclusions (GC pauses and stalls):

- In this shape GC does not explain lease expiry. No watchdog wakeup was more than 0.3 s late at
  19,500 connections, during the storm or after it, on any variant. At a 3.4 GB heap the worst was
  0.67 s. Even extrapolated to 11 GB, single pauses stay around 2 s, far from a 7-10 s gap.
- The fixes roughly halve GC time: storm GC total 1.7-2.1 s -> 0.6-0.9 s, steady pause p50
  255-310 -> 155-165 ms, and at a large heap 751 -> 382 ms. The mark stack stops overflowing on
  every collection (3,579 -> 10 overflows). They don't change the answer on lease expiry, because
  nothing measured was close.
- The simulation can't reproduce production's heap on main (22-25 KB per connection vs 216-450 KB).
  It partly can on v2.10.2, whose heap grows ~46 KB per reconnect under churn. That is the likely
  source of production's multi-GB leader heap, and main doesn't have it. So the conclusion holds
  for heaps up to 3.4 GB measured and ~11 GB extrapolated; it is not a measurement at production's
  heap.
- Production's 2-3 minute scrape gaps and the burst of handshake EOFs were not reproduced. Scrapes
  took at most 361 ms, and there were no handshake timeouts or EOF lines, with or without a big heap.
  Something other than GC pauses stalls the production leader for minutes. Untested candidates:
  memory pressure from an 8-11 GB heap plus page cache on a 16 GB host, CPU steal or credit
  throttling, or blocking I/O.

## Files

- `setup-sim.sh`, `run_sim.sh`, `plan.sh`, `summarize_sim.py`, `tables.py` -> `summary.txt`,
  `tables.md`; `check_conc.sh` -> `check-conc50.txt`; `growth_check.sh` -> `growth-check.txt`;
  `bigheap.sh` -> `bigheap.txt` (the v2.10.2 brokers there and in `runs/growth-fibers` were rebuilt
  with the hook's fiber census; `v2102g` is v2.10.2 against the patched libgc).
- `runs/<run>/`: `gc.pauses` (end ns, pause ns, stop-world ns, mark ns), `gc.pauses.watchdog` (wakeup
  ns, lateness ns), `phases.txt` (monotonic ns), `scrapes.txt` (start ns, ms, curl rc, GC heap bytes,
  connections), `rss.txt` (ns, RSS kB, fds), `census.txt`, driver/perf/broker logs, `markers.txt`,
  `gc_version.txt`. `diag-*` ran with `GC_PRINT_STATS=1` (`mark-stack.txt`).
- Polling and retention: `poll_plan.sh`, `per_minute.py`, `poll-summary.txt`; `churn_probe.sh`,
  `bisect.txt`; `leak_probe.sh`, `leak_table.py`; candidate fixes `zz_fiber_drop_proc.cr`,
  `zz_socket_unregister.cr`, `zz_clear_reused_stacks.cr` (no effect).
- Hook and driver changes: `../gc_pauses.cr` (watchdog, version, fiber census, holder scan), `../driver.cr`
  (`storm` and `declare` modes, `CHURN_RATE`, `CONC`, `HS_TIMEOUT`, `CONSUMERS`, `POOL_PUB`).

# Handover: LavinMQ GC pauses and collection frequency

Owner: Johan (johan@duh.se). Written 2026-10-30. Scope: Boehm GC (bdwgc) behaviour in LavinMQ on
upstream main (cloudamqp/lavinmq). The stats-history work (PR #2453, branch `gc-heap-stats`) is
out of scope and can wait. The password digest fix is being handled separately by Johan.

## TL;DR

1. Parallel marking breaks down with many fibers. Crystal pushes every parked fiber's stack as a
   GC root. With a few thousand fibers that overflows bdwgc's 4,096-entry mark stack, and in
   parallel mode bdwgc never grows it, so every collection overflows and falls back to a slow heap
   rescan. Pauses are about 2x longer than with one marker and 3-4x longer than with the fix. A
   one-line bdwgc patch fixes it; Acton's bdwgc fork fixes it better. Neither is upstream.
2. Finalizers make Boehm collect too often. In its "collect or grow the heap?" decision, each newly
   registered finalizable object counts as 10 KB of allocation. Each AMQP connection registers two
   (its socket and, today, a password `OpenSSL::Digest`), so connection churn triggers about 3x
   more collections than its real allocation would.

Everything below is measured on a 4-vCPU cloud VM (Firecracker, shared host, some CPU steal) with
the load generators on the same machine. Treat effect sizes as indicative; directions held in every
repeat.

## 1. Parallel marking and the mark stack

### Mechanism

- A collection is: stop the world (0.1-0.3 ms), push roots, mark everything reachable, resume.
  Marking is ~95% of the pause. The mark stack is the list of found-but-not-yet-scanned objects.
- Crystal pushes every parked fiber's used stack as a root with `GC_push_all_eager`, which scans
  each stack immediately and pushes every object it finds. LavinMQ has thousands of parked fibers
  (about 3 per connection; idle queues stop theirs).
- On overflow bdwgc drops entries, marks the state invalid and recovers by rescanning the heap. It
  normally also flags the stack to double. In parallel mode it skips that flag, assuming the
  overflow was a helper thread's local stack. Root pushing uses the global stack, so the global
  stack never grows and overflows on every collection.
- With `GC_MARKERS=1` the flag is set, the stack grows once (to 32,768 entries in the broker) and
  the problem disappears, but marking is single-threaded.

### Code

- Faulty condition `if (!GC_parallel) GC_mark_stack_too_small = TRUE;`:
  https://github.com/bdwgc/bdwgc/blob/v8.2.8/mark.c#L484-L498 (unchanged in master:
  https://github.com/bdwgc/bdwgc/blob/fd3e9873c0674d356a44ac5eeb59d7f4936d5d86/mark.c#L690-L700)
- Introduced by https://github.com/bdwgc/bdwgc/commit/60cbd25851cf8343f504ffb56fd847483bd20322
  (2013, from bdwgc PR #31). Its message says the intent was "only set GC_mark_stack_too_small if
  we are using the global mark stack"; the code checks parallel mode instead.
- 4,096-entry initial size: https://github.com/bdwgc/bdwgc/blob/v8.2.8/mark.c#L69
- Crystal side: https://github.com/crystal-lang/crystal/blob/1.21.0/src/gc/boehm.cr#L227-L229
  (every parked fiber), https://github.com/crystal-lang/crystal/blob/1.21.0/src/fiber.cr#L384-L387,
  https://github.com/crystal-lang/crystal/blob/1.21.0/src/gc/boehm.cr#L482-L483

### Evidence

Test program `extras/gc-bench/mark.cr` (120 MB heap of 1,000 independent lists; parallel marking
should give ~4x), collect p50:

| libgc | no fibers, 4 markers | 6,500 fibers, 1 / 4 markers | 30,000 fibers, 1 / 4 markers |
|---|---|---|---|
| Crystal's bundled 8.2.8 | 51-88 ms | 238-336 / 274-372 ms | 247-337 / 300-390 ms |
| 8.2.8 + narrow patch | 46-81 ms | 223-290 / 55-85 ms | 236-324 / 66-94 ms |
| Acton fork 2b99b72 | 52 ms | 224 / 50 ms | 238 / 62 ms |

(Ranges span three VMs and sessions; machine speed drifted 20-40% between them, so compare within
a row.)

Broker (20k queues, 2,000 connections), pause p50 / max:

| Load | Bundled, default (4) markers | Bundled, 1 marker | Patched, 4 markers | Acton fork, 4 markers |
|---|---|---|---|---|
| Idle, forced GC every 3 s | 92-107 / 117-151 ms | 46-61 / 102-115 ms | 21-24 / 109-153 ms | 21-22 / 27-46 ms |
| Full load (churn 200/s, flapping queues, 20k msg/s) | not run | 53-87 / 84-161 ms | 27-34 / 86-144 ms | 32-35 / 38-45 ms |

- The patched build's max is three collections (96-152 ms) right after the connections open,
  while its stack doubles 4,096 -> 32,768. Over 15 minutes it then never overflowed again.
- The Acton fork moves the full stack into a larger one mid-collection, so it has no such
  collections; that is also why its GC time per minute is ~35% lower in short runs.
- One 511 ms pause in one Acton run, every phase inflated (227 ms stop-the-world). Likely VM CPU
  steal, not proven; 4 more fork runs were clean.
- Important: these broker runs used the `gc-heap-stats` branch plus the digest fix as the base,
  not main. On main the GC heap is bigger (see section 3) so absolute pauses will be longer; the
  mark stack bug is the same.

Pause scaling (extrapolation): pause ~= serial root scan (~0.3-0.6 us per parked fiber) + marking
of the pointer-containing heap (~2.2 GB/s with 1 marker, ~5 GB/s with 4 patched markers). At 100k
connections plus 20k queues (~300k fibers, ~490 MB scanned) that is roughly 200-280 ms with the
patch and 4 markers and ~300+ ms on bundled libgc; the fiber root scan becomes the floor.

### Fixes

- Narrow patch (the one to ship/propose): `extras/gc-bench/bdwgc-mark-stack-overflow-global.patch`.
  Sets the flag when the overflowing stack is the global one
  (`msp` in `[GC_mark_stack, GC_mark_stack_limit]`; `msp` is one past the end at overflow, hence
  `<=`). A broader variant that always sets it is `bdwgc-mark-stack-overflow.patch`; they performed
  the same.
- Validation done (branch `gc-bench-results-patch`, `extras/gc-bench/results-patch/RESULTS.md`):
  bdwgc `make check` 16/16 on stock and both patches (those tests never reach the patched path);
  a C reproducer `overflow_test.c` (200,000 roots via `GC_push_other_roots` +
  `GC_push_all_eager`, verifying every object for 100 collections) reproduces the bug on stock
  (105/106 collections overflow) and shows 0 corrupted objects on all builds with 1, 2 and 4
  markers; 260 collections at 30,000 fibers: stack grows 3 times then never again.
- Initial stack size: a 262,144-entry initial stack (`-DINITIAL_MARK_STACK_SIZE=262144`) avoids the
  growth collections, but above 8x a helper's local stack (32,768 entries) a local overflow can
  write below the local stack array (Acton fixed this in
  https://github.com/actonlang/bdwgc/commit/3f6201b6a3a786f729be8d551c5749a4fb2b200c). Recommended:
  the narrow patch plus `-DINITIAL_MARK_STACK_SIZE=32768`. That exact combination is NOT measured
  yet; measure it before shipping.
- Acton's fork (https://github.com/actonlang/bdwgc, Kristian Larsson, an upstream contributor):
  https://github.com/actonlang/bdwgc/commit/752a6275b32855f67326f74580a13a2adbcd5242 fixes this
  bug, https://github.com/actonlang/bdwgc/commit/2b99b72c85ac89f580dc7353e078290f83e8b065 grows
  without dropping entries. It is based on bdwgc master (8.3 dev), not 8.2.8. Crystal 1.21 links
  and runs against it unchanged; its `make check` passes 38/38. Results on branch
  `gc-bench-results-acton`. Acton now pins a newer commit `b5c707b9` (not measured). Other fork
  commits worth knowing: `9612707` (objects reachable from finalizable objects can be freed after
  an overflow during finalization marking), `bfc5e05`/`8ee362a` (thread-local allocation reclaim
  bugs), `843bb7e` (prefetch only scanned objects), `b51001b` (fewer markers for small phases),
  `9b7544f`/`b17b72f` (cheaper thread-local allocation), `c829d6e` (heap growth divisor).
- `GC_MARKERS=1` is a stopgap only, not a default: it halved pauses with many fibers, but on
  deployments with few connections and large heaps parallel marking still works (~4x) and one
  marker would be slower. Not measured on a few-connections setup.

### How a fix ships

| Channel | libgc comes from | Fix path |
|---|---|---|
| Deb, RPM, Docker, static build | Statically linked from the `84codes/crystal` build images (`ldd` shows no libgc) | Build a patched libgc in those images (or in LavinMQ's packaging Dockerfiles with `CRYSTAL_LIBRARY_PATH`) |
| Homebrew | Homebrew's `bdw-gc` formula, loaded at runtime (not verified on a Mac) | Upstream bdwgc fix, then the formula; meanwhile `GC_MARKERS=1` in the formula's service block |
| Source builds | Whatever Crystal links | Upstream fix |

macOS behaviour is unverified; the CI workflow already installs Crystal via Homebrew on macOS
(`.github/workflows/ci.yml` lines 111-117), so running `mark.cr` there would answer it.

### Upstream status

- Nobody has reported the parallel-mode case. Closest: bdwgc issue
  https://github.com/bdwgc/bdwgc/issues/997 (opened 2026-10-29 by the ECL maintainer:
  `GC_push_other_roots` overflowing the mark stack on single-threaded builds; ivmai agreed on
  unifying stack scanning). Upstream commit `6ed9d86` (Feb 2026) made `GC_push_all` signal
  instead of abort on overflow.
- No Crystal issue found about `GC_MARKERS` or parallel marking with fibers.
- Suggested: a bdwgc issue with `overflow_test.c`, the narrow patch, the 60cbd258 history, links to
  #997 and Acton's commits (coordinate with Kristian Larsson); a short note to crystal-lang
  (affects every Crystal program with many fibers; Crystal's bundled libgc could carry the fix).
  Nothing has been posted.

## 2. Finalizers and collection frequency

- Rule: bdwgc 8.2.8 `GC_collect_or_expand`
  https://github.com/bdwgc/bdwgc/blob/v8.2.8/alloc.c#L1668-L1683 collects instead of growing the
  heap when (finalizers registered since last GC) x `GC_allocd_bytes_per_finalizer` (default
  10,000) > bytes allocated since last GC.
- Per AMQP connection: one `TCPSocket` finalizer (stdlib
  https://github.com/crystal-lang/crystal/blob/1.21.0/src/socket.cr#L560, unavoidable) and one
  `OpenSSL::Digest` from the password check (Johan is fixing that one; an alternative fix exists on
  branch `password-digest-without-finalizer`). TLS connections add an `OpenSSL::SSL::Socket`.
  Counted with a hook on `GC.add_finalizer`: exactly those two types, ~202/s each at 200
  reconnects/s.
- Measured on the gc-heap-stats base, full load: removing the digest finalizer took collections
  from ~10 to ~3.5 per minute and GC time down ~63%; lowering the weight to 1 KB
  (`GC_set_allocd_bytes_per_finalizer(1000)` at startup) alone gave ~4.6/min. With churn only (no
  other traffic) the digest effect was lost in noise. Re-measure on main.
- The weight is settable at runtime from LavinMQ (no env var needed); it would cover the socket and
  TLS finalizers too. Fewer collections cost some RSS (~40 MB at 20k queues).

## 3. Heap composition on main (live census)

Census of every reachable object by type, 2 minutes into full load, 20k queues + 2,000 connections
(`extras/gc-bench/results/census-main.txt`):

- main: 408 MB reachable, 100 MB scanned by marking, 308 MB pointer-free, 524 MB GC heap. 290 MB of
  the pointer-free part is stats history (268k `Deque(Float64)` + 40k `Deque(UInt32)` buffers):
  costs RSS, not pause time, and acts as ballast that makes Boehm collect less often.
- Main under full load, bundled libgc, default markers: 5-6 collections/min, pause p50 138-140 ms,
  max 162-171 ms, 735-838 ms GC per minute, RSS ~610 MB.
- What marking scans, ~4.4 KB per queue: `Queue` objects 1 KB each (about half inline stats
  counters), 3 `BoolChannel`s per queue (each 2 `StateChannel` + 2 `EndlessQueue` + a mutex; 124k
  `StateChannel` 7.6 MB, 124k `EndlessQueue` 5.7 MB), 167k `Sync::Mutex` 7.7 MB, message store
  objects and per-queue hashes. Connections ~4 KB each.
- Ideas, smaller wins: make `BoolChannel`'s channels lazily (branch `lazy-bool-channel`, based on
  upstream main, full suite passes; scanned memory -12%, pauses -5-8%, measured on the GC branch);
  fewer mutexes per queue; fewer parked fibers per connection (they are both roots and what
  overflows the stack).

## 4. Monitoring

- PR https://github.com/cloudamqp/lavinmq/pull/2565 adds `lavinmq_gc_pause_seconds` (histogram,
  PRE_STOP_WORLD -> POST_START_WORLD). Right metric; its class vars are initialized eagerly (checked
  in LLVM IR), so the callback is safe. Suggest adding 0.075 and 0.15 buckets (observed pauses
  cluster at ~27, ~53 and ~90-140 ms). Naming note: #2529 asked for `_total`; the histogram name is
  correct per Prometheus conventions (`_sum` gives the total).
- Worth adding: a parked-fiber count gauge (the pause driver). Existing `lavinmq_gc_cycles_total`
  gives collection frequency.

## 5. Suggested order of work

1. Measure on upstream main with bundled libgc vs narrow patch + 32,768 initial stack (idle forced
   GC and full load, 2+ runs each), so the numbers in any PR are main's.
2. Get the patched libgc into the `84codes/crystal` images (needs that repo's owners), with the
   evidence above.
3. File the bdwgc issue (reproducer + patch), note to crystal-lang. Get Johan's go-ahead first.
4. Merge #2565 (with the extra buckets) so production shows the effect; add a fiber gauge.
5. Digest/finalizer work (Johan) and, optionally, `GC_set_allocd_bytes_per_finalizer` for TLS churn.
6. Later: lazy `BoolChannel`, fewer per-queue mutexes, Acton fork once upstream.

## Where everything is (jage/lavinmq)

- `gc-bench-tools`: `extras/gc-bench/` with README, `setup.sh` (fresh VM: Crystal 1.21, libgc
  variants, driver, lavinmqperf, brokers with the GC hook; ~20 min), `build-libgc.sh` (stock,
  broad, global, bigstack), both patches, `gc_pauses.cr` (hook: pause and phase times, allocation
  rate, finalizers by type, GC trigger stack traces, live heap census on request),
  `driver.cr` (20k flapping queues, churn/flood), `run_broker.sh`, `run_broker_forcegc.sh`,
  `summarize.py`, `phases.py`, `mark.cr`, `results/` (raw logs, censuses).
  Note `setup.sh` builds brokers from gc-heap-stats + digest; for main, build brokers from main the
  same way (copy `gc_pauses.cr`/`typetable.cr` into `src/` as `zz_*.cr`, build `src/zz_bench.cr`).
- `gc-bench-results-patch`: patch validation (make check, `overflow_test.c`, stress, mark matrix).
- `gc-bench-results-broker`: broker with the narrow patch (idle, full load, 15-minute growth log).
- `gc-bench-results-acton`: Acton fork vs 8.2.8.
- `password-digest-without-finalizer`, `lazy-bool-channel`: ready branches (author identity on the
  digest commit is the container's, not Johan's; recreate before upstreaming).
- Report doc with all tables: https://claude.ai/artifact/HGaPRgTZsU4rEFavr3faNN

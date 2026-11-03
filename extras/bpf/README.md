# bpftrace tools for Crystal fibers and the Boehm GC

Attach to a running LavinMQ, no rebuild, no restart: release builds keep the
symbols these tools probe (`Fiber::swapcontext`, `Fiber::inactive`, libgc's
`GC_stop_world`, ...). Needs root, bpftrace (tested with 0.20.2) and a
kernel with uprobes; x86_64 and aarch64, Crystal 1.21 and 1.22.

```
extras/bpf/lavinmq-bpf <tool> <pid> [threshold_ms]
```

| tool | shows | safe to leave on in production |
|---|---|---|
| `evloop` | per thread, time between event loop polls; prints gaps over the threshold (default 100 ms) with GC overlap and the user stack on CPU | yes |
| `gc` | every collection: total time (allocator lock held), stop-the-world time, heap size, and whether the mark stack overflowed into a heap rescan; summary per interval with heap growth, histograms on exit | yes |
| `fibers` | fibers spawned / finished per fiber name per interval, net change since attach | yes |
| `finalizers` | objects with a finalizer (sockets, files, digests) created / finalized per class per interval, net change alive since attach: what the GC can't free | yes |
| `stalls` | per thread, time between fiber switches; prints gaps over the threshold (default 100 ms) with the fiber that ran and GC overlap, max gap per thread per second | for minutes, see overhead |
| `oncpu` | time each fiber name held its thread, top N per interval | for minutes |
| `sched` | scheduling latency (runnable to running) per fiber name | for minutes |
| `profile` | CPU profile as a flame graph (SVG) and folded stacks | yes (without `FIBERS=1`) |
| `diff` | differential flame graph of two `profile` runs | (offline) |
| `record` | a timeline of fiber runs per thread, idle time, collections and CPU samples, as an HTML report | for minutes, like `oncpu` |
| `report` | the HTML report of one or more recordings or `.folded` profiles, with a comparison of any two | (offline) |
| `check` | resolved symbols and offsets, and fiber names seen in 1 s | |

`INTERVAL` (s) and `TOP` set the report period and length. Attaching takes
a few seconds, plus up to 10 s on an idle broker for tools that read fiber
names from a release build (the offset check waits for 20 fiber switches).
Ctrl-C ends a tool. Run `check` first on a new binary.

Idle time (blocked in `epoll_wait`, or parked on a condition variable by a
scheduler or the thread pool, probed in libc's `pthread_cond_*wait`, also in
static builds) is not counted by `stalls`, `evloop` and `oncpu`, so an idle
broker shows no gaps. The condition variable waits of libgc's parallel
marking are not idle: they happen inside a collection, on the thread that
collects, and count as part of the gap. When bpftrace misses the end of an
idle wait (seen under load with several tools attached), the next fiber
switch ends it in `stalls` and `oncpu`; `evloop` then misses that one gap.
A gap during a GC includes the stop-the-world; `gc_stw_overlap` says how much.

`gc` counts heap rescans: libgc pushes the roots once per collection and
again after each rescan of the heap that a mark stack overflow forces
(`GC_push_roots`, a call or two per collection). A rescan costs about a full
mark, and a stock bdwgc (8.2.12 and before) never grows its mark stack in
parallel mode, so a broker with thousands of parked fibers, whose stacks are
roots, rescans on every collection. It also reads libgc's heap size
(`GC_heapsize`, which never shrinks) after each collection and each heap
expansion: a heap that grows by hundreds of MB between a few collections is
allocating what libgc can't place in the heap it has, typically large
pointerful objects in a heap fragmented by blacklisting.

`finalizers` follows the objects Crystal registers a finalizer for, mostly
ones holding a file descriptor or a C resource: accepted sockets
(`TCPServer#accept?`), files, OpenSSL contexts and digests. A class is named
by the method that created it, read from the return address of
`GC_register_finalizer_ignore_self`; it is finalized when a collection finds
it unreachable. Its net change alive since attach levels off under a steady
load and falls back once the load stops and a collection has run (`POST
/api/nodes/gc_collect` forces one). A class that stays up holds objects
something still references: with sockets, closed connections that are never
freed.

`stalls` and `evloop` answer different questions. `stalls`: one fiber kept
the thread (a fiber that doesn't yield). `evloop`: the thread didn't poll for
IO and timers, either because one fiber kept it or because it worked through a
long run queue. A timer such as a lease keepalive fires late when `evloop`
shows a gap, so start with `evloop` and switch to `stalls` to name the fiber.

## CPU profiling

```
extras/bpf/lavinmq-bpf profile <pid> [seconds]     # default 30 s
HZ=199 FIBERS=1 OUT=/tmp/before extras/bpf/lavinmq-bpf profile <pid> 60
SOURCE_URL=https://github.com/cloudamqp/lavinmq/blob/v2.10.2 extras/bpf/lavinmq-bpf profile <pid>
```

Samples every thread at `HZ` (default 99) while on CPU, user and kernel
stacks, and writes `$OUT.svg`, `$OUT.folded` and `$OUT.lines` (default
`lavinmq-profile-<pid>-<time>`). The SVG needs no tools: open it in a
browser, hover for sample counts, click a frame to zoom in and to show its
details under the graph, click `all` to zoom out. The details are the
frame's samples, how often the function was on the stack and on top of it,
and the source lines the samples were at (for a caller, the line of the call),
with the inlined function when there is one. Lines come from the binary's
line tables (release builds have them) through `lines.sh`, which needs `nm`
and `llvm-symbolizer` or `addr2line` where the profile is taken; without them
the SVG has no lines. `SOURCE_URL` links `src/` lines, and Crystal stdlib
lines link to the matching Crystal version. The bottom levels are the thread
name and, with `FIBERS=1`, the fiber name; kernel frames end in `_[k]`. `.folded` is the standard folded format
for FlameGraph's `flamegraph.pl`, `difffolded.pl` (before/after diffs) or
speedscope. Ctrl-C ends early and still writes the files.

The bar above the graph filters it. Type a regex on function names and press
Enter, or pick a preset: `GC` (libgc and its marker threads), `Allocation`,
`Syscalls` (the kernel's `__x64_sys_*` entries, one per syscall), `Kernel`,
`Locks`, `Fiber switches`, `Event loop`. Matching frames turn magenta. With
"only matching stacks" (the default) the graph keeps just the samples whose
stacks contain a match, everything above and below them included, laid out
again to the full width, and the panel below says what share of all samples
that is and lists the matching functions with their share on the stack and
running themselves. Unchecked, matches are only highlighted. The filter works
the same in a diff, with the before and after shares.

To compare two profiles, for example before and after a change, under the
same load:

```
extras/bpf/lavinmq-bpf diff before.folded after.folded   # writes $OUT.svg
```

Frame widths are the average of the frame's share of each profile, so code
that exists on only one side still shows. Red means a larger share of the
samples after, blue a smaller one (full color at 4 percentage points), and a
dark outline marks frames found in only one profile. Thread names are dropped,
since they differ between runs. Profile both sides the same way (same `HZ`,
same `FIBERS`). Shares move between identical runs too: two profiles of the
same build under the same stream replay differed by up to 3.3 points in
kernel networking frames, so treat small shifts in busy frames as noise. A
frame that appears or disappears is a real change.

Full call chains need `--frame-pointers always` in the build (see
Limitations). Without it, each sample has its leaf function and junk above,
which is still a flat "where does CPU go" profile. Measured on the same
commits built both ways, under the same load (`/api/queues` at 20,000 queues,
16,000 idle connections with a full-speed publisher, a connection burst):
1.1-1.4 frames per sample instead of 7.4-8.5, no stack reaching `Fiber#run`
instead of 86-96%, and 2-5% of samples naming the request handler, read
loop or deliver loop instead of 85-95%. Self time is the same either way, so
a function that gets cheaper or disappears still shows in a diff
(`IO#write_byte` and `memset` across #2569 and #2452 did); what the callers
were, and the inclusive time of anything above the leaf, is lost: the
serialization of 20,000 prebuilt queue details was 79% of the samples with
frame pointers and 2.8% without.

Sampling costs nothing measurable (500+500 connections: broker CPU within
run-to-run noise). `FIBERS=1` adds the `swapcontext` probe, with the cost of
`oncpu`, and the probe itself shows up in the graph as `swapcontext` →
`asm_exc_int3_[k]`.

On a frame pointer build under 500+500 connections at 40 msg/s, 10 s with
`FIBERS=1` attributed 232 of 438 samples to the `Accept TCP socket` fibers
(client read loops; a third in `recv` and the kernel TCP path) and 201 to the
`Consumer` fibers (`deliver_loop`; 20% in GC, 8% in `write`).

## Timeline and comparison report

```
extras/bpf/lavinmq-bpf record <pid> [seconds]     # default 10 s
OUT=before SOURCE_URL=https://github.com/cloudamqp/lavinmq/blob/<commit> extras/bpf/lavinmq-bpf record <pid>
extras/bpf/lavinmq-bpf report before.trace after.trace      # or .folded files; no root needed
```

`record` writes what happened, with times: every fiber run of `RUN_MIN_US`
(default 200) or longer with its thread and fiber name (shorter runs are
summed per thread and 10 ms), idle time in `epoll_wait` or parked, each
collection with its stop-the-world pause and the heap after it, and CPU
samples at `HZ` with their thread, fiber and stacks. It writes `$OUT.trace`
(text, one event per line, see `record.bt`), `$OUT.lines` and `$OUT.html`.
It probes every fiber switch, so it costs what `oncpu` costs: use it for
seconds to minutes. bpftrace gets a larger output buffer for it
(`BPFTRACE_PERF_RB_PAGES`, default 2048 pages per CPU); if it still loses
events, the report says so at the top.

The report is one HTML file that works offline:

- **Timeline:** one row per thread. Fiber runs are colored by fiber name,
  idle time is pale, short runs are a gray density strip, CPU samples are dots,
  and collections run along the top with their stop-the-world pauses as red
  bands across every thread. Hover for what ran, for how long and how many
  CPU samples fell in it: a long run with few samples was blocked off CPU.
  Drag to select a time range, click a run to select it and its thread, click
  a thread name to keep only that thread; Ctrl and the wheel zoom.
- **Flame graph of the selection:** the samples in the selected range and
  thread, grouped by thread, by fiber or not at all, with the same filter
  presets and source lines as the SVG. Root at the top.
- **Fibers:** busy time, runs per second, longest run, spawned and finished
  per fiber name for the whole recording, and the share of CPU samples and the
  longest run in the selection.
- **Collections:** every collection with its pause and heap; click one to
  select it.
- **Objects:** what `finalizers` counts, for the whole recording: objects
  with a finalizer created, finalized and still alive per creating method.
- **Compare:** for any two recordings or profiles, the functions whose share
  of the CPU samples changed most, as a ranked table with both shares side by
  side and the change as a bar, either with the function anywhere on the stack
  or running itself. Functions only one side has are marked new or gone, and
  a row opens its callers and callees before and after. With fewer than 200
  samples on a side the table is folded away, since such shares are noise.
  For two recordings, busy time, longest run and spawned / finished per
  fiber (fibers that pile up first), the collections and the objects side by
  side too. This is the
  easier read of a before/after: across #2569 the top rows were
  `IO#write_byte` gone (-24.5 points) and `Response#write` gone, and across
  #2452, sorted by running itself, the kernel's `clear_page_erms` gone
  (-7.3 points: zeroing new heap pages), `memset` and `GC_mark_from` down.

## Machine-readable output

`FORMAT=tsv` makes `gc`, `stalls`, `evloop`, `fibers`, `oncpu`, `sched` and `finalizers`
print tab-separated rows with a header on stdout, for DuckDB, Parquet or a
benchmark harness; messages go to stderr. Times are UTC (ISO 8601, µs),
durations integer µs. `gc` defaults to every collection (threshold 0) and the
map tools to every key (`TOP=0`); `ONGOING` lines and histograms are left out.

```
sudo FORMAT=tsv extras/bpf/lavinmq-bpf gc $(pidof lavinmq) > gc.tsv
sudo FORMAT=tsv extras/bpf/lavinmq-bpf evloop $(pidof lavinmq) 20 > evloop.tsv
duckdb -c "COPY (FROM read_csv('evloop.tsv', delim='\t', quote='')) TO 'evloop.parquet'"
```

Fields are not quoted: read with `quote=''`, so a fiber name starting with
`"` stays as it is (tabs in names become spaces in map keys; a tab in a
fiber name of an event row would shift its columns). DuckDB infers types from
the rows, so a file with only a header loads as text: give `types={...}` when
combining runs. At Ctrl-C the map tools print the partial interval since the
last report, with the time of exit.

| Tool | Columns, one row per |
|---|---|
| `gc` | `time`, `collection_us`, `stw_us`, `stop_us`, `rescans`, `heap_kb` (after the collection): collection |
| `stalls`, `evloop` | `time`, `event`, `tid`, `thread`, `duration_us`, `gc_stw_us`, `fiber`, `stack`: `stall` (`stalls`) or `gap` (`evloop`) over the threshold, and `interval_max`, each thread's longest gap per `INTERVAL` (only `time`, `event`, `tid`, `thread`, `duration_us`). `fiber` is set by `stalls`, `stack` (root first, `;` between frames, the sample taken during the gap) by `evloop` |
| `fibers`, `oncpu`, `sched` | `time`, `metric`, `key`, `value`: each map at the end of each `INTERVAL`, `key` a fiber name. `fibers`: `spawned_total`, `finished_total`, `spawned`, `finished`, `live_delta` (since attach); `oncpu`: `on_cpu` (µs), `runs` (times switched out); `sched`: `max_us`, `avg_us` |
| `finalizers` | the same, `key` the creating method: `created`, `finalized`, `live_delta` (since attach), and `finalized_type` keyed by type id for classes not created since attach |

`profile` writes `.folded` (one stack and its samples per line) and `.lines`
(function, `file:line`, inlined function, samples, tab-separated).

## How it works

`lavinmq-bpf` resolves the binary through `/proc/<pid>/exe` (works for
containers and replaced binaries), lists its symbols with `bpftrace -l`
and fails if one a tool needs is missing, fills the placeholders in the `.bt`
script and runs it with `bpftrace -p <pid>`.

The scripts read fiber names from the Fiber object: `swapcontext(current,
new)` gets pointers to `Fiber#@context`, so `fiber = arg - offsetof(@context)`,
then `@name` (a `String*`: `@bytesize` at 4, chars at 12). Release builds have
line tables only, no type info, so the offsets come from, in order:
`llvm-dwarfdump` when the binary has type DWARF (`--debug` builds); a check
on the live process that tries the known `@name` offsets on the next 20 fiber
switches and keeps the one pointing at valid Strings; the table for the
Crystal version found in the binary. `FIBER_NAME_OFF` etc. override.

| Crystal | `@context` | `@name` | String `@bytesize`, `@c` |
|---|---|---|---|
| 1.21.x | 8 | 88 (has `@timeout_event`, `@timeout_select_action`) | 4, 12 |
| 1.22.x | 8 | 64 | 4, 12 |

Same on x86_64 and aarch64 (checked from the DWARF of
`offsets.cr` cross-compiled for aarch64). Probes use `argN` only, except
`finalizers`, which reads the return address at function entry (`sp` on
x86_64, `r30` on aarch64), and `gc`, which finds `GC_arrays` in the
position-independent binary from the probed function's address (`ip`, `pc`).

Symbols that differ between 1.21 and 1.22: the event loop pass that enqueues
ready fibers is `Parallel::Scheduler#run_evloop<Bool>` on 1.22 and
`EventLoop::Polling#run<Pointer(Fiber::List), Bool>` on 1.21 (`sched` uses
whichever exists); `Parallel#external_enqueue` is inlined in some 1.21
builds. All other probed symbols are the same.

## Validation

`test/workload.cr` runs a fiber `busy-loop` that blocks its thread for 2 s
every 5 s, an allocating fiber and 1000 short-lived fibers/s, and records
every collection in process (`GC_set_on_collection_event`) as ground truth.

```
$ extras/bpf/lavinmq-bpf stalls $(pidof bpf-workload)
05:08:58.562736 ONGOING tid=3411 (bpf-workload) 188 ms so far, fiber="busy-loop"
05:09:00.374692 STALL tid=3411 (bpf-workload) 2000 ms fiber="busy-loop" gc_stw_overlap=0 ms
05:09:00
@max_gap_ms[3411, bpf-workload]: 2000
@switches[3411, bpf-workload]: 418

$ extras/bpf/lavinmq-bpf evloop $(pidof bpf-workload)
05:33:40.924985 GAP tid=7940 (bpf-workload) 2000 ms without polling, gc_stw_overlap=0 ms
  on CPU during the gap:
        __clock_gettime_2+29
        ~procProc(Nil)@extras/bpf/test/workload.cr:61+665
```

`fibers` shows `short-lived` spawned and finished at the same rate, net 0.

`gc` against the `gc_pauses.cr` hook (from the gc-bench tools) built into
LavinMQ main, under `lavinmqperf amqp throughput -x 2 -y 2 -s 256`: all 276
collections matched, end times within 3 µs, durations 32 µs longer at the
median (the hook's start event fires after `GC_try_to_collect_inner` is
entered).

LavinMQ v2.10.2 (Crystal 1.21 stdlib), 2 publishers + 2 consumers, then 500 +
500 connections at 40 msg/s each:

```
$ extras/bpf/lavinmq-bpf gc $PID 20
05:43:27 249 collections in 10 s: collection total 383 ms max 13 ms, stw total 344 ms max 13 ms
$ extras/bpf/lavinmq-bpf evloop $PID 50
05:43:39.903328 ONGOING tid=9416 (lavinmq-2.10.2) 125 ms without polling, on CPU:
        *LavinMQ::AMQP::Consumer+@LavinMQ::AMQP::Consumer#deliver_loop:(Bool | Nil)+12436
05:43:40.044093 GAP tid=9416 (lavinmq-2.10.2) 266 ms without polling, gc_stw_overlap=7 ms
$ extras/bpf/lavinmq-bpf stalls $PID 50
05:43:21.811886 STALL tid=9416 (lavinmq-2.10.2) 54 ms fiber="Accept TCP socket" gc_stw_overlap=1 ms
$ extras/bpf/lavinmq-bpf oncpu $PID
05:43:47 ms on CPU per fiber name, and times switched out:
@on_cpu[AMQP listener]: 67
@on_cpu[Consumer vhost=/ queue=perf-test]: 2060
@on_cpu[Accept TCP socket]: 2128
@runs[Accept TCP socket]: 136695
@runs[Consumer vhost=/ queue=perf-test]: 530570
$ extras/bpf/lavinmq-bpf sched $PID
worst fiber names, max and avg (us):
@max_us[Server#stats_loop]: 862
@max_us[Accept TCP socket]: 12932
@max_us[Consumer vhost=/ queue=perf-test]: 14781
```

With 1000 connections the scheduler went 266 ms without polling while no
single fiber held it for more than 54 ms: a long run queue, not one bad fiber.

Four recent changes, each on release builds from before and after:

- Mark stack overflow (#2588, a patched libgc): 16,000 idle connections plus
  one publisher and one consumer at full speed. With the stock libgc, `gc`
  flagged every collection as a heap rescan, at 172-259 ms. With the patched
  one there were no rescans, at 84-114 ms.
- Finished fibers keeping their closures (#2587): 1000 idle connections
  closed at once, then three `POST /api/nodes/gc_collect`. Before the fix,
  `finalizers` still counted 261 `TCPServer#accept?` sockets alive: the
  scheduler's 256-slot run queue, plus the 3 HTTP connections. With the fix,
  5 remained.
- List details for every item (#2452): 20,000 queues, `/api/queues` in a
  loop for 60 s. Before the change, `gc` showed the heap growing from 490 to
  954 MB, with 3.3 times as many collections per request. After it, the heap
  held at 475 MB. A `diff` of `profile` runs showed the array of 20,000
  detail tuples and its `memset` going away.
- JSON through two IO dispatches (#2569): in the same diff, `IO#write_byte`
  and `HTTP::Server::Response#write` disappeared, and CPU per request fell
  from 126 to 102 ms.

## Overhead

`test/overhead.sh <pid> 3 15 -- <lavinmqperf args>`: LavinMQ main release
build, 4 vCPU, median of 3 runs of 15 s.

| tool | A: 2+2 clients, max rate (msg/s) | B: 500+500 clients, 19.7k msg/s (broker CPU ms/s) |
|---|---|---|
| none | 499k | 297 |
| gc | 504k | 323 |
| evloop | 475k | 321 |
| fibers | 514k | 316 |
| stalls | 519k | 393 (+32%) |
| oncpu | 498k | 420 (+41%) |
| sched | 463k | 430 (+45%) |

A switches fibers ~2k times/s (the broker batches), so no tool costs
anything measurable there: baseline runs alone ranged 462k-518k msg/s. B switches ~72k times/s:
a uprobe on `swapcontext` costs ~1.3 µs per switch, all on the
scheduler thread. `gc`, `fibers` and `evloop` probe rare events (one
collection, one spawn, one `epoll_wait`: ~700/s in B) and stay within
run-to-run noise (±25 ms/s). `finalizers` adds 4 probe hits per connection (2 objects
created, 2 finalized): under `lavinmqperf connection-churn` the open-close
time stayed within run-to-run noise (295-418 µs per connection with and
without it, 3 runs each). On a broker whose scheduler thread is near
saturation, use `evloop` for continuous monitoring and `stalls`, `oncpu` and
`sched` for short sessions.

## Limitations

- `evloop` cannot name the fiber, only the code on CPU, sampled at 10 Hz.
  `ustack()` walks frame pointers, which release builds omit (x86_64: 20 of
  5352 Crystal functions set one up): the first frame is right, the callers
  are missing or wrong. Build with `crystal build --release --frame-pointers
  always` (Crystal >= 1.21 has it) for full stacks: on LavinMQ main under
  500+500 connections, 10 s of samples went from 1.5 to 6 frames on average
  and 75% reached `Fiber#run`, and throughput and CPU were unchanged within
  noise (2 runs each, scenarios A and B below). libgc and libc frames still
  have none. A thread stalled off CPU (blocked syscall, page fault, stopped
  for GC) gets no stack.
- `ONGOING` lines need the thread on CPU; a gap off CPU is reported when it
  ends.
- `sched` measures from when the scheduler found a fiber runnable: a spawn,
  an enqueue, or the end of the event loop pass that returned it. A timer or
  socket that became ready while the scheduler was busy (a stalled fiber,
  say) waited longer than that: `sched` shows the queue wait, `evloop` the
  wait before the scheduler polled. Switches into the scheduler's loop fiber
  are counted until the tool has seen it poll once.
- `fibers` counts live fibers relative to attach time, and `finalizers` live
  objects. `finalizers` matches an object to its class by type id: a class
  created from several methods is counted under the one that created it last.
- Fiber names are read up to 128 bytes (`BPFTRACE_MAX_STRLEN`, which can't
  grow much: the strings live on the 512 byte BPF stack); fibers whose
  names only differ after that are counted together. Bytes outside ASCII in
  thread and fiber names become `?` in flame graphs.
- `profile` resolves symbols when bpftrace exits, from `/proc/<pid>/exe`:
  if the process exits first, frames are bare addresses.
- `oncpu` is wall time between switches minus idle, so it includes
  preemption and blocking syscalls.
- bpftrace 0.20 gives garbage map keys when an aggregation keyed by a
  `str()` follows `max()`; keep the order in `sched.bt`.
- Only symbol names, not their argument layout, are checked: a new Crystal
  version needs its offsets checked (`check`, `offsets.cr`).

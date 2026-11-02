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
| `gc` | every collection: total time (allocator lock held) and stop-the-world time; summary per interval, histograms on exit | yes |
| `fibers` | fibers spawned / finished per fiber name per interval, net change since attach | yes |
| `stalls` | per thread, time between fiber switches; prints gaps over the threshold (default 100 ms) with the fiber that ran and GC overlap, max gap per thread per second | for minutes, see overhead |
| `oncpu` | time each fiber name held its thread, top N per interval | for minutes |
| `sched` | scheduling latency (runnable to running) per fiber name | for minutes |
| `profile` | CPU profile as a flame graph (SVG) and folded stacks | yes (without `FIBERS=1`) |
| `check` | resolved symbols and offsets, and fiber names seen in 1 s | |

`INTERVAL` (s) and `TOP` set the report period and length. Attaching takes
a few seconds; Ctrl-C ends a
tool. Run `check` first on a new binary.

Idle time (blocked in `epoll_wait`, or parked on a condition variable by a
scheduler or the thread pool, probed in libc's `pthread_cond_*wait`) is not
counted by `stalls`, `evloop` and `oncpu`, so an idle broker shows no gaps.
When bpftrace misses the end of an idle wait (seen under load with several
tools attached), the next fiber switch ends it.
A gap during a GC includes the stop-the-world; `gc_stw_overlap` says how much.

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

Full call chains need `--frame-pointers always` in the build (see
Limitations). Without it, each sample has its leaf function and junk above,
which is still a flat "where does CPU go" profile.

Sampling costs nothing measurable (500+500 connections: broker CPU within
run-to-run noise). `FIBERS=1` adds the `swapcontext` probe, with the cost of
`oncpu`, and the probe itself shows up in the graph as `swapcontext` →
`asm_exc_int3_[k]`.

On a frame pointer build under 500+500 connections at 40 msg/s, 10 s with
`FIBERS=1` attributed 232 of 438 samples to the `Accept TCP socket` fibers
(client read loops; a third in `recv` and the kernel TCP path) and 201 to the
`Consumer` fibers (`deliver_loop`; 20% in GC, 8% in `write`).

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
`offsets.cr` cross-compiled for aarch64). Probes use `argN` only.

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
05:43:47 ms running per fiber name, and times switched out:
@ms[AMQP listener]: 67
@ms[Consumer vhost=/ queue=perf-test]: 2060
@ms[Accept TCP socket]: 2128
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
run-to-run noise (±25 ms/s). On a broker whose scheduler thread is near
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
- `sched` takes the time a fiber became ready from the scheduler's last event
  loop pass when it wasn't enqueued through a probed function: exact for the
  default single-thread context, approximate when fibers are stolen across
  threads.
- `fibers` counts live fibers relative to attach time.
- `profile` resolves symbols when bpftrace exits, from `/proc/<pid>/exe`:
  if the process exits first, frames are bare addresses.
- `oncpu` is wall time between switches minus idle, so it includes
  preemption and blocking syscalls.
- bpftrace 0.20 gives garbage map keys when an aggregation keyed by a
  `str()` follows `max()`; keep the order in `sched.bt`.
- Only symbol names, not their argument layout, are checked: a new Crystal
  version needs its offsets checked (`check`, `offsets.cr`).

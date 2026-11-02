# Runtime introspection

LavinMQ can answer questions about its fibers and heap while it runs, through the HTTP API
under `/api/debug` and `lavinmqctl debug`. All of it requires administrator access, and only
one debug request runs at a time (a second one gets `429`). The output is JSON.

Some of it stops the world (pauses every thread) or forces a garbage collection; that's
noted per endpoint below. A forced collection is a regular full collection: it pauses the
broker as long as its own collections do. Prefer the cheap ones on a busy node, and expect
the expensive ones to delay deliveries for their duration.

| Endpoint | `lavinmqctl` | Cost |
|----------|--------------|------|
| `GET /api/debug/fibers` | `debug fibers` | No pause. Holds the fiber list lock, ~3 µs per fiber (0.4 µs without backtraces) |
| `GET /api/debug/heap` | `debug heap` | Full collection + heap walk with the world stopped |
| `GET /api/debug/holders?type=T` | `debug holders T` | Full collection + two heap walks with the world stopped |
| `PUT /api/debug/retention` | `debug retention on\|off` | None; while on, a weak reference per finished fiber and closed socket |
| `GET /api/debug/retention` | `debug retention` | Full collection |
| `GET /api/debug/retention?holders=true` | `debug retention holders` | Full collection + heap walk with the world stopped |

Measured on a 4 vCPU VM with 3,000 AMQP connections (each with a channel and a consumer)
and 100 of them replaced per second: 4,900 fibers, 256 MB reachable heap of which 72 MB
may hold pointers, 1.36 million objects.

| Request | Response time | Of which world stopped |
|---------|---------------|------------------------|
| fibers | 21 ms (75 ms the first time, loading debug info) | none; lock held 14 ms, 1.8 ms without backtraces |
| heap | 390-440 ms | collection 330-370 ms + walk 58-61 ms |
| holders `LavinMQ::AMQP::Client` | 650 ms | collection 360 ms + scan 280 ms |
| retention | 490 ms | collection 350-470 ms |
| retention with holders | 570 ms | collection 350 ms + scan 190 ms |

The heap walk takes about 45 ns per reachable object (0.23 ms per MB here); the holder scan
adds the time to read every pointer-holding object, every suspended fiber's stack and the
data segments.

## Fibers

Every fiber with its name, state, execution context, stack size and stack used, plus counts
by name and by name prefix (the name up to its first space, as names often carry a queue or
client name). States:

- `running`: executing on a thread now
- `runnable`: suspended and queued in a scheduler, waiting for a thread
- `parked`: suspended, waiting for an event (IO, a channel, a timer)

Suspended fibers get a backtrace, unwound from the registers saved when the fiber was
switched out, using the binary's DWARF call frame information (Linux on x86_64 and AArch64).
It's read without stopping the fiber's thread: a fiber resumed while it's read gets an
empty backtrace rather than a wrong one. The first request loads the debug information
to symbolize backtraces, which takes a moment.

Query parameters: `name` (only fibers whose name contains it), `backtrace=false`,
`limit` (fibers listed, default 1000; the counts always include every fiber).

```sh
lavinmqctl debug fibers --no-backtrace --limit=0 | jq '.states, .by_name_prefix[:5]'
```

## Heap census

Forces a collection, then walks every reachable object with the world stopped and counts
objects and bytes by type. `scanned` objects may hold pointers and are marked through on
every collection (they drive pause times); the others (strings, buffers of numbers) only
cost memory. Objects that have no type header (array, hash and deque buffers, closures)
are grouped by size class.

```sh
lavinmqctl debug heap --limit=20
```

## Holders

`GET /api/debug/holders?type=LavinMQ::AMQP::Client` finds every word that points into a
live instance of the type, the way the GC sees it (conservatively, any word with the
right value counts):

- `heap`: in a reachable heap object, grouped by the holder's type with the most common
  offsets in it
- `stack`: in a suspended fiber's stack, grouped by fiber name prefix and offset from the
  stack bottom (its highest address); `own_stack` marks a fiber's references to itself
- `static`: in a writable data segment (global and class variables), by symbol

`unattributed` counts instances with no holder found: only referenced from a running
thread's registers or stack, or from a finalizer queue. A generic type name matches all
its instances (`Array` matches `Array(String)`).

## Retention of finished fibers and closed sockets

Answers "is something keeping dead connections alive?". Enable tracking, let the broker
run for a while, then ask:

```sh
lavinmqctl debug retention on
# ... let connections come and go ...
lavinmqctl debug retention            # counts, by name/type and age
lavinmqctl debug retention holders    # and what references them (stops the world)
lavinmqctl debug retention off        # stops tracking and forgets everything
```

While on, each finished fiber and closed socket gets a weak reference (at most 500,000;
`dropped` counts the rest). A report forces a collection, forgets the entries that were
collected, and reports the rest as `retained`. With `holders`, stack holders also count
`same_stack`: words on the very stack the retained fiber ran on. Fiber stacks are reused
without being cleared, so a fiber that gets a finished fiber's stack can keep that fiber
(and its closure, socket and buffers) reachable through a stale word its own frames never
overwrite; such words show up as a stack group with `same_stack` equal to `words`, at the
same offset for every holder.

When off, the hooks cost a load and a branch per finished fiber and closed socket.

# GC benchmark tools

Scripts behind the stats-history and GC report (Oct 2026). Not part of the build.

- `gc_pauses.cr`: a hook compiled into a broker (see `build.sh`). With `GC_PAUSE_FILE` set it
  writes every collection's duration, stop-the-world and mark phases, allocated bytes each second,
  finalizer registrations by type, a stack trace per collection, and a live-heap census by type on
  request. `GC_BYTES_PER_FINALIZER` sets Boehm's per-finalizer weight.
- `typetable.cr`: maps type IDs to names at compile time, for the census.
- `driver.cr`: 20k queues with flapping traffic plus connection churn (`churn`), reconnect floods
  (`flood`) or neither (`none`); `FLAP=0` turns flapping off.
- `run_broker.sh <binary suffix> <mode> <seconds>`: one run with optional lavinmqperf load
  (`PERF=0` off) and census (`CENSUS_AT=<s>`); `summarize.py` prints the result line.
  `run_broker_forcegc.sh` also forces a collection every 3 s.
- `churn.cr`, `bench.cr`: synthetic stats-object benchmarks (no broker).
- `mark.cr`: reproduces the parallel-marking slowdown with parked fibers
  (`TREE=1 ./mark 6500 2000000`, compare `GC_MARKERS=1`; `GC_PRINT_STATS=1` shows the overflows).
- `phases.py`, `fincount.py`, `symbolize.py`: phase split, finalizers per second, trigger stacks.
- `results/`: raw output of every run in the report, and the heap censuses.

The shell scripts expect `SCRATCH` to point at a directory holding `brokers/`, `bench/` and `runs/`.

## Fresh VM

    SCRATCH=$HOME/gcbench extras/gc-bench/setup.sh   # about 20 minutes on 4 vCPUs
    source $HOME/gcbench/env.sh

`BROKERS="bundled global stock"` picks which brokers it builds (one per libgc variant).

## libgc variants (bdwgc 8.2.8)

- `stock`: as released; overflows its 4,096-entry mark stack on every collection when parallel
  marking and thousands of fiber stack roots meet, and never grows it.
- `broad` (`bdwgc-mark-stack-overflow.patch`): always flags the stack to grow on overflow.
- `global` (`bdwgc-mark-stack-overflow-global.patch`): flags it when the global stack overflows,
  leaving helper threads' local stacks as upstream handles them. The one to ship.
- `bigstack`: unpatched, built with a 262,144-entry initial mark stack.

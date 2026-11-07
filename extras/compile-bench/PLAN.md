# Plan: faster Crystal builds and spec runs (compiler, GC, toolchain options)

Round 2 of the GC work (`../gc-bench/results-matrix`), aimed at the development and CI loop rather
than LavinMQ's runtime: how long the Crystal 1.22.2 compiler takes to build LavinMQ, itself and the
spec suites, how much of that is the compiler's own Boehm GC, and what we can change.

## Baseline on one 4-vCPU VM (packaged compiler, bdwgc 8.2.12 inside, LLVM 18.1.3)

| workload | wall | GC (stop-the-world) | peak RSS | dominant phase |
|---|---|---|---|---|
| LavinMQ dev build | 41.6 s | 6.6 s (16%), max 1.2 s | 2.8 GB | semantic 20 s |
| LavinMQ release build | 213 s | 4.1 s (2%) | 2.9 GB | LLVM -O3 single module 173 s |
| Compiler dev build | 59.0 s | 9.8 s (17%), max 2.2 s | 4.2 GB | semantic 27 s |
| Compiler release build | 623 s | 6.9 s (1%) | 7.7 GB | LLVM -O3 single module 584 s |
| LavinMQ spec build | 74 s | 12.7 s (17%) | 6.3 GB | |
| LavinMQ spec run | | 0.3 s in the first ~150 collections | | IO and timers |
| Crystal semantic spec build | 33 s | 7.3 s (22%) | 4.2 GB | |
| Crystal semantic spec run | 236 s | 8.4 s (4%) | 1.6 GB | single thread |

GC figures are the stop-the-world collections from `GC_PRINT_STATS`; lazy sweeping during
allocation comes on top (measured by bpf profiles of the compiler).

## Phases (`run-matrix.sh <phase>`), one VM each, variants interleaved within each round

| phase | question | variants | workloads |
|---|---|---|---|
| env | Does GC tuning of the packaged compiler help? | base, GC_MARKERS=1/2, GC_FREE_SPACE_DIVISOR=2/1, GC_INITIAL_HEAP_SIZE=2G/4G, GC_DONT_GC=1 (bound) | lmq-dev, lmq-spec, cr-dev |
| libgc-a | Do the 8.2.12 patches help the compiler? | compiler rebuilt with stock, fix, fix-fl, fix-pf; pkg | lmq-dev, lmq-spec, cr-dev |
| libgc-b | Does Acton's fork help the compiler? | rebuilt with stock, acton, acton-noinl; acton with growdiv 4, budget 100, refill 8; pkg | lmq-dev, lmq-spec, cr-dev |
| relopt | What do -O3 multi-module, -O2, -O1 save on release builds, and what do they cost at runtime? | --release, -O3, -O2, -O1 | lmq-*, cr-*, LavinMQ throughput |
| devopt | Development build options | --threads 1/2/4/8, --no-debug, lld, warm cache | lmq-dev, cr-dev |
| specs | Does libgc matter for spec processes? | std and semantic specs linked with stock, fix, fix-fl, acton; markers 1, divisor 1 | crstd-spec, crsem-spec runs |

Each VM: `extras/compile-bench/setup.sh`, then `extras/compile-bench/run-matrix.sh <phase>`. Results
in `$CB/results/<phase>.txt`; cross-VM numbers are not comparable, each phase has its own baseline.

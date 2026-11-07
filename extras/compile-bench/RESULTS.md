# Results: faster Crystal builds and spec runs

Crystal 1.22.2 (bdwgc 8.2.12, LLVM 18.1.3), 4-vCPU Xeon VMs, one VM per phase, variants interleaved
within each round, median of 3 rounds (relopt, specs: 2). Compare within a phase only: the VMs
differ by up to 20% in absolute times. Full tables: `results/tables.md` (`tables.py results`).
Workloads: `lmq-dev` = `crystal build src/lavinmq.cr`, `cr-dev` = the compiler itself,
`lmq-spec` = every LavinMQ spec in one program as `crystal spec` builds it, `*-release` = `--release`.

## Where the time goes

| workload | wall | in GC (stop-the-world) | bound without GC (`GC_DONT_GC`) |
|---|---|---|---|
| LavinMQ dev build | 30 s | 5.4 s | −21%, RSS 2.8 → 4.2 GB |
| Compiler dev build | 39 s | 6.7 s | −18%, RSS 4.2 → 6.1 GB |
| LavinMQ spec build | 50 s | 9.0 s | −15%, RSS 6.3 → 9.4 GB |
| LavinMQ release build | 222 s | 4.0 s | LLVM on one thread: 189 s |
| Compiler release build | 576 s | 5.6 s | LLVM on one thread: 544 s |

Dev and spec builds: GC is 15 to 21% of wall time. Release builds: 85 to 95% is LLVM optimizing one
module on one thread; GC does not matter there. A frame-pointer profile of a compiler dev build has
libgc on the stack in 32% of samples, 27% marking (`results/profile/cr-dev-fp.svg`).

## Findings

**1. The 8.2.12 mark stack fix speeds up the compiler (libgc-a).** Compiler rebuilt against patched
libgc: GC time −30 to −47%, wall −6 to −12%, compiler dev build max pause 2.1 → 1.1 s. The
compiler's deep AST overflows the 4,096-entry initial mark stack the same way LavinMQ's parked
fibers do (round 1). The free-list unlock order patch adds a little on the compiler build (−12% vs
−7%); prefetch on push nothing.

| variant | lmq-dev | lmq-spec | cr-dev | GC s (cr-dev) |
|---|---|---|---|---|
| pkg (packaged 1.22.2) | 35.7 s | 61.8 s | 48.9 s | 9.1 |
| stock (rebuilt) | −3% | −1% | +1% | 8.9 |
| fix | −11% | −6% | −7% | 6.0 |
| fix-fl | −11% | −3% | −12% | 5.2 |
| fix-pf | −10% | −3% | −8% | 6.1 |

**2. Malloc for LLVM (sys).** LLVM allocates through glibc malloc; the GC heap is separate.
`LD_PRELOAD` of mimalloc or jemalloc: release builds −11%, dev builds −4 to −11%. Transparent huge
pages `always`: dev −5 to −8%, release −2%. All three with `GC_UNMAP_THRESHOLD=0`: dev −10 to −17%,
release −14%.

| variant | lmq-dev | cr-dev | lmq-release |
|---|---|---|---|
| base | 35.4 s | 43.7 s | 222.0 s |
| THP always | −8% | −5% | −2% |
| GC_UNMAP_THRESHOLD=0 | −4% | +2% | +1% |
| jemalloc | −8% | ±0% | −11% |
| mimalloc | −11% | −4% | −11% |
| THP + jemalloc + unmap 0 | −17% | −10% | −14% |

**3. Warm cache halves dev builds (devopt).** Same source, cache kept: −47 to −51%. That is the
upper bound for an incremental build. `--no-debug` −4 to −8%. `--threads` defaults to the CPU
count, which is right: 1 thread +55%, 2 threads +24%, 8 threads on 4 vCPUs no change. lld instead
of the default linker: no change.

**4. Release builds: multi-module is 4× faster to compile and 3× slower to run; lower levels save little (relopt).**
`-O3`/`-O2`/`-O1` without `--single-module` cut LavinMQ's build from 237 s to 56 s and the
compiler's from 576 s to 91 s, and the level barely matters. The binaries publish 66% fewer
messages (626k → 211k msg/s). The follow-up on one VM (relopt-flag) separates the two things
`--release` adds: with `-Drelease` the multi-module binaries still lose 66%; `-O3 --single-module`
without the flag matches `--release`. The loss is cross-module inlining, so release builds stay
single-module.

| build | build time | publish msg/s |
|---|---|---|
| `--release` | 225.7 s | 960k |
| `-O3 --single-module` | −3% | ±0% |
| `-O3 -Drelease` (multi-module) | −75% | −66% |
| `-O2 -Drelease` | −74% | −67% |
| `-O1 -Drelease` | −74% | −66% |

Single-module at lower levels (relopt-single, same VM, another session): `-O2 --single-module
-Drelease` builds 5% faster and publishes 7% less, `-O1` builds 12% faster and publishes 5% less.
Almost all of the build stays in LLVM on one thread at any level.

| build | build time | publish msg/s |
|---|---|---|
| `--release` | 210.8 s | 981k |
| `-O2 --single-module -Drelease` | −5% | −7% |
| `-O1 --single-module -Drelease` | −12% | −5% |

**5. GC settings of the packaged compiler: the defaults are best (env).** Fewer markers cost
+12 to +18% (`GC_MARKERS=1`) and +3 to +7% (`2`); `GC_FREE_SPACE_DIVISOR=1/2` (fewer collections)
−4 to +8%; an initial heap of 2 or 4 GB +5 to +14% (fewer collections, each longer, and the dev
build's codegen slower). On more cores more markers should help: the default is one per CPU.

**6. Acton's fork slows the compiler down (libgc-b).** +22% (lmq-dev), +44% (cr-dev), +57%
(lmq-spec), from collecting 3.5 times as often (82 against 23 collections on lmq-dev). With
`GC_HEAP_GROWTH_DIVISOR=4` it is level with the packaged compiler (−2 to −5%), not better than
`fix`. Not inlining, the allocation budget and the refill limit change nothing.

**7. Spec processes (specs).** Crystal's own spec binaries linked against `fix` or `fix-fl` run 5 to
7% faster than stock (semantic specs 220 → 205 s, std specs 94 → 88 s); acton ±0 to −7%.
`GC_FREE_SPACE_DIVISOR=1` −3 to −13% at up to 4× the RSS. All spec binaries were built by the
packaged compiler, linked against each libgc; the variants change only the spec process.
The 25 std spec failures are the sandbox (network, permissions), the same for every variant.

**8. The LavinMQ spec run waits.** 5:13 wall for 42 s of CPU and 1.1 s of GC: 87% is sleeps,
timeouts and IO in the specs, not the compiler or the GC.

## What to do

1. Build bdwgc 8.2.12 in 84codes/crystal-packages as the `fix-fl` variant
   (`../gc-bench/build-libgc-matrix.sh`: `bdwgc-mark-stack-overflow-global.patch`, a 32,768-entry
   initial mark stack, `bdwgc-8.2.12-fl-builder-unlock-order.patch`): the compiler
   gets 7 to 12% faster dev builds and half the pause, and every program linked against the
   packaged `libgc.a` (LavinMQ) gets round 1's pause fix.
2. CI: cache `~/.cache/crystal` (`CRYSTAL_CACHE_DIR`) for the spec and build jobs. Up to −50% on
   the compile; an unchanged source tree is the upper bound.
3. CI and local release builds: preload mimalloc for the compiler,
   `LD_PRELOAD=libmimalloc.so.2 crystal build --release ...`: −11% on the 4-minute release build.
   On runners where THP can be set to `always`, a further 3 to 6%.
4. Keep `--release` for shipped binaries. Multi-module optimization costs two thirds of the
   throughput; `-O1 --single-module -Drelease` saves 12% of the build for 5% of the throughput,
   which only suits CI-only binaries such as `bin/stress` and `bin/shovel-test`.
5. Spec run time: look at the waits in `spec/` (sleeps, `wait_for` timeouts), not at the compiler.

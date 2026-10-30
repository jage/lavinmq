# Finalizers and collection frequency on upstream main, full load

Branch `gc-bench-main-finalizers-load`, 2026-10-30.

## Setup

- VM: 4 vCPU (`nproc` 4), Intel Xeon @ 2.10 GHz (family 6 model 207), KVM, 15 GB RAM. CPU steal from
  `vmstat 1 5` before each run (`runs/*/vmstat.txt`): 0% in all runs except 1% once (before r4 main).
- Crystal 1.21.0 (LLVM 20.1.8), Crystal's bundled `libgc.a`; `GC_get_version()` = 8.2.8 (a 3-line
  program linked the same way). All four broker binaries link that same archive, default markers.
- Brokers: `main` = upstream `baaa3ea`; `digest` = `142910d` (PR 2584, on `baaa3ea`). `-socket` adds
  `zz_socket_unregister.cr` (the colleague's snippet plus an `Atomic(UInt64)` counter written once a
  second to `gc.pauses.unregs`), required before `./lavinmq`. `digest-socket-1k` is the
  `digest-socket` binary with `GC_BYTES_PER_FINALIZER=1000`. Built by `build.sh`; the hook
  (`gc_pauses.cr`, `typetable.cr`) compiled against main unchanged.
- Load per run: `run_broker.sh <bin> churn 240` (PERF=1, FLAP=1): 20k flapping queues, 2,000
  connections with 200 reconnects/s, lavinmqperf ~20k msg/s. 5 rounds, variants interleaved in the
  order main, main-socket, digest, digest-socket, digest-socket-1k. Rounds 1-3: `plan.sh 1 3`;
  rounds 4-5: `plan45.sh 4 5` (added because digest-socket and digest-socket-1k are within 15%).
- Anomaly: `ss` is not installed, so `plan.sh`'s port check was a no-op in rounds 1-3 (the
  `pkill -9` + 2 s sleep before it did the cleanup; every run started its own broker cleanly, see
  `broker.log`). `plan45.sh` checks the ports with bash `/dev/tcp`.
- Metrics are over the driver's measure window. Trigger path: the hook's per-collection backtrace,
  symbolized with `nm` (PIE base from `gc.pauses.maps`), classified by the first of
  `GC_collect_or_expand` (C), `GC_maybe_gc`/`GC_collect_a_little_inner` (M), `GC_grow_table` (G),
  explicit `GC_gcollect`/`GC_try_to_collect` (E), other (O). C cannot tell its finalizer clause from
  `GC_should_collect()`; the hook records no allocation counters at collection start.
  `analyze.py runs <brokers dir>` regenerates the tables; `summary.txt` has the raw summary lines.

## Per run

| run | variant | gcs/min | p50 | p90 | max ms | GC ms/min | RSS peak/end MB | finalizers/s | socket unreg/s | trigger % (C/M/G/E/O) |
|---|---|---|---|---|---|---|---|---|---|---|
| r1 | digest | 4.0 | 193 | 228 | 343 | 823 | 661/600 | TCPSocket 202, File 5 | - | 75 / 0 / 25 / 0 / 0 |
| r1 | digest-socket | 3.5 | 201 | 213 | 224 | 686 | 660/598 | TCPSocket 202, File 5 | 201 | 100 / 0 / 0 / 0 / 0 |
| r1 | digest-socket-1k | 3.5 | 210 | 223 | 244 | 719 | 661/599 | TCPSocket 200, File 5 | 209 | 100 / 0 / 0 / 0 / 0 |
| r1 | main | 5.2 | 196 | 224 | 257 | 1033 | 662/600 | TCPSocket 201, OpenSSL::Digest 201, File 5 | - | 57 / 0 / 43 / 0 / 0 |
| r1 | main-socket | 6.7 | 190 | 211 | 235 | 1278 | 599/537 | TCPSocket 201, OpenSSL::Digest 201, File 5 | 201 | 0 / 0 / 100 / 0 / 0 |
| r2 | digest | 4.2 | 196 | 251 | 295 | 854 | 661/599 | TCPSocket 201, File 5 | - | 76 / 0 / 24 / 0 / 0 |
| r2 | digest-socket | 3.5 | 203 | 260 | 270 | 733 | 660/598 | TCPSocket 200, File 5 | 209 | 100 / 0 / 0 / 0 / 0 |
| r2 | digest-socket-1k | 3.5 | 205 | 240 | 245 | 717 | 646/586 | TCPSocket 206, File 5 | 201 | 100 / 0 / 0 / 0 / 0 |
| r2 | main | 5.5 | 201 | 230 | 247 | 1095 | 662/601 | TCPSocket 200, OpenSSL::Digest 200, File 5 | - | 55 / 0 / 45 / 0 / 0 |
| r2 | main-socket | 6.7 | 195 | 222 | 244 | 1324 | 598/537 | TCPSocket 202, OpenSSL::Digest 202, File 5 | 201 | 0 / 0 / 100 / 0 / 0 |
| r3 | digest | 4.2 | 202 | 222 | 230 | 857 | 661/599 | TCPSocket 201, File 5 | - | 71 / 0 / 29 / 0 / 0 |
| r3 | digest-socket | 3.5 | 198 | 231 | 239 | 694 | 660/599 | TCPSocket 204, File 5 | 201 | 100 / 0 / 0 / 0 / 0 |
| r3 | digest-socket-1k | 3.5 | 191 | 230 | 232 | 675 | 660/600 | TCPSocket 205, File 5 | 201 | 100 / 0 / 0 / 0 / 0 |
| r3 | main | 5.5 | 204 | 234 | 242 | 1136 | 662/599 | TCPSocket 203, OpenSSL::Digest 203, File 5 | - | 55 / 0 / 45 / 0 / 0 |
| r3 | main-socket | 6.7 | 188 | 217 | 233 | 1295 | 599/537 | OpenSSL::Digest 202, TCPSocket 202, File 5 | 201 | 0 / 0 / 100 / 0 / 0 |
| r4 | digest | 4.0 | 209 | 264 | 278 | 838 | 661/599 | TCPSocket 203, File 5 | - | 75 / 0 / 25 / 0 / 0 |
| r4 | digest-socket | 3.5 | 195 | 222 | 241 | 696 | 661/599 | TCPSocket 201, File 5 | 209 | 100 / 0 / 0 / 0 / 0 |
| r4 | digest-socket-1k | 3.5 | 208 | 231 | 240 | 708 | 662/600 | TCPSocket 201, File 5 | 201 | 100 / 0 / 0 / 0 / 0 |
| r4 | main | 5.5 | 206 | 219 | 241 | 1086 | 662/601 | TCPSocket 201, OpenSSL::Digest 201, File 5 | - | 55 / 0 / 45 / 0 / 0 |
| r4 | main-socket | 6.7 | 189 | 208 | 234 | 1270 | 599/536 | TCPSocket 202, OpenSSL::Digest 202, File 5 | 201 | 0 / 0 / 100 / 0 / 0 |
| r5 | digest | 4.2 | 209 | 240 | 261 | 891 | 661/599 | TCPSocket 205, File 5 | - | 71 / 0 / 29 / 0 / 0 |
| r5 | digest-socket | 3.5 | 185 | 204 | 221 | 651 | 661/600 | TCPSocket 200, File 5 | 209 | 100 / 0 / 0 / 0 / 0 |
| r5 | digest-socket-1k | 3.5 | 196 | 205 | 266 | 694 | 662/601 | TCPSocket 205, File 5 | 201 | 100 / 0 / 0 / 0 / 0 |
| r5 | main | 5.2 | 190 | 209 | 258 | 1003 | 663/601 | TCPSocket 200, OpenSSL::Digest 200, File 5 | - | 57 / 0 / 43 / 0 / 0 |
| r5 | main-socket | 6.7 | 194 | 226 | 231 | 1323 | 598/536 | TCPSocket 203, OpenSSL::Digest 203, File 5 | 201 | 0 / 0 / 100 / 0 / 0 |

Finalizers/s only lists types registered during the measure window (all variants also register
~20k `File` and ~20k `Digest::SHA1` at startup).

## Per variant (median of 5; trigger % pooled over all runs)

| variant | runs | gcs/min | p50 | p90 | max ms | GC ms/min | RSS peak MB | finalizers/s (total) | socket unreg/s | trigger % (C/M/G/E/O) |
|---|---|---|---|---|---|---|---|---|---|---|
| main | 5 | 5.5 | 201 | 224 | 247 | 1086 | 662 | 407 | - | 56 / 0 / 44 / 0 / 0 (n=108) |
| main-socket | 5 | 6.7 | 190 | 217 | 234 | 1295 | 599 | 409 | 201 | 0 / 0 / 100 / 0 / 0 (n=135) |
| digest | 5 | 4.2 | 202 | 240 | 278 | 854 | 661 | 208 | - | 73 / 0 / 27 / 0 / 0 (n=83) |
| digest-socket | 5 | 3.5 | 198 | 222 | 239 | 694 | 660 | 206 | 209 | 100 / 0 / 0 / 0 / 0 (n=70) |
| digest-socket-1k | 5 | 3.5 | 205 | 230 | 244 | 708 | 661 | 210 | 201 | 100 / 0 / 0 / 0 / 0 (n=70) |

## Conclusions

- PR 2584 (digest) cuts collections from 5.5 to 4.2/min and GC time from 1,086 to 854 ms/min (-21%).
  Pause length is unchanged (~200 ms p50); RSS unchanged.
- The socket unregister alone on main makes it worse: 6.7/min, 1,295 ms/min (+19%), every collection
  forced by `GC_grow_table` (called from `GC_register_finalizer_inner` for `OpenSSL::Digest`), at a
  fixed ~8.8 s period (~1,770 digest registrations). bdwgc 8.2.8 collects before growing a full
  finalizer table and skips growth when the collection frees >=25%; with closed sockets dropping out
  the table (inferred) stays small and is refilled by digests. On main, collections come ~16 s apart, mixing both paths.
- Both together are best: 3.5/min, 694 ms/min (-36% vs main, -19% vs digest), all collections via
  `GC_collect_or_expand`; no `GC_grow_table` collections since net finalizer entries stay flat.
- The 1 KB weight adds nothing on top (3.5/min, 708 ms/min): with both fixes the net
  `GC_fo_entries` growth per cycle is ~0, so the finalizer clause cannot fire whatever the weight.
- Digest alone still takes 27% of its collections through `GC_grow_table` (likely closed sockets
  waiting for a GC to leave the table); the socket unregister removes those.

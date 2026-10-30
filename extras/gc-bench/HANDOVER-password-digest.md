# Handover: hash passwords without a finalizable OpenSSL::Digest

Goal: get the password digest fix merged into cloudamqp/lavinmq within a day or two, with
measurements that prove it on upstream main. Owner: Johan (johan@duh.se).

## The problem in one paragraph

Every AMQP login checks the password with `RabbitPassword#verify`
(`src/lavinmq/auth/password.cr`), which created an `OpenSSL::Digest`. That class has a
`finalize` method, so Crystal registers a Boehm GC finalizer for each instance. When the heap needs
more blocks, Boehm collects instead of growing if the finalizable objects registered since the last
collection, weighted at `GC_allocd_bytes_per_finalizer` (default 10,000 bytes each), exceed the
bytes actually allocated since then (bdwgc 8.2.8 `alloc.c`, `GC_collect_or_expand`). Each
connection registers two finalizable objects: its `TCPSocket` (stdlib `Socket#finalize`, not
avoidable) and this digest. So connection churn reads to Boehm as far more allocation than happens
and drives collections.

## The fix (done, needs a PR)

- Branch `password-digest-without-finalizer` on jage/lavinmq, one commit `8d9aee41`, based on
  upstream main `b7a2f3cc`. Upstream main has moved 2 commits since (`baaa3ea2` at the time of
  writing); rebase or merge before opening the PR.
- `RabbitPassword.digest(algorithm, salt, password)` does the salted hash on a plain EVP context
  (`EVP_get_digestbyname`, `EVP_MD_CTX_new`, `EVP_DigestInit_ex`, two `EVP_DigestUpdate`,
  `EVP_DigestFinal_ex`) and frees it in an `ensure`. `create` and `verify` both use it. The only GC
  allocation left is the 16–64 byte result, which has no finalizer.
- Same errors as before: an unknown algorithm raises `OpenSSL::Digest::UnsupportedError` with the
  same message `OpenSSL::Digest.new` uses; other failures raise `OpenSSL::Digest::Error`.
- `evp_md_size` comes from Crystal's stdlib `LibCrypto` bindings, which map it to `EVP_MD_get_size`
  on OpenSSL 3 and `EVP_MD_size` on 1.1.
- bcrypt passwords (`BcryptPassword`) are untouched; they never used OpenSSL.
- Spec (in `spec/users_spec.cr`, `describe LavinMQ::Auth::Password::RabbitPassword`): for MD5,
  SHA256 and SHA512, a hash made with `OpenSSL::Digest` verifies, a wrong password fails, and
  `create` round-trips.
- Tests run: `spec/users_spec.cr` + `spec/auth_spec.cr` 62 examples pass; full suite (without etcd
  specs) 2,734 examples, the only failure `spec/websocket_spec.cr:171`, which fails on upstream
  main too in this environment.

## Before opening the PR

1. Commit author: `8d9aee41` was committed by a container whose git identity is
   `Claude <noreply@anthropic.com>`. Per AGENTS.md, commits are written as the person you work
   for, without changing `user.name`/`user.email` or passing `--author`. Recreate the commit in an
   environment configured as Johan, or ask him to.
2. Rebase onto current upstream main, then run
   `make test SPEC="spec/users_spec.cr spec/auth_spec.cr"`, `make lint`, `crystal tool format`.
3. Add a CHANGELOG.md entry (under the unreleased section, "Changed" or "Fixed") linking the PR,
   e.g.: "AMQP logins no longer create a finalizable `OpenSSL::Digest` per password check, which
   made connection churn trigger far more garbage collections than its allocation explained".
4. Re-measure on upstream main (next section). Important: all numbers below were measured with the
   fix on top of the `gc-heap-stats` branch (lazy stats history), not on main. Main's heap carries
   about 300 MB of pointer-free stats buffers at 20k queues, which changes Boehm's thresholds; it
   collected about 5–6 times a minute under the same load where the GC branch collected about 10.
   Expect a real but possibly smaller effect on main, and report what you measure.

## Evidence so far

Finalizer registrations counted by type during 60 s of connection churn (a hook around
`GC.add_finalizer`), 200 reconnects/s:

| Type | Before | With the fix |
|---|---|---|
| `TCPSocket` | 202/s | 199/s |
| `OpenSSL::Digest` | 202/s | 0 |

GC-branch broker, full load (20k queues with flapping traffic, 200 reconnects/s, 20k msg/s via
lavinmqperf), 240 s per run, 4 vCPU VM, two runs each:

| Variant | Collections/min | Pause p50 | GC time/min | RSS at end |
|---|---|---|---|---|
| Baseline | 10.2, 9.7 | 97–99 ms | 989–1,058 ms | 219–228 MB |
| Digest fix | 3.5, 3.5 | 103–108 ms | 375–380 ms | 252–270 MB |
| Digest fix + per-finalizer weight 1 KB | 3.5, 3.2 | 103 ms | 348–375 ms | 283 MB |
| Per-finalizer weight 1 KB, no digest fix | 4.5, 4.7 | 99–104 ms | 470–503 ms | 253–269 MB |

Fewer collections cost about 40 MB more RSS at that scale. With churn only and no other traffic,
the effect was hidden by noise (collections/min 8.5, 17.5, 10.0 vs 13.5, 14.0, 10.5): there, half
the finalizer weight still exceeds the small real allocation rate. Under real traffic it drops below.

Raw logs: `extras/gc-bench/results/plan2.log` (churn only), `plan3.log` (full load).

## How to measure on main

Easiest with the tools on the `gc-bench-tools` branch (`extras/gc-bench/`, see its README):

1. `SCRATCH=$HOME/gcbench extras/gc-bench/setup.sh` sets up Crystal 1.21, the load driver,
   lavinmqperf and libgc variants (about 20 minutes). Its brokers are built from gc-heap-stats + the
   digest fix; for this comparison build two brokers yourself from upstream main and from the
   rebased branch, with the GC hook, the way `setup.sh` does at the end (copy `gc_pauses.cr` and
   `typetable.cr` into `src/` as `zz_*.cr`, build `src/zz_bench.cr`, output to
   `$SCRATCH/brokers/lavinmq-<name>`, then remove the `zz_` files).
2. `cd $SCRATCH/bench && ./run_broker_frozen.sh <name> churn 240` runs the full load and prints
   collections/min, pause p50/p99/max, GC time/min, RSS and throughput. Run both brokers at least
   twice, interleaved, one at a time (fixed ports). `PERF=0 FLAP=0` gives churn only.
3. Optionally count finalizers per type with `python3 -I fincount.py $SCRATCH/runs/<name>-churn`.

For the PR description a simpler reproduction is fine too: run each broker with
`lavinmqperf connection-churn` plus `lavinmqperf throughput` and compare `lavinmq_gc_cycles_total`
over a fixed time from `/metrics`. If #2565 (the `lavinmq_gc_pause_seconds` histogram) is merged,
include its `_count` and `_sum` rates.

## Things a reviewer may ask

- Thread safety: no shared state; each call has its own context.
- Why not keep one `OpenSSL::Digest` and reset it: it would need a lock or one per thread, and
  still holds a finalizer; a short-lived context is simpler.
- Performance: the same OpenSSL calls as before, minus the Crystal wrapper object.
- TLS: TLS connections also register an `OpenSSL::SSL::Socket` finalizer; this fix does not touch
  that. If TLS churn matters, `GC_set_allocd_bytes_per_finalizer` at startup (e.g. 1,000) is the
  lever; measured above as halving churn collections without the digest fix.

## Out of scope here, for context

- The bigger GC finding (bdwgc's parallel marking breaks down with thousands of fibers because the
  global mark stack never grows in parallel mode) and its libgc patch: `extras/gc-bench/README.md`,
  `bdwgc-mark-stack-overflow-global.patch`, and results branches `gc-bench-results-patch`,
  `gc-bench-results-broker`, `gc-bench-results-acton`.
- `GC_MARKERS=1` as a mitigation is not a safe default: it slows marking for deployments with few
  connections and a large heap, where parallel marking still works.

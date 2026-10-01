# Nightly harnesses

Long-running tests that start the real broker, drive it from the outside and
check the results automatically. They find the bugs specs miss: what happens
after a crash, after a restart, and in long or unusual sequences of
operations. They run nightly in CI, and locally against any build.

Everything is Python 3 standard library, so there's nothing to install
besides a broker binary.

## Layout

- `lib/`: what every harness shares.
  - `broker.py`: starts, stops and kills a broker on its own ports and data
    dir, and picks broker failures out of its log.
  - `amqp.py`: a raw AMQP 0-9-1 client that can send any method with any
    field values. `amqp_methods.py` is its method table.
  - `mqtt.py`: a raw MQTT 3.1.1 client.
  - `mgmt.py`: a client for the management HTTP API.
- `test_lib.py`: self-tests for `lib/`.
- `torn/`: damaged data dirs at startup, below.

## Damaged data dirs

`torn/torn.py` seeds a broker with every kind of persistent state, then starts
the broker on copies of that data dir, each damaged the way a crash or power
loss can leave it, and checks what comes back against the intact seed.

- **The seed** (`torn/state.py`): classic, priority and stream queues with
  acks, tracked stream consumers, dead-lettered and delayed messages, two
  persistent MQTT sessions with queued messages, retained messages, and
  users, vhosts, permissions, policies, parameters and limits set over HTTP.
  Every message body checks itself with a CRC and says which store and
  sequence number it came from.
- **The damage**, for every file in the data dir:
  - cut at and around record boundaries
  - cut, then zeros up to the capacity, which is what a preallocated mmap
    file looks like after a crash, including at page boundaries inside a
    record
  - a page of zeros in the middle
  - the file deleted
  - a stale `.tmp` next to files that are replaced by rename

  Each case runs once in `single` mode, a start on the damaged copy, and some
  in `double` mode: start, publish confirmed messages, `kill -9`, start
  again. That shows whether a repair reaches the disk or only memory.
- **The checks**: the broker starts and logs no exceptions, every body reads
  back intact, no message appears that wasn't there, nothing is lost outside
  the damaged region, confirmed messages survive the second start, stream
  offsets don't move forward, and definitions, retained messages and delayed
  messages match the seed.

Each failure becomes a signature, the check plus the kind of damage, e.g.
`lost q.classic | zerotail meta:q.classic single`. `torn/known.txt` lists
the signatures of known bugs, so a run fails only on new ones. When a fix
makes a known signature go away, remove it from the list.

```sh
python3 verification/nightly/torn/torn.py run --sample 300   # random 300 of ~6000 cases
python3 verification/nightly/torn/torn.py run                # all of them, about an hour
python3 verification/nightly/torn/torn.py replay '<a line from results.jsonl>'
```

`replay` reruns one case and keeps its data dir. Results go to
`verification/nightly/runs/torn/`: `summary.md`, `results.jsonl`, and the
seed with its `expected.json`.

## CI

`.github/workflows/nightly.yml` builds the broker and runs each harness every
night, a different random sample each night. The summary shows in the run,
and the results, the seed and the expected state are uploaded, so any case
can be replayed locally against the same seed.

## Running

Build a broker, then run the self-tests:

```sh
make bin/lavinmq
python3 verification/nightly/test_lib.py
```

`LAVINMQ_BIN` points the harnesses at another binary; the default is
`bin/lavinmq`.

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

## Running

Build a broker, then run the self-tests:

```sh
make bin/lavinmq
python3 verification/nightly/test_lib.py
```

`LAVINMQ_BIN` points the harnesses at another binary; the default is
`bin/lavinmq`.

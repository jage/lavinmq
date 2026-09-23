# Formal verification

[Lean 4](https://lean-lang.org/) models of the pure, protocol-level algorithms
in LavinMQ and its protocol shards, with machine-checked proofs that they
agree with the AMQP 0-9-1 and MQTT 3.1.1 specifications.

The models mirror the Crystal code structurally (same recursion, same
branches), so a divergence found in the model points at a line in the source.
Every divergence found this way has a regression spec on the Crystal side.

| Module | Crystal source | Proven |
| --- | --- | --- |
| `AmqpTopic` | `src/lavinmq/amqp/exchange/topic.cr` `TopicBindingKey`, `RkIterator` | segment chain equals §3.1.3.3 for all keys; fixed `RkIterator` splits like `String#split('.')` |
| `MqttTopic` | `src/lavinmq/mqtt/topic_rule_segment.cr`, `subscription_tree.cr`, `topic_tree.cr` | permission rules equal §4.7; subscription and retain trees miss `#` parent level and `$` rule, fixed versions equal §4.7 |
| `MqttRemainingLength` | `lib/mqtt-protocol` `IO#write_remaining_length`, `IO#read_remaining_length`, `Packet#bytesize` | round trip, encoded size per Table 2.4, 4-byte limit; `bytesize` off by one at 127, 16 383, 2 097 151 |

## TLA+: replication and failover

`tla/Replication.tla` models the clustering protocol (leader, followers,
etcd election and ISR, publish confirms) with node crashes and disconnects
at every step. TLC checks every interleaving for 3 nodes and 2 messages.

| Config | Models | Result |
| --- | --- | --- |
| `Current.cfg` | the code as it is | a confirmed message is lost in 11 steps |
| `JoinAfterAck.cfg` | ISR join only after the follower's first ack | still lost, in 16 steps |
| `Fixed.cfg` | also keep mismatching files until replaced | no violation, 788k states |
| `FixedLeaderOnly.cfg` | ISR join after ack, ISR committed without a follower before syncing it | no violation, 506k states |

The two defects: `Server#sync_and_serve` lists a follower in the ISR before
it has written its full sync, and `Client#sync_files` deletes a mismatching
file while the follower may still be listed in the ISR.

```sh
java -jar tla2tools.jar -deadlock -config tla/Fixed.cfg tla/Replication.tla
```

Get `tla2tools.jar` from the [TLA+ releases](https://github.com/tlaplus/tlaplus/releases).

## Running

Install Lean with [elan](https://github.com/leanprover/elan), then:

```sh
make verify
```

The toolchain is pinned in `lean-toolchain`; only Lean core is used. CI runs
the proofs when anything under `verification/` changes.

## Keeping models in sync

A proof covers the model, not the Crystal code. When changing one of the
sources in the table, update its model in the same change and run
`make verify`.

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
| `Replication.cfg` | the code | no confirmed message is lost (477k states) |
| `LeaseExpiry.cfg` | the code, with a leader serving on after its lease expired | no confirmed message is lost (2.2M states) |
| `ProtocolV1_0.cfg` | before protocol 1.1, and 1.0 followers | a confirmed message is lost in 11 steps |
| `SyncAckOnly.cfg` | without committing the ISR before a follower's sync | lost in 16 steps |

With `LeaseExpiry` two nodes can serve at once. A deposed leader can still
confirm until a successor serves (`DeposedCanConfirm` is reachable), but not
after: the successor closing its replication link dirties the old leader's
ISR, and a fenced leader can't flush it (`DeposedConfirmsBesideLeader` is
unreachable).

The two defects it found: the leader listed a follower in the ISR before
the follower had written its full sync, and a follower still listed in the
ISR deletes mismatching files when it resyncs.

```sh
make verify-tla TLA2TOOLS=path/to/tla2tools.jar
```

Get `tla2tools.jar` from the [TLA+ releases](https://github.com/tlaplus/tlaplus/releases);
it needs Java 11 or later.

## Model-based specs

The proofs and TLC check models, not the Crystal code. These specs close the
gap from the other side: they drive the real code with random operations and
check it against a small reference model after every step. Each takes `SEED`,
`SEEDS` and `STEPS` from the environment for longer runs.

| Spec | Drives | Found |
| --- | --- | --- |
| `spec/message_store_model_spec.cr` | `MessageStore`: push, shift, requeue, ack, purge, restart, crash | recovery counted zero padding after a crashed segment's last record |
| `spec/queue_model_spec.cr` | a queue over AMQP: publish, get, ack, nack, reject, channel close, purge, restart; with x-max-length, priorities and x-delivery-limit | reject-publish dropped requeued messages; settling a message above the max priority closed the connection; priority queues shared delivery counts |
| `spec/consumer_model_spec.cr` | a consumer over AMQP: consume, cancel, prefetch changes, acks, channel close, restart | a consumer stalled when its prefetch was lifted; a lowered prefetch was exceeded |
| `spec/mqtt/matching_model_spec.cr` | `SubscriptionTree` and `TopicTree` against the §4.7 specification | |
| `spec/mqtt/session_model_spec.cr` | a persistent MQTT session: QoS 0/1, reconnects, acks, resubscribes, restart | |

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

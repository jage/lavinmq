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

## Running

Install Lean with [elan](https://github.com/leanprover/elan), then:

```sh
make verify
```

The toolchain is pinned in `lean-toolchain`; only Lean core is used.

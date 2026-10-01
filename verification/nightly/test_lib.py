"""Self-tests for the harness library: codecs offline, clients against a broker.

    python3 verification/nightly/test_lib.py
"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "lib"))
import amqp  # noqa: E402
import broker  # noqa: E402
import mgmt  # noqa: E402
import mqtt  # noqa: E402

PORT = int(os.environ.get("NIGHTLY_TEST_PORT", "29000"))


class Codecs(unittest.TestCase):
    def test_table_round_trip(self):
        value = {"s": b"text", "i": -5, "l": 2**40, "t": True, "d": 1.5, "v": None,
                 "a": [1, b"x"], "f": {"nested": 7}}
        self.assertEqual(amqp.Reader(amqp.table(value)).table(), value)

    def test_method_round_trip(self):
        payload = amqp.method_payload("queue.declare", {"queue": "q", "durable": True, "arguments": {"x": 1}})
        f = amqp.Frame(amqp.FRAME_METHOD, 1, payload)
        self.assertEqual(f.name, "queue.declare")
        self.assertEqual((f.args["queue"], f.args["durable"], f.args["exclusive"]), (b"q", True, False))

    def test_properties_round_trip(self):
        props = {"delivery-mode": 2, "priority": 9, "headers": {"h": b"v"}, "message-id": b"m1"}
        f = amqp.Frame(amqp.FRAME_HEADER, 1, amqp.header_payload(3, props))
        self.assertEqual((f.args["body-size"], f.args["properties"]), (3, props))

    def test_mqtt_publish(self):
        data = mqtt.publish("a/b", b"hi", qos=1, packet_id=7, retain=True)
        p = mqtt.Packet(data[0], data[2:])
        self.assertEqual((p.topic, p.qos, p.packet_id, p.retain, p.payload), ("a/b", 1, 7, True, b"hi"))

    def test_mqtt_remaining_length(self):
        self.assertEqual(mqtt.remaining_length(321), b"\xc1\x02")


@unittest.skipUnless(os.path.exists(broker.BIN), f"no broker binary at {broker.BIN}")
class Clients(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.b = broker.Broker(cls.tmp.name, PORT)
        assert cls.b.start(), cls.b.log()

    @classmethod
    def tearDownClass(cls):
        cls.b.stop()
        cls.tmp.cleanup()

    def test_amqp_publish_get(self):
        c = amqp.Connection(self.b.amqp)
        ch = c.channel(confirm=True)
        c.call(ch, "queue.declare", "queue.declare-ok", queue="q1")
        c.publish(ch, "", "q1", b"body", {"message-id": "m1"})
        c.expect("basic.ack", ch)
        m = c.get(ch, "q1", no_ack=True)
        self.assertEqual((m.body, m.properties["message-id"]), (b"body", b"m1"))
        self.assertIsNone(c.get(ch, "q1"))
        c.close()

    def test_confirms_and_consume(self):
        c = amqp.Connection(self.b.amqp)
        ch = c.channel(confirm=True)
        c.call(ch, "queue.declare", "queue.declare-ok", queue="q3")
        c.publish_confirmed(ch, "", "q3", [(b"%d" % i, {}) for i in range(50)])
        c.publish_confirmed(ch, "", "q3", [(b"50", {})])  # tags continue on the channel
        c.consume(ch, "q3", "t", no_ack=True)
        bodies = [c.next_delivery(ch).body for _ in range(51)]
        self.assertEqual(bodies, [b"%d" % i for i in range(51)])
        self.assertIsNone(c.next_delivery(ch, timeout=0.2))
        c.close()

    def test_mqtt_round_trip(self):
        sub = mqtt.Connection.open(self.b.mqtt, "sub")
        sub.send(mqtt.subscribe(1, [("t/#", 1)]))
        sub.expect(mqtt.SUBACK)
        pub = mqtt.Connection.open(self.b.mqtt, "pub")
        pub.send(mqtt.publish("t/x", b"hello", qos=1, packet_id=3))
        pub.expect(mqtt.PUBACK)
        p = sub.expect(mqtt.PUBLISH)
        self.assertEqual((p.topic, p.payload), ("t/x", b"hello"))
        sub.close()
        pub.close()

    def test_http(self):
        mgmt.put(self.b.http, "/api/queues/%2F/q2", {"durable": True})
        self.assertEqual(mgmt.get_json(self.b.http, "/api/queues/%2F/q2")["name"], "q2")

    def test_no_failures_logged(self):
        self.assertEqual(self.b.failures(), [])


if __name__ == "__main__":
    unittest.main()

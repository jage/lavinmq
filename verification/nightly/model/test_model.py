"""Self-tests for the reference model, offline: small scenarios with known outcomes.

    python3 verification/nightly/model/test_model.py
"""
import os
import sys
import unittest

sys.path[:0] = [os.path.join(os.path.dirname(__file__), "..", "lib"), os.path.dirname(__file__)]
import model as M  # noqa: E402
import ops as O  # noqa: E402
import quirks  # noqa: E402

CH = "c0.1"


def declare(name, **args):
    return {"op": "declare_queue", "ch": CH, "name": name, "passive": False, "durable": True,
            "exclusive": False, "auto_delete": False, "args": args}


def publish(rk, mid, exchange="", ch=CH, **props):
    return {"op": "publish", "ch": ch, "exchange": exchange, "rk": rk, "mid": mid, "body": mid,
            "props": {"delivery-mode": 2, "message-id": mid, **props}, "mandatory": False}


def get(queue, no_ack=False):
    return {"op": "get", "ch": CH, "queue": queue, "no_ack": no_ack}


def settle(kind, tag, requeue=False):
    return {"op": kind, "ch": CH, "tag": tag, "multiple": False, "requeue": requeue}


def consume(queue, tag, ch=CH, priority=0):
    return {"op": "consume", "ch": ch, "queue": queue, "tag": tag, "no_ack": False, "exclusive": False,
            "priority": priority}


class Scenario(unittest.TestCase):
    def setUp(self):
        quirks.strict([])  # every quirk on
        self.m = M.Model()

    def tearDown(self):
        quirks.strict([])

    def do(self, *ops):
        replies = []
        for op in ops:
            replies.append(O.apply(self.m, op))
            self.m.dispatch()
        return replies

    def events(self):
        return self.m.take_events().get(CH, [])

    def ready(self, queue):
        return [m.id for m in self.m.queues[queue].ready]


class Routing(unittest.TestCase):
    def test_topic(self):
        self.assertTrue(M.topic_match("a.#", "a"))
        self.assertTrue(M.topic_match("*.b.*", "a.b.c"))
        self.assertFalse(M.topic_match("a.*", "a.b.c"))
        self.assertTrue(M.topic_match("#.c", "c"))

    def test_headers(self):
        self.assertTrue(M.headers_match({"x-match": "all", "h1": "1"}, {"h1": "1", "h2": "2"}))
        self.assertFalse(M.headers_match({"x-match": "all", "h1": "1", "h2": "1"}, {"h1": "1"}))
        self.assertTrue(M.headers_match({"x-match": "any", "h1": "1", "h2": "1"}, {"h1": "1"}))
        self.assertTrue(M.headers_match({"x-match": "all"}, {}))


class Queues(Scenario):
    def test_fifo_and_requeue_keeps_position(self):
        self.do(declare("q"), publish("q", "m1"), publish("q", "m2"), publish("q", "m3"))
        first = self.do(get("q"))[0]
        self.assertEqual(first[5], "m1")
        self.do(settle("reject", first[1], requeue=True))
        self.assertEqual(self.ready("q"), ["m1", "m2", "m3"])
        self.assertTrue(self.m.queues["q"].ready[0].redelivered)

    def test_reject_dead_letters_with_x_death(self):
        self.do(declare("dlq"), declare("q", **{"x-dead-letter-exchange": "", "x-dead-letter-routing-key": "dlq"}),
                publish("q", "m1"))
        tag = self.do(get("q"))[0][1]
        self.do(settle("reject", tag))
        dead = self.m.queues["dlq"].ready[0]
        death = dead.props["headers"]["x-death"][0]
        self.assertEqual((death["queue"], death["reason"], death["count"]), ("q", "rejected", 1))
        self.assertEqual(dead.props["headers"]["x-first-death-reason"], "rejected")

    def test_max_length_drops_the_oldest(self):
        self.do(declare("dlq"), declare("q", **{"x-max-length": 2, "x-dead-letter-exchange": "",
                                                "x-dead-letter-routing-key": "dlq"}),
                publish("q", "m1"), publish("q", "m2"), publish("q", "m3"))
        self.assertEqual(self.ready("q"), ["m2", "m3"])
        self.assertEqual(self.ready("dlq"), ["m1"])
        self.assertEqual(self.m.queues["dlq"].ready[0].props["headers"]["x-death"][0]["reason"], "maxlen")

    def test_reject_publish_nacks(self):
        self.do({"op": "confirm_select", "ch": CH}, declare("q", **{"x-max-length": 1, "x-overflow": "reject-publish"}),
                publish("q", "m1"), publish("q", "m2"))
        self.assertEqual([e for e in self.events() if e[0] == "confirm"],
                         [("confirm", 1, "ack"), ("confirm", 2, "nack")])
        self.assertEqual(self.ready("q"), ["m1"])

    def test_priorities_order_and_clamp(self):
        self.do(declare("q", **{"x-max-priority": 2}), publish("q", "low"), publish("q", "high", priority=2),
                publish("q", "above", priority=9))
        self.assertEqual(self.ready("q"), ["high", "above", "low"])

    def test_prefetch_holds_deliveries(self):
        self.do(declare("q"), {"op": "qos", "ch": CH, "prefetch": 1, "global": False}, consume("q", "t"),
                publish("q", "m1"), publish("q", "m2"))
        delivered = [e for e in self.events() if e[0] == "deliver"]
        self.assertEqual([e[6] for e in delivered], ["m1"])
        self.do(settle("ack", delivered[0][2]))
        self.assertEqual([e[6] for e in self.events() if e[0] == "deliver"], ["m2"])

    def test_transactions(self):
        self.do(declare("q"), {"op": "tx_select", "ch": CH}, publish("q", "m1"))
        self.assertEqual(self.ready("q"), [])
        self.do({"op": "tx_rollback", "ch": CH}, publish("q", "m2"), {"op": "tx_commit", "ch": CH})
        self.assertEqual(self.ready("q"), ["m2"])

    def test_restart_keeps_durable_state_only(self):
        self.do(declare("q"), {**declare("t"), "durable": False}, publish("q", "m1"))
        tag = self.do(get("q"))[0][1]
        self.do(settle("reject", tag, requeue=True), {"op": "restart"})
        self.assertNotIn("t", self.m.queues)
        self.assertEqual(self.m.redelivered(self.m.queues["q"].ready[0]), "?")

    def test_single_active_consumer(self):
        self.do(declare("q", **{"x-single-active-consumer": True}), consume("q", "a", priority=1),
                consume("q", "b", ch="c1.1", priority=2), publish("q", "m1"))
        self.assertEqual([e[1] for e in self.events() if e[0] == "deliver"], ["a"])


class QuirkSwitches(Scenario):
    def test_overflow_policy_precedence(self):
        self.do(declare("q", **{"x-overflow": "reject-publish"}))
        self.m.policies["p"] = ("^q$", {"overflow": "drop-head"}, 1, "queues")
        self.m.apply_policies()
        self.assertEqual(self.m.queues["q"].overflow, "drop-head")
        quirks.strict(["overflow-policy-wins"])
        self.assertEqual(self.m.queues["q"].overflow, "reject-publish")

    def test_max_length_bytes_counts(self):
        msg = M.Msg("m", "12345", {"message-id": "m"}, "", "q", ["q"])
        whole = msg.bytesize()
        quirks.strict(["max-length-bytes-whole-message"])
        self.assertEqual(msg.bytesize(), 5)
        self.assertGreater(whole, 5)

    def test_duplicate_consumer_tag(self):
        self.do(declare("q"), consume("q", "t"))
        again = consume("q", "t", priority=1)  # equal priorities are skipped for another reason
        self.assertIsNone(O.resolve(again, self.m))
        quirks.strict(["duplicate-consumer-tag"])
        op = O.resolve(again, self.m)
        self.assertEqual(self.do(op), [("connclose", M.NOT_ALLOWED)])

    def test_strict_all_keeps_hazards(self):
        off = quirks.strict(["all"])
        self.assertNotIn("dead-letter-ping-pong", off)
        self.assertTrue(quirks.on("dead-letter-ping-pong"))
        self.assertFalse(quirks.on("bcc-stored"))


class Generation(unittest.TestCase):
    def test_generates_valid_ops(self):
        ops = O.generate(7, 200, M.Model)
        self.assertEqual(len(ops), 200)
        self.assertEqual(O.generate(7, 200, M.Model), ops)  # deterministic per seed


if __name__ == "__main__":
    unittest.main()

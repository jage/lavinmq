"""The seed workload, and a dump of everything a broker holds, for comparing a
broker started on a damaged data dir with one started on the intact seed.

Every message body checks itself: b"N1|<crc32>|<store>|<seq>|<padding>", where
the CRC covers everything after it. A dump decodes each body, so a corrupt one
is caught, and records which store and sequence number it came from."""
import json
import random
import re
import zlib

import amqp
import mgmt
import mqtt

BODY = re.compile(rb"N1\|([0-9a-f]{8})\|")
POKE = 900000  # sequence numbers of messages published after the damage
STREAM_TRACKERS = {"c1": 100, "c2": 700, "c3": 1500}  # consumer tag: messages acked
QUEUES = ["q.classic", "q.prio", "q.src", "q.dlx"]


class Corrupt(ValueError):
    pass


def body(store, seq, padding):
    payload = f"{store}|{seq}|".encode() + b"x" * padding
    return b"N1|%08x|" % zlib.crc32(payload) + payload


def parse(data):
    """(store, seq) of a body; raises Corrupt if it doesn't check out."""
    m = BODY.match(data)
    if not m or int(m.group(1), 16) != zlib.crc32(data[m.end():]):
        raise Corrupt(repr(data[:60]))
    store, seq, _ = data[m.end():].split(b"|", 2)
    return store.decode(), int(seq)


def record_ends(data):
    """(end offset, store, seq) of every intact body in a file, in file order."""
    out = []
    for m in BODY.finditer(data):
        crc = int(m.group(1), 16)
        head = data[m.end():m.end() + 40].split(b"|", 2)
        if len(head) < 3:
            continue
        # the padding runs to the record's end, and the CRC says where that is
        start = m.end()
        end = start + len(head[0]) + len(head[1]) + 2
        while end <= len(data) and data[end:end + 1] == b"x":
            end += 1
        while end > start and zlib.crc32(data[start:end]) != crc:
            end -= 1
        if end > start:
            out.append((end, head[0].decode(), int(head[1])))
    return out


# -- seed ---------------------------------------------------------------------

def seed(b):
    """Fill a fresh broker with every kind of persistent state."""
    rng = random.Random(1)
    pad = lambda: rng.randrange(20, 600)  # noqa: E731
    durable = {"delivery-mode": 2}
    c = amqp.Connection(b.amqp)
    ch = c.channel(confirm=True)

    c.call(ch, "queue.declare", "queue.declare-ok", queue="q.classic", durable=True)
    c.publish_confirmed(ch, "", "q.classic", [(body("q.classic", i, pad()), durable) for i in range(3000)])
    # ack the even ones of the first 1500; closing the channel requeues the odd ones
    g = c.channel(2)
    for _ in range(1500):
        m = c.get(g, "q.classic")
        if parse(m.body)[1] % 2 == 0:
            c.send(g, "basic.ack", **{"delivery-tag": m.delivery_tag})
    c.call(g, "channel.close", "channel.close-ok")

    c.call(ch, "queue.declare", "queue.declare-ok", queue="q.prio", durable=True,
           arguments={"x-max-priority": 5})
    # priorities 6 and 7 are above the max, and are stored at the max
    c.publish_confirmed(ch, "", "q.prio", [(body("q.prio", i, pad()), {"delivery-mode": 2, "priority": i % 8})
                                           for i in range(1500)])

    c.call(ch, "queue.declare", "queue.declare-ok", queue="q.stream", durable=True,
           arguments={"x-queue-type": "stream"})
    c.publish_confirmed(ch, "", "q.stream", [(body("q.stream", i, pad()), durable) for i in range(3000)])
    for n, (tag, count) in enumerate(STREAM_TRACKERS.items(), start=10):
        s = c.channel(n, prefetch=count)
        c.consume(s, "q.stream", tag, arguments={"x-stream-offset": "first",
                                                 "x-stream-automatic-offset-tracking": True})
        for _ in range(count):
            m = c.next_delivery(s)
            c.send(s, "basic.ack", **{"delivery-tag": m.delivery_tag})
        c.call(s, "channel.close", "channel.close-ok")

    # dead-lettering: 200 of q.src's messages are rejected into q.dlx
    c.call(ch, "queue.declare", "queue.declare-ok", queue="q.dlx", durable=True)
    c.call(ch, "queue.declare", "queue.declare-ok", queue="q.src", durable=True,
           arguments={"x-dead-letter-exchange": "", "x-dead-letter-routing-key": "q.dlx"})
    c.publish_confirmed(ch, "", "q.src", [(body("q.src", i, pad()), durable) for i in range(300)])
    r = c.channel(3)
    for _ in range(200):
        m = c.get(r, "q.src")
        c.send(r, "basic.reject", **{"delivery-tag": m.delivery_tag, "requeue": False})
    c.call(r, "channel.close", "channel.close-ok")

    # delayed messages, due long after the run
    c.call(ch, "exchange.declare", "exchange.declare-ok", exchange="x.delay", type="x-delayed-message",
           durable=True, arguments={"x-delayed-type": "direct"})
    c.call(ch, "queue.declare", "queue.declare-ok", queue="q.delayed", durable=True)
    c.call(ch, "queue.bind", "queue.bind-ok", queue="q.delayed", exchange="x.delay", **{"routing-key": "d"})
    c.publish_confirmed(ch, "x.delay", "d", [(body("q.delayed", i, pad()),
                                              {"delivery-mode": 2, "headers": {"x-delay": 86_400_000}})
                                             for i in range(50)])
    c.close()

    # MQTT: two persistent sessions with queued messages, and retained messages
    for client_id, topic in (("sess1", "s1/#"), ("sess2", "s2/#")):
        s = mqtt.Connection.open(b.mqtt, client_id, clean=False)
        s.send(mqtt.subscribe(1, [(topic, 1)]))
        s.expect(mqtt.SUBACK)
        s.send(mqtt.DISCONNECT)
        s.close()
    p = mqtt.Connection.open(b.mqtt, "publisher")
    packet_id = 0
    for store, topic, n in (("sess1", "s1/x", 400), ("sess2", "s2/x", 400)):
        for i in range(n):
            packet_id = packet_id % 65535 + 1
            p.send(mqtt.publish(topic, body(store, i, pad()), qos=1, packet_id=packet_id))
            p.expect(mqtt.PUBACK)
    for i in range(20):
        p.send(mqtt.publish(f"r/{i}", body("retained", i, pad()), qos=1, packet_id=i + 1, retain=True))
        p.expect(mqtt.PUBACK)
    p.send(mqtt.publish("r/3", b"", qos=1, packet_id=21, retain=True))  # cleared
    p.expect(mqtt.PUBACK)
    p.send(mqtt.publish("r/7", body("retained", 107, 33), qos=1, packet_id=22, retain=True))  # replaced
    p.expect(mqtt.PUBACK)
    p.send(mqtt.DISCONNECT)
    p.close()

    # definitions over the management API
    h = b.http
    mgmt.put(h, "/api/users/u1", {"password": "p1", "tags": "management"})
    mgmt.put(h, "/api/users/u2", {"password": "p2", "tags": ""})
    mgmt.put(h, "/api/vhosts/v2", {})
    mgmt.put(h, "/api/permissions/v2/u1", {"configure": ".*", "write": ".*", "read": ".*"})
    mgmt.put(h, "/api/permissions/%2F/u1", {"configure": "^q", "write": ".*", "read": ".*"})
    mgmt.put(h, "/api/policies/%2F/p1", {"pattern": r"^q\.pol", "definition": {"max-length": 10},
                                         "apply-to": "queues", "priority": 1})
    mgmt.put(h, "/api/policies/v2/p2", {"pattern": ".*", "definition": {"message-ttl": 999999},
                                        "apply-to": "queues"})
    mgmt.put(h, "/api/operator-policies/%2F/op1", {"pattern": "^zz", "definition": {"max-length": 100},
                                                   "apply-to": "queues"})
    mgmt.put(h, "/api/global-parameters/gp1", {"value": "gv1"})
    mgmt.put(h, "/api/vhost-limits/v2/max-queues", {"value": 50})
    mgmt.put(h, "/api/queues/v2/v2q", {"durable": True})
    mgmt.put(h, "/api/exchanges/v2/v2x", {"type": "topic", "durable": True})
    status, reply = mgmt.call(h, "POST", "/api/bindings/v2/e/v2x/q/v2q", {"routing_key": "a.#"})
    if status != 201:
        raise RuntimeError(f"binding: {status} {reply!r}")


def poke(b):
    """After the damage: publish a few confirmed messages, which must survive a kill -9."""
    c = amqp.Connection(b.amqp)
    ch = c.channel(confirm=True)
    for q in ("q.classic", "q.prio", "q.stream"):
        c.publish_confirmed(ch, "", q, [(body(q, POKE + i, 10), {"delivery-mode": 2}) for i in range(5)])
    c.close()


# -- dump ---------------------------------------------------------------------

def dump(b):
    """Everything the broker holds, read back over AMQP, MQTT and HTTP. Destructive:
    it consumes the messages. Problems reading are collected, not raised."""
    out = {"queues": {}, "corrupt": [], "errors": []}

    def guard(what, fn):
        try:
            fn()
        except Exception as e:  # anything a broken broker can do to a client
            out["errors"].append(f"{what}: {type(e).__name__}: {str(e)[:200]}")

    def read(data, where):
        try:
            return parse(data)
        except Corrupt as e:
            out["corrupt"].append(f"{where}: {e}")
            return None

    def queue(name):
        # a connection each, so one queue closing it can't fail the others
        ids = out["queues"][name] = []
        c = amqp.Connection(b.amqp)
        try:
            ch = c.channel()
            while (m := c.get(ch, name, no_ack=True)) is not None:
                if (r := read(m.body, name)) is not None:
                    ids.append(r)
        finally:
            c.close()

    def stream():
        c = amqp.Connection(b.amqp)
        ids = out["queues"]["q.stream"] = []
        ch = c.channel(1, prefetch=1000)
        c.consume(ch, "q.stream", "reader", arguments={"x-stream-offset": "first"})
        while (m := c.next_delivery(ch, timeout=1)) is not None:
            if (r := read(m.body, "q.stream")) is not None:
                ids.append(r)
            c.send(ch, "basic.ack", **{"delivery-tag": m.delivery_tag})
        c.close()

    def offsets():
        found = out["stream_offsets"] = {}
        c = amqp.Connection(b.amqp)
        for n, tag in enumerate(STREAM_TRACKERS, start=1):
            ch = c.channel(n, prefetch=1)
            c.consume(ch, "q.stream", tag)  # resumes at the stored offset
            m = c.next_delivery(ch, timeout=1)
            found[tag] = m.properties["headers"].get("x-stream-offset") if m else None
            c.call(ch, "channel.close", "channel.close-ok")
        c.close()

    def sessions():
        for client_id in ("sess1", "sess2"):
            ids = out["queues"]["mqtt:" + client_id] = []
            s = mqtt.Connection.open(b.mqtt, client_id, clean=False)
            for p in s.drain(1):
                if p.type == mqtt.PUBLISH:
                    if (r := read(p.payload, client_id)) is not None:
                        ids.append(r)
                    if p.qos:
                        s.send(mqtt.puback(p.packet_id))
            s.close()

    def retained():
        found = out["retained"] = {}
        s = mqtt.Connection.open(b.mqtt, "retain-reader")
        s.send(mqtt.subscribe(1, [("r/#", 0)]))
        for p in s.drain(1):
            if p.type == mqtt.PUBLISH and p.retain:
                r = read(p.payload, p.topic)
                found[p.topic] = r[1] if r else "corrupt"
        s.close()

    def delayed():
        q = mgmt.get_json(b.http, "/api/queues/%2F/amq.delayed-x.delay")
        out["delayed"] = q.get("messages")

    def definitions():
        d = mgmt.get_json(b.http, "/api/definitions")
        for u in d.get("users", []):
            u.pop("password_hash", None)
        out["definitions"] = {k: sorted(json.dumps(i, sort_keys=True) for i in v)
                              for k, v in d.items() if isinstance(v, list)}

    for name in QUEUES:
        guard(name, lambda: queue(name))
    for what, fn in (("stream", stream), ("offsets", offsets),
                     ("sessions", sessions), ("retained", retained), ("delayed", delayed),
                     ("definitions", definitions)):
        guard(what, fn)
    return out

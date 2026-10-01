"""The system under test: applies ops to a running broker over AMQP and the
management API, and reports what a client observes in the same shape the
model does."""
import json
import time

import amqp
import mgmt
from amqp import FRAME_BODY, FRAME_HEADER, FRAME_METHOD, Closed


class Client:
    """One AMQP connection. Deliveries, returns, confirms and cancels collect as
    events per channel; replies to synchronous methods queue up per channel."""

    def __init__(self, port, vhost):
        self.c = amqp.Connection(port, vhost=vhost)
        self.open = set()
        self.pending = {}   # channel -> [method, args, properties, body, size] being assembled
        self.replies = {}
        self.events = {}
        self.dead = None

    def pump(self, timeout):
        try:
            self.c._read(timeout)
            self.c._parse()
        except Closed:
            self.dead = self.dead or ("eof",)
        frames, self.c.frames = self.c.frames, []
        for f in frames:
            self.handle(f)

    def event(self, ch, e):
        self.events.setdefault(ch, []).append(e)

    def handle(self, f):
        ch = f.channel
        if f.type == FRAME_METHOD:
            n = f.name
            if n in ("basic.deliver", "basic.return", "basic.get-ok"):
                self.pending[ch] = [n, f.args, None, b"", 0]
            elif n in ("basic.ack", "basic.nack"):
                self.event(ch, ("confirm-raw", f.args["delivery-tag"], f.args["multiple"],
                                "ack" if n == "basic.ack" else "nack"))
            elif n == "basic.cancel":
                self.event(ch, ("cancel", f.args["consumer-tag"].decode()))
            elif n == "channel.close":
                try:
                    self.c.send(ch, "channel.close-ok")
                except Closed:
                    pass
                self.open.discard(ch)
                self.replies.setdefault(ch, []).append(("close", f.args["reply-code"]))
            elif n == "connection.close":
                self.dead = ("connection.close", f.args.get("reply-code"))
            else:
                self.replies.setdefault(ch, []).append(f)
        elif f.type == FRAME_HEADER and ch in self.pending:
            p = self.pending[ch]
            p[2], p[4] = f.args["properties"], f.args["body-size"]
            if p[4] == 0:
                self.complete(ch)
        elif f.type == FRAME_BODY and ch in self.pending:
            p = self.pending[ch]
            p[3] += f.payload
            if len(p[3]) >= p[4]:
                self.complete(ch)

    def complete(self, ch):
        n, a, props, body, _ = self.pending.pop(ch)
        mid = body.decode().split("_")[0]
        where = (a["exchange"].decode(), a["routing-key"].decode())
        if n == "basic.deliver":
            self.event(ch, ("deliver", a["consumer-tag"].decode(), a["delivery-tag"], a["redelivered"],
                            *where, mid, props))
        elif n == "basic.return":
            self.event(ch, ("return", a["reply-code"], *where, mid))
        else:
            self.replies.setdefault(ch, []).append(("get-ok", a["delivery-tag"], a["redelivered"], *where, mid,
                                                    props, a["message-count"]))

    def call(self, ch, name, timeout=5, **args):
        self.replies[ch] = []
        self.c.send(ch, name, **args)
        return self.wait(ch, timeout)

    def wait(self, ch, timeout=5):
        deadline = time.monotonic() + timeout
        while True:
            if self.replies.get(ch):
                return self.replies[ch].pop(0)
            if self.dead:
                return ("connclose",) + tuple(self.dead[1:2])
            left = deadline - time.monotonic()
            if left <= 0:
                return ("timeout",)
            self.pump(min(left, 0.05))


def reply(r):
    """A method frame as the model's reply tuple."""
    if isinstance(r, tuple):
        return r
    n, a = r.name, r.args
    if n == "queue.declare-ok":
        return ("ok", a["message-count"], a["consumer-count"])
    if n in ("queue.delete-ok", "queue.purge-ok"):
        return ("ok", a["message-count"])
    if n in ("exchange.declare-ok", "exchange.delete-ok", "queue.bind-ok", "queue.unbind-ok",
             "exchange.bind-ok", "exchange.unbind-ok"):
        return ("ok",)
    if n in ("basic.consume-ok", "basic.cancel-ok"):
        return (n.split(".")[1], a["consumer-tag"].decode())
    if n == "channel.flow-ok":
        return ("flow-ok", a["active"])
    simple = {"basic.get-empty": "get-empty", "basic.recover-ok": "recover-ok", "basic.qos-ok": "qos-ok",
              "confirm.select-ok": "select-ok", "tx.select-ok": "tx-select-ok", "tx.commit-ok": "commit-ok",
              "tx.rollback-ok": "rollback-ok"}
    return (simple[n],) if n in simple else ("frame", n)


class Sut:
    def __init__(self, broker, vhost, model):
        self.b = broker
        self.vhost = vhost
        self.model = model  # to know which policy each queue and exchange should end up with
        self.clients = {}

    def client(self, name):
        c = self.clients.get(name)
        if c is None or c.dead:
            c = self.clients[name] = Client(self.b.amqp, self.vhost)
        return c

    def channel(self, cid):
        name, n = cid.split(".")
        c = self.client(name)
        n = int(n)
        if n not in c.open:
            r = c.call(n, "channel.open")
            if getattr(r, "name", None) != "channel.open-ok":
                raise RuntimeError(f"channel.open: {r}")
            c.open.add(n)
        return c, n

    def pump(self, timeout):
        for c in list(self.clients.values()):
            c.pump(0)
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            for c in list(self.clients.values()):
                c.pump(0.005)

    def take_events(self):
        out = {}
        for name, c in self.clients.items():
            for ch, events in c.events.items():
                out.setdefault(f"{name}.{ch}", []).extend(events)
            c.events = {}
        return out

    def close(self):
        for c in self.clients.values():
            c.c.close()
        self.clients = {}

    def barrier(self, c, n):
        """A synchronous round trip, so the broker has handled what was sent before."""
        return reply(c.call(n, "exchange.declare", exchange="amq.direct", type="direct", passive=True))

    def wait_for_policies(self, timeout=10):
        """Policies are applied in a fiber: wait until every queue and exchange the
        model knows shows the policy the model expects."""
        def expected(kind, name):
            best = self.model.effective_policy(kind, name)
            return (best[0], json.dumps(best[1], sort_keys=True)) if best else (None, "{}")
        deadline = time.monotonic() + timeout
        while True:
            pending = []
            for kind, known in (("queues", self.model.queues), ("exchanges", self.model.exchanges)):
                for item in mgmt.get_json(self.b.http, f"/api/{kind}/{self.vhost}"):
                    if item["name"] in known:
                        got = (item.get("policy"), json.dumps(item.get("effective_policy_definition") or {},
                                                              sort_keys=True))
                        if got != expected(kind, item["name"]):
                            pending.append(item["name"])
            if not pending:
                return
            if time.monotonic() > deadline:
                raise RuntimeError(f"policies not applied to {pending}")
            time.sleep(0.02)

    def apply(self, op):
        k = op["op"]
        if k == "sleep":
            time.sleep(op["ms"] / 1000)
            return ("ok",)
        if k == "restart":
            self.close()
            self.b.stop()
            if not self.b.start():
                raise RuntimeError("broker didn't start again")
            return ("ok",)
        if k == "close_conn":
            c = self.clients.pop(op["conn"], None)
            if c and not c.dead:
                c.call(0, "connection.close", **{"reply-code": 200, "reply-text": "bye"})
                c.c.close()
            return ("ok",)
        if k in ("set_policy", "del_policy"):
            path = f"/api/policies/{self.vhost}/{op['name']}"
            if k == "set_policy":
                status, body = mgmt.call(self.b.http, "PUT", path, {
                    "pattern": op["pattern"], "definition": op["definition"], "priority": op["priority"],
                    "apply-to": op["apply_to"]})
            else:
                status, body = mgmt.call(self.b.http, "DELETE", path)
            if status is None or (status >= 300 and not (k == "del_policy" and status == 404)):
                return ("http", status, body[:200].decode("utf-8", "replace"))
            self.wait_for_policies()
            return ("ok",)
        c, n = self.channel(op["ch"])
        if k == "declare_queue":
            a = {"queue": op["name"], "passive": op["passive"]}
            if not op["passive"]:
                a.update(durable=op["durable"], exclusive=op["exclusive"], arguments=op["args"])
                a["auto-delete"] = op["auto_delete"]
            return reply(c.call(n, "queue.declare", **a))
        if k == "delete_queue":
            return reply(c.call(n, "queue.delete", queue=op["name"],
                                **{"if-unused": op["if_unused"], "if-empty": op["if_empty"]}))
        if k == "purge":
            return reply(c.call(n, "queue.purge", queue=op["name"]))
        if k == "declare_exchange":
            a = {"exchange": op["name"], "type": op.get("type", "direct"), "passive": op["passive"]}
            if not op["passive"]:
                a.update(durable=op["durable"], internal=op["internal"], arguments=op["args"])
                a["auto-delete"] = op["auto_delete"]
            return reply(c.call(n, "exchange.declare", **a))
        if k == "delete_exchange":
            return reply(c.call(n, "exchange.delete", exchange=op["name"], **{"if-unused": op["if_unused"]}))
        if k in ("bind_queue", "unbind_queue"):
            return reply(c.call(n, "queue.bind" if k == "bind_queue" else "queue.unbind", queue=op["queue"],
                                exchange=op["exchange"], arguments=op["args"], **{"routing-key": op["key"]}))
        if k in ("bind_exchange", "unbind_exchange"):
            return reply(c.call(n, "exchange.bind" if k == "bind_exchange" else "exchange.unbind",
                                destination=op["dest"], source=op["src"], arguments=op["args"],
                                **{"routing-key": op["key"]}))
        if k == "publish":
            c.c.publish(n, op["exchange"], op["rk"], op["body"].encode(), op["props"], mandatory=op["mandatory"])
            return self.barrier(c, n)
        if k == "get":
            return reply(c.call(n, "basic.get", queue=op["queue"], **{"no-ack": op["no_ack"]}))
        if k == "consume":
            args = {"x-priority": op["priority"]} if op["priority"] else {}
            return reply(c.call(n, "basic.consume", queue=op["queue"], exclusive=op["exclusive"], arguments=args,
                                **{"consumer-tag": op["tag"], "no-ack": op["no_ack"]}))
        if k == "cancel":
            return reply(c.call(n, "basic.cancel", **{"consumer-tag": op["tag"]}))
        if k in ("ack", "nack", "reject", "ack_bad", "ack_all"):
            tag = op.get("sut_tag", op.get("tag", 0))
            if k == "ack_bad":
                c.c.send(n, "basic.ack", **{"delivery-tag": 10 ** 6})
            elif k == "ack_all":
                c.c.send(n, "basic.ack", **{"delivery-tag": 0, "multiple": True})
            elif k == "ack":
                c.c.send(n, "basic.ack", **{"delivery-tag": tag, "multiple": op["multiple"]})
            elif k == "nack":
                c.c.send(n, "basic.nack", **{"delivery-tag": tag, "multiple": op["multiple"],
                                             "requeue": op["requeue"]})
            else:
                c.c.send(n, "basic.reject", **{"delivery-tag": tag, "requeue": op["requeue"]})
            return self.barrier(c, n)
        if k == "recover":
            return reply(c.call(n, "basic.recover", requeue=op["requeue"]))
        if k == "qos":
            return reply(c.call(n, "basic.qos", **{"prefetch-count": op["prefetch"], "global": op["global"]}))
        if k == "flow":
            return reply(c.call(n, "channel.flow", active=op["active"]))
        if k in ("confirm_select", "tx_select", "tx_commit", "tx_rollback"):
            return reply(c.call(n, k.replace("_", ".")))
        if k == "close_channel":
            r = c.call(n, "channel.close", **{"reply-code": 200, "reply-text": "bye"})
            c.open.discard(n)
            return ("ok",) if getattr(r, "name", None) == "channel.close-ok" else reply(r)
        raise ValueError(f"unknown op {k}")

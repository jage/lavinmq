"""Ops: generated at random, resolved against the model so a shrunk sequence
stays valid, and applied to the model."""
import copy
import random

from model import (ACCESS_REFUSED, NOT_ALLOWED, NOT_FOUND, PRECONDITION_FAILED, RESOURCE_LOCKED, LONG_TTL,
                   SHORT_TTL, ChannelError, ConnectionError_, Consumer, DeadLetterLoop, Exchange, Queue)
from quirks import on

QUEUES = ["q0", "q1", "q2", "q3", "q4"]
EXCHANGES = ["x0", "x1", "x2", "x3"]
CHANNELS = ["c0.1", "c0.2", "c1.1", "c1.2"]
CONNS = ["c0", "c1"]
ROUTING_KEYS = ["a", "b", "a.b", "a.b.c", "b.c"] + QUEUES
TOPIC_KEYS = ["*", "#", "a.*", "a.#", "#.c", "*.b.*", "a.b.c", "b"]


def resolve(op, m):
    """Make op concrete against the model's state: pick the delivery or consumer
    tag it refers to, or None to skip an op that can't apply or that a quirk avoids."""
    op = dict(op)
    k = op["op"]
    ch = m.channels.get(op.get("ch"))
    if k in ("ack", "nack", "reject"):
        tags = [t for t in sorted(ch.unacked) if t not in ch.tx_pending] if ch and ch.open else []
        if not tags:
            return None
        op["tag"] = tags[op["ref"] % len(tags)]
    elif k == "cancel":
        if not ch or not ch.consumers:
            return None
        tags = sorted(ch.consumers)
        op["tag"] = tags[op["ref"] % len(tags)]
    elif k == "consume":
        q = m.queues.get(op["queue"])
        if ch and op["tag"] in ch.consumers and on("duplicate-consumer-tag"):
            return None
        if q and q.consumers and op["exclusive"] and on("exclusive-consume-beside-others"):
            return None
        if q and not q.single_active and any(c.priority == op["priority"] for c in q.consumers):
            return None  # with equal priorities, which consumer gets a message isn't defined
        if ch and ch.global_prefetch and ch.consumers:
            return None  # how a global prefetch is shared between consumers isn't defined
    elif k == "qos":
        if op["global"] and ch and len(ch.consumers) > 1:
            return None
        if not op["global"] and ch and op["prefetch"] and on("qos-below-unacked") and \
                any(c.unacked >= op["prefetch"] for c in ch.consumers.values()):
            return None
        if not op["global"] and not op["prefetch"] and ch and on("qos-zero-spins") and \
                any(c.unacked for c in ch.consumers.values()):
            return None
    elif k == "recover":
        if op["requeue"] and ch and ch.tx_pending and on("recover-in-tx-loses-acks"):
            return None
        if not op["requeue"] and ch and on("recover-no-requeue-541") and \
                any(c is not None for (_q, _m, c) in ch.unacked.values()):
            return None
    elif k == "publish":
        x = m.exchanges.get(op["exchange"])
        headers = op["props"].get("headers") or {}
        if ch and ch.tx and x is not None and x.type == "x-delayed-message" and "x-delay" in headers and \
                on("tx-delayed-corrupts"):
            return None
        q = m.queues.get(op["rk"]) if not op["exchange"] else None
        if q is not None and q.overflow != "drop-head" and op["props"].get("expiration") == "0":
            return None  # the model's expiry timing for this is approximate
    elif k == "restart":
        if on("delivery-count-lost-on-restart") and any(q.delivery_limit is not None for q in m.queues.values()):
            return None
    elif k == "ack_all":
        if ch and ch.tx and on("tx-ack-all-541"):
            return None
    return op


def safe(m, op):
    """Whether applying op leaves the model in a state LavinMQ survives: with the
    dead-letter-ping-pong quirk on, ops that start an endless loop, at once or
    paced by TTLs over the next seconds, are skipped."""
    if not on("dead-letter-ping-pong"):
        return True
    trial = copy.deepcopy(m)
    try:
        apply(trial, op)
        trial.dispatch()
        for _ in range(10):
            trial.advance(trial.now + 0.5)
    except DeadLetterLoop:
        return False
    return True


def apply(m, op):
    """Apply a resolved op to the model; returns the synchronous reply."""
    k = op["op"]
    if k == "sleep":
        return ("ok",)
    if k == "restart":
        m.restart()
        return ("ok",)
    if k == "close_conn":
        m.close_conn(op["conn"])
        return ("ok",)
    if k in ("set_policy", "del_policy"):
        if k == "set_policy":
            m.policies[op["name"]] = (op["pattern"], op["definition"], op["priority"], op["apply_to"])
        else:
            m.policies.pop(op["name"], None)
        m.apply_policies()
        return ("ok",)
    cid = op["ch"]
    ch = m.ch(cid)
    ch.open = True
    try:
        return _apply_on_channel(m, ch, cid, op)
    except ChannelError as e:
        m.close_channel(cid)
        return ("close", e.code)
    except ConnectionError_ as e:
        m.close_conn(ch.conn)
        return ("connclose", e.code)


def _bind(m, kind, op, ch):
    if kind == "q":
        b = ("q", op["queue"], op["exchange"], op["key"], frozenset(op["args"].items()))
        source = op["exchange"]
    else:
        b = ("x", op["dest"], op["src"], op["key"], frozenset(op["args"].items()))
        source = op["src"]
    if not op["op"].startswith("unbind"):
        if m.exchanges[source].route_type == "headers" and on("x-match-with-x") and \
                str(op["args"].get("x-match", "")).endswith("-with-x"):
            raise ChannelError(PRECONDITION_FAILED)
        if b not in m.bindings:
            m.bind_seq[b] = len(m.bind_seq) + 1
        m.bindings.add(b)
        m.exchanges[source].had_binding = True
    else:
        m.bindings.discard(b)
        m.bind_seq.pop(b, None)
        m.auto_delete_exchanges()
    return ("ok",)


def _apply_on_channel(m, ch, cid, op):
    k = op["op"]
    conn = ch.conn
    if k == "declare_queue":
        name = op["name"]
        if op["passive"]:
            q = m.queue(name, cid)
            return ("ok", len(q.ready), len(q.consumers))
        if name.startswith("amq."):
            raise ChannelError(ACCESS_REFUSED)
        q = m.queues.get(name)
        if q is not None and q.exclusive_conn is not None and q.exclusive_conn != conn:
            raise ChannelError(RESOURCE_LOCKED)
        if "x-dead-letter-routing-key" in op["args"] and "x-dead-letter-exchange" not in op["args"]:
            raise ChannelError(PRECONDITION_FAILED)
        if q is not None:
            if (q.exclusive_conn is not None) != op["exclusive"]:
                raise ChannelError(RESOURCE_LOCKED)
            if (q.durable, q.auto_delete, q.args) != (op["durable"], op["auto_delete"], op["args"]):
                raise ChannelError(PRECONDITION_FAILED)
            return ("ok", len(q.ready), len(q.consumers))
        q = m.queues[name] = Queue(name, op["durable"], conn if op["exclusive"] else None, op["auto_delete"],
                                   dict(op["args"]))
        m.bindings.add(("q", name, "", name, frozenset()))  # the default exchange's binding
        m.apply_policies(only=q)
        return ("ok", 0, 0)
    if k == "delete_queue":
        q = m.queues.get(op["name"])
        if q is None:
            return ("ok", 0)
        m.queue(op["name"], cid)
        if (op["if_unused"] and q.consumers) or (op["if_empty"] and q.ready):
            raise ChannelError(PRECONDITION_FAILED)
        return ("ok", m.delete_queue(op["name"]))
    if k == "purge":
        q = m.queue(op["name"], cid)
        n = len(q.ready)
        q.ready = []
        m.rearm(q)
        return ("ok", n)
    if k == "declare_exchange":
        name = op["name"]
        x = m.exchanges.get(name)
        if op["passive"]:
            if x is None:
                raise ChannelError(NOT_FOUND)
            return ("ok",)
        if name.startswith("amq."):
            raise ChannelError(ACCESS_REFUSED)
        if x is not None:
            if (x.type, x.durable, x.auto_delete, x.internal, x.args) != \
                    (op["type"], op["durable"], op["auto_delete"], op["internal"], op["args"]):
                raise ChannelError(PRECONDITION_FAILED)
            return ("ok",)
        x = m.exchanges[name] = Exchange(name, op["type"], op["durable"], op["auto_delete"], op["internal"],
                                         dict(op["args"]))
        m.apply_policies(only=x)
        return ("ok",)
    if k == "delete_exchange":
        name = op["name"]
        if name.startswith("amq."):
            raise ChannelError(ACCESS_REFUSED)
        if name not in m.exchanges:
            return ("ok",)
        in_use = any(b[2] == name or (on("if-unused-counts-destination") and b[0] == "x" and b[1] == name)
                     for b in m.bindings)
        if op["if_unused"] and in_use:
            raise ChannelError(PRECONDITION_FAILED)
        m.delete_exchange(name)
        return ("ok",)
    if k in ("bind_queue", "unbind_queue"):
        if k == "unbind_queue" and on("unbind-missing-ok") and \
                (op["queue"] not in m.queues or op["exchange"] not in m.exchanges):
            return ("ok",)
        if op["exchange"] == "":
            raise ChannelError(ACCESS_REFUSED)
        m.exchange(op["exchange"])  # LavinMQ checks the exchange before the queue
        m.queue(op["queue"], cid)
        return _bind(m, "q", op, ch)
    if k in ("bind_exchange", "unbind_exchange"):
        if k == "unbind_exchange" and on("unbind-missing-ok") and \
                (op["dest"] not in m.exchanges or op["src"] not in m.exchanges):
            return ("ok",)
        if op["src"] == "" or op["dest"] == "":
            raise ChannelError(ACCESS_REFUSED)
        m.exchange(op["dest"])
        m.exchange(op["src"])
        return _bind(m, "x", op, ch)
    if k == "publish":
        m.publish(cid, op["exchange"], op["rk"], op["mid"], op["body"], op["props"], op["mandatory"])
        return ("ok",)
    if k == "get":
        q = m.queue(op["queue"], cid)
        if any(c.exclusive for c in q.consumers):
            raise ChannelError(ACCESS_REFUSED)  # the queue is in exclusive use
        msg = m.pop(q)
        if msg is None:
            return ("get-empty",)
        props = m.deliver_props(q, msg, op["no_ack"])
        tag = ch.next_tag
        ch.next_tag += 1
        if not op["no_ack"]:
            ch.unacked[tag] = (q.name, msg, None)
        reply = ("get-ok", tag, m.redelivered(msg), msg.exchange, msg.rk, msg.id, props, len(q.ready))
        # a get wakes the expire loop, or starts it, and it expires the new head if it's due
        m.rearm(q)
        m.start_expiring(q)
        m.expire_ready()
        m.dispatch()
        return reply
    if k == "consume":
        q = m.queue(op["queue"], cid)
        if op["tag"] in ch.consumers:
            raise ConnectionError_(NOT_ALLOWED)  # the tag is in use on the channel
        if any(c.exclusive for c in q.consumers) or (op["exclusive"] and q.consumers):
            raise ChannelError(ACCESS_REFUSED)
        c = Consumer(op["tag"], cid, q.name, op["no_ack"], op["exclusive"], op["priority"], ch.prefetch)
        ch.consumers[c.tag] = c
        q.consumers.append(c)
        q.had_consumer = True
        return ("consume-ok", op["tag"])
    if k == "cancel":
        c = ch.consumers.get(op["tag"])
        if c is not None:
            m.remove_consumer(c)
        return ("cancel-ok", op["tag"])
    if k in ("ack", "nack", "reject"):
        tag, multiple = op["tag"], op.get("multiple", False) and k != "reject"
        if tag not in ch.unacked or (ch.tx and tag in ch.tx_pending):
            raise ChannelError(PRECONDITION_FAILED)
        tags = [t for t in sorted(ch.unacked) if t <= tag and t not in ch.tx_pending] if multiple else [tag]
        if ch.tx:
            ch.tx_acks.append((k, tags, op.get("requeue", False)))
            ch.tx_pending |= set(tags)
            return ("ok",)
        for t in tags:
            m.settle(cid, t, k == "ack", op.get("requeue", False))
        return ("ok",)
    if k == "ack_bad":
        raise ChannelError(PRECONDITION_FAILED)
    if k == "ack_all":
        tags = [t for t in sorted(ch.unacked) if t not in ch.tx_pending]
        if ch.tx:
            ch.tx_acks.append(("ack", tags, False))
            ch.tx_pending |= set(tags)
            return ("ok",)
        for t in tags:
            m.settle(cid, t, True, False)
        return ("ok",)
    if k == "recover":
        tags = sorted(ch.unacked)
        if op["requeue"]:
            for t in tags:
                m.settle(cid, t, False, True)
            return ("recover-ok",)
        for t in tags:
            if t in ch.tx_pending:
                continue  # channel.cr basic_recover skips tags acked in the transaction
            qname, msg, ctag = ch.unacked.pop(t)
            c = ch.consumers.get(ctag) if ctag else None
            if c is None:
                ch.unacked[t] = (qname, msg, ctag)
                m.settle(cid, t, False, True)
                continue
            msg.redelivered = True
            tag = ch.next_tag
            ch.next_tag += 1
            props = m.deliver_props(m.queues[qname], msg, c.no_ack)
            m.event(cid, ("deliver", c.tag, tag, True, msg.exchange, msg.rk, msg.id, props))
            ch.unacked[tag] = (qname, msg, ctag)
        return ("recover-ok",)
    if k == "qos":
        if op["global"]:
            ch.global_prefetch = op["prefetch"]
        else:
            ch.prefetch = op["prefetch"]
            if on("qos-updates-consumers"):
                for c in ch.consumers.values():
                    c.prefetch = op["prefetch"]
        return ("qos-ok",)
    if k == "flow":
        ch.flow = op["active"]
        return ("flow-ok", op["active"])
    if k == "confirm_select":
        if ch.tx:
            raise ChannelError(PRECONDITION_FAILED)
        ch.confirm = True
        return ("select-ok",)
    if k == "tx_select":
        if ch.confirm:
            raise ChannelError(PRECONDITION_FAILED)
        ch.tx = True
        return ("tx-select-ok",)
    if k == "tx_commit":
        if not ch.tx:
            raise ChannelError(PRECONDITION_FAILED)
        acks, pubs = ch.tx_acks, ch.tx_pubs
        ch.tx_acks, ch.tx_pubs, ch.tx_pending = [], [], set()
        for kind, tags, requeue in acks:
            for t in tags:
                if t in ch.unacked:
                    m.settle(cid, t, kind == "ack", requeue)
        for exchange, rk, mid, body, props, mandatory in pubs:
            if exchange != "" and exchange not in m.exchanges:
                # an exchange deleted before the commit leaves its publishes unroutable
                if mandatory:
                    m.event(cid, ("return", 312, exchange, rk, mid))
                continue
            m.publish(cid, exchange, rk, mid, body, props, mandatory, in_commit=True)
        return ("commit-ok",)
    if k == "tx_rollback":
        if not ch.tx:
            raise ChannelError(PRECONDITION_FAILED)
        ch.tx_acks, ch.tx_pubs, ch.tx_pending = [], [], set()
        return ("rollback-ok",)
    if k == "close_channel":
        m.close_channel(cid)
        return ("ok",)
    raise ValueError(f"unknown op {k}")


# -- generation -------------------------------------------------------------------

WEIGHTS = {
    "declare_queue": 8, "declare_queue_passive": 4, "delete_queue": 1.5, "purge": 1,
    "declare_exchange": 5, "delete_exchange": 1, "bind_queue": 7, "unbind_queue": 1,
    "bind_exchange": 3, "unbind_exchange": 0.5, "publish": 30, "get": 8, "consume": 6,
    "cancel": 2, "ack": 8, "nack": 6, "reject": 5, "ack_all": 1, "ack_bad": 0.3, "recover": 1,
    "qos": 3, "flow": 0.7, "confirm_select": 2, "tx_select": 1, "tx_commit": 2, "tx_rollback": 0.7,
    "close_channel": 1, "close_conn": 0.4, "sleep": 0.7, "set_policy": 1.2, "del_policy": 0.5,
    "restart": 0.25,
}
INVALID = 0.04  # how often an op names something that may not exist


def queue_args(r):
    a = {}
    if r.random() < .25:
        a["x-max-length"] = r.randint(0, 3)
    if r.random() < .1:
        a["x-max-length-bytes"] = r.choice([0, 30, 60, 150])
    if r.random() < .2:
        a["x-overflow"] = r.choice(["drop-head", "reject-publish", "reject-publish-dlx"])
    if r.random() < .35:
        a["x-dead-letter-exchange"] = r.choice(["", "", "", "amq.fanout"] + EXCHANGES)
    if a.get("x-dead-letter-exchange") == "" and r.random() < .8:
        a["x-dead-letter-routing-key"] = r.choice(QUEUES)  # a queue behind the default exchange
    elif r.random() < .2:
        a["x-dead-letter-routing-key"] = r.choice(QUEUES + ["a", "a.b"])
    if r.random() < .15:
        a["x-message-ttl"] = r.choice([0, SHORT_TTL, LONG_TTL])
    if r.random() < .15:
        a["x-delivery-limit"] = r.randint(0, 2)
    if r.random() < .15:
        a["x-max-priority"] = r.randint(1, 3)
    if r.random() < .1:
        a["x-single-active-consumer"] = True
    return a


def pick(r, existing, fallback):
    """Mostly an existing name, sometimes any name."""
    existing = sorted(existing)
    return r.choice(existing) if existing and r.random() > INVALID else r.choice(fallback)


def binding_key(r, m, exchange):
    x = m.exchanges.get(exchange)
    t = x.route_type if x else "direct"
    if t == "headers":
        args = {"x-match": r.choice(["all", "any", "all-with-x", "any-with-x"])}
        for h in ("h1", "h2"):
            if r.random() < .6:
                args[h] = r.choice(["1", "2"])
        if len(args) == 1:
            args["h1"] = "1"
        return "", args
    if t == "topic":
        return r.choice(TOPIC_KEYS), {}
    return r.choice(ROUTING_KEYS), {}


def random_op(r, m, n):
    k = r.choices(list(WEIGHTS), weights=list(WEIGHTS.values()))[0]
    open_channels = [c for c, s in m.channels.items() if s.open]
    cid = r.choice(open_channels) if open_channels and r.random() < .7 else r.choice(CHANNELS)
    ch = m.channels.get(cid)
    conn = cid.split(".")[0]
    qs = [q.name for q in m.queues.values() if q.exclusive_conn in (None, conn)]
    xs = [x for x in m.exchanges if not x.startswith("amq.")]
    if len(m.queues) < 2 and r.random() < .5:
        k = "declare_queue"
    elif not xs and r.random() < .2:
        k = "declare_exchange"
    if k == "declare_queue":
        name = r.choice([q for q in QUEUES if q not in m.queues] or QUEUES) if r.random() < .6 else r.choice(QUEUES)
        q = m.queues.get(name)
        if q is not None and r.random() < .9:
            return {"op": k, "ch": cid, "name": name, "passive": False, "durable": q.durable,
                    "exclusive": q.exclusive_conn is not None, "auto_delete": q.auto_delete, "args": dict(q.args)}
        args = queue_args(r)
        if "x-dead-letter-routing-key" in args and r.random() > INVALID:
            args.setdefault("x-dead-letter-exchange", "")
        return {"op": k, "ch": cid, "name": name if r.random() > .01 else "amq.q", "passive": False,
                "durable": r.random() < .5, "exclusive": r.random() < .08, "auto_delete": r.random() < .08,
                "args": args}
    if k == "declare_queue_passive":
        return {"op": "declare_queue", "ch": cid, "name": pick(r, qs, QUEUES), "passive": True}
    if k == "delete_queue":
        return {"op": k, "ch": cid, "name": pick(r, qs, QUEUES), "if_unused": r.random() < .3,
                "if_empty": r.random() < .3}
    if k == "purge":
        return {"op": k, "ch": cid, "name": pick(r, qs, QUEUES)}
    if k == "declare_exchange":
        name = r.choice([x for x in EXCHANGES if x not in m.exchanges] or EXCHANGES) if r.random() < .6 \
            else r.choice(EXCHANGES)
        x = m.exchanges.get(name)
        if x is not None and r.random() < .9:
            return {"op": k, "ch": cid, "name": name, "passive": False, "type": x.type, "durable": x.durable,
                    "auto_delete": x.auto_delete, "internal": x.internal, "args": dict(x.args)}
        t = r.choice(["direct", "fanout", "topic", "headers", "direct", "topic", "x-delayed-message"])
        args = {"x-delayed-type": r.choice(["direct", "topic", "fanout"])} if t == "x-delayed-message" else {}
        if r.random() < .2:
            args["x-alternate-exchange"] = r.choice(EXCHANGES)
        return {"op": k, "ch": cid, "name": name, "passive": r.random() < .03, "type": t,
                "durable": r.random() < .5, "auto_delete": r.random() < .04, "internal": r.random() < .04,
                "args": args}
    if k == "delete_exchange":
        return {"op": k, "ch": cid, "name": pick(r, xs, EXCHANGES), "if_unused": r.random() < .3}
    if k in ("bind_queue", "unbind_queue"):
        bindings = [b for b in m.bindings if b[0] == "q" and b[2] != ""]
        if k == "unbind_queue" and bindings and r.random() < .9:
            b = r.choice(sorted(bindings))
            return {"op": k, "ch": cid, "queue": b[1], "exchange": b[2], "key": b[3], "args": dict(b[4])}
        exchange = pick(r, xs + ["amq.topic", "amq.fanout", "amq.direct", "amq.headers"], EXCHANGES)
        key, args = binding_key(r, m, exchange)
        return {"op": k, "ch": cid, "queue": pick(r, qs, QUEUES), "exchange": exchange, "key": key, "args": args}
    if k in ("bind_exchange", "unbind_exchange"):
        bindings = [b for b in m.bindings if b[0] == "x"]
        if k == "unbind_exchange" and bindings:
            b = r.choice(sorted(bindings))
            return {"op": k, "ch": cid, "dest": b[1], "src": b[2], "key": b[3], "args": dict(b[4])}
        source = pick(r, xs + ["amq.topic", "amq.fanout"], EXCHANGES)
        key, args = binding_key(r, m, source)
        return {"op": k, "ch": cid, "dest": pick(r, xs, EXCHANGES), "src": source, "key": key, "args": args}
    if k == "publish":
        mid = f"m{n}"
        props = {"delivery-mode": 2, "message-id": mid}
        if r.random() < .25:
            props["priority"] = r.randint(0, 5)  # above x-max-priority too
        if r.random() < .15:
            props["expiration"] = r.choice(["0", str(SHORT_TTL), str(LONG_TTL)])
        h = {}
        if r.random() < .5:
            if r.random() < .6:
                h["h1"] = r.choice(["1", "2"])
            if r.random() < .4:
                h["h2"] = r.choice(["1", "2"])
            if r.random() < .1:
                h["CC"] = r.sample(ROUTING_KEYS, r.randint(1, 2))
            if r.random() < .05:
                h["BCC"] = r.sample(ROUTING_KEYS, 1)
            if r.random() < .05:
                h["x-dead-letter-exchange"] = r.choice(EXCHANGES + ["amq.fanout"])
        if r.random() < .45 and qs:
            exchange, rk = "", r.choice(qs)
        else:
            exchange = pick(r, xs + ["amq.topic", "amq.fanout", ""], EXCHANGES + ["nx"])
            keys = [b[3] for b in m.bindings if b[2] == exchange and b[3] and "*" not in b[3] and "#" not in b[3]]
            rk = r.choice(keys) if keys and r.random() < .6 else r.choice(ROUTING_KEYS)
        x = m.exchanges.get(exchange)
        if x is not None and x.type == "x-delayed-message" and r.random() < .7:
            h["x-delay"] = r.choice([300, 0])
        if h:
            props["headers"] = h
        size = r.choice([1, 3, 8, 15, 30])
        body = (mid + "_" * size)[:max(size, len(mid))]
        return {"op": k, "ch": cid, "exchange": exchange, "rk": rk, "mid": mid, "body": body,
                "props": props, "mandatory": r.random() < .3}
    if k == "get":
        return {"op": k, "ch": cid, "queue": pick(r, qs, QUEUES), "no_ack": r.random() < .3}
    if k == "consume":
        return {"op": k, "ch": cid, "queue": pick(r, qs, QUEUES), "tag": f"t{n}", "no_ack": r.random() < .2,
                "exclusive": r.random() < .04, "priority": r.randint(0, 4)}
    with_consumers = [c for c, s in m.channels.items() if s.consumers]
    with_unacked = [c for c, s in m.channels.items() if s.unacked]
    if k == "cancel":
        return {"op": k, "ch": r.choice(with_consumers) if with_consumers else cid, "ref": r.randint(0, 9)}
    if k in ("ack", "nack", "reject"):
        return {"op": k, "ch": r.choice(with_unacked) if with_unacked else cid, "ref": r.randint(0, 9),
                "multiple": r.random() < .3, "requeue": r.random() < .6}
    if k == "ack_all":
        return {"op": k, "ch": r.choice(with_unacked) if with_unacked else cid}
    if k == "recover":
        return {"op": k, "ch": r.choice(with_unacked) if with_unacked else cid, "requeue": r.random() < .7}
    if k == "qos":
        return {"op": k, "ch": cid, "prefetch": r.randint(0, 3), "global": r.random() < .3}
    if k == "flow":
        return {"op": k, "ch": cid, "active": not ch.flow if ch else False}
    if k in ("tx_commit", "tx_rollback"):
        in_tx = [c for c, s in m.channels.items() if s.tx and s.open]
        return {"op": k, "ch": r.choice(in_tx) if in_tx and r.random() > INVALID else cid}
    if k in ("ack_bad", "confirm_select", "tx_select", "close_channel"):
        return {"op": k, "ch": cid}
    if k == "close_conn":
        return {"op": k, "conn": r.choice(CONNS)}
    if k == "sleep":
        return {"op": k, "ms": 700}
    if k == "set_policy":
        definition = {}
        for key, values in (("max-length", [0, 1, 2]), ("max-length-bytes", [60, 200]),
                            ("message-ttl", [SHORT_TTL, LONG_TTL]), ("overflow", ["drop-head", "reject-publish"]),
                            ("dead-letter-exchange", EXCHANGES + ["amq.fanout"]),
                            ("dead-letter-routing-key", QUEUES), ("delivery-limit", [0, 1]),
                            ("alternate-exchange", EXCHANGES)):
            if r.random() < .25:
                definition[key] = r.choice(values)
        return {"op": k, "name": r.choice(["p1", "p2"]),
                "pattern": r.choice(["^q", "^q1$", "^x", "^(q2|x1)$", "."]),
                "definition": definition or {"max-length": 2}, "priority": r.choice([1, 2, 3]),
                "apply_to": r.choice(["all", "queues", "exchanges"])}
    if k == "del_policy":
        return {"op": k, "name": r.choice(["p1", "p2"])}
    if k == "restart":
        return {"op": k}
    raise ValueError(f"unknown op {k}")


def generate(seed, length, model_factory):
    """length ops that fit the state as it evolves, stepping a scratch model.
    The runner resolves them again against its own model."""
    r = random.Random(seed)
    m = model_factory()
    ops = []
    n = 0
    while len(ops) < length:
        n += 1
        op = random_op(r, m, n)
        resolved = resolve(op, m)
        if resolved is None or not safe(m, resolved):
            continue
        apply(m, resolved)
        m.dispatch()
        m.take_events()
        ops.append(op)
    return ops

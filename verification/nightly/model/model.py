"""A reference model of AMQP 0-9-1 with RabbitMQ's extensions, as the
specification and LavinMQ's docs/ describe them. It's the oracle: it applies
one op at a time and says what a client should observe, the synchronous reply
plus the deliveries, returns, confirms and cancels on each channel.

Where LavinMQ knowingly differs, the model follows LavinMQ while the quirk is
on (quirks.py), and the specification when it's off."""
import copy
import re
import time

import amqp
from quirks import on

SHORT_TTL = 150      # ms; the runner waits out deadlines this short
LONG_TTL = 10 ** 8
AMQ_EXCHANGES = {"amq.direct": "direct", "amq.fanout": "fanout", "amq.topic": "topic",
                 "amq.headers": "headers", "amq.match": "headers"}

# reply codes
NOT_FOUND, RESOURCE_LOCKED, PRECONDITION_FAILED, ACCESS_REFUSED = 404, 405, 406, 403
NOT_ALLOWED = 530


class DeadLetterLoop(Exception):
    """Dead-lettering that never ends; LavinMQ hangs on it (dead-letter-ping-pong)."""


class ChannelError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


class ConnectionError_(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


def topic_match(pattern, routing_key):
    p, w = pattern.split("."), routing_key.split(".")

    def match(i, j):
        if i == len(p):
            return j == len(w)
        if p[i] == "#":
            return any(match(i + 1, k) for k in range(j, len(w) + 1))
        return j < len(w) and p[i] in ("*", w[j]) and match(i + 1, j + 1)
    return match(0, 0)


def headers_match(args, headers):
    x_match = args.get("x-match", "all")
    headers = headers or {}
    with_x = x_match.endswith("-with-x")
    pairs = {k: v for k, v in args.items() if k != "x-match" and (with_x or not k.startswith("x-"))}
    if not pairs:
        return x_match.startswith("all")  # all with no pairs matches everything (RabbitMQ)
    hits = [k in headers and (v is None or headers[k] == v) for k, v in pairs.items()]
    return all(hits) if x_match.startswith("all") else any(hits)


class Msg:
    __slots__ = ("id", "body", "props", "exchange", "rk", "rks", "seq", "redelivered",
                 "deliveries", "ts", "ttl", "unknown_redelivered", "bcc", "home", "keep_ts")

    def __init__(self, id, body, props, exchange, rk, rks):
        self.id, self.body, self.props = id, body, props
        self.exchange, self.rk, self.rks = exchange, rk, rks
        self.seq = 0
        self.redelivered = False
        self.unknown_redelivered = False  # after a restart the flag isn't known
        self.deliveries = 0
        self.ts = 0           # enqueue time in ms
        self.ttl = None       # per-message expiration
        self.bcc = None
        self.keep_ts = False
        self.home = None      # the Queue holding it: a queue declared again under the same name is another queue

    def clone(self):
        m = Msg(self.id, self.body, copy.deepcopy(self.props), self.exchange, self.rk, list(self.rks))
        m.ts, m.ttl, m.keep_ts = self.ts, self.ttl, self.keep_ts
        m.bcc = copy.deepcopy(self.bcc)
        return m

    def bytesize(self):
        if not on("max-length-bytes-whole-message"):
            return len(self.body.encode())
        props = copy.deepcopy(self.props)
        if self.bcc is not None and on("bcc-stored"):
            props.setdefault("headers", {})["BCC"] = self.bcc
        headers = props.get("headers")
        if headers and isinstance(headers.get("x-death"), list):
            for d in headers["x-death"]:
                d["time"] = ("T", b"\0" * 8)
        props_size = len(amqp.header_payload(0, props)) - 12
        return 8 + 1 + len(self.exchange.encode()) + 1 + len(self.rk.encode()) + props_size + 8 + len(self.body.encode())


class Queue:
    def __init__(self, name, durable, exclusive_conn, auto_delete, args):
        self.name, self.durable, self.exclusive_conn, self.auto_delete = name, durable, exclusive_conn, auto_delete
        self.args = args
        self.policy = {}
        self.ready = []         # in delivery order
        self.consumers = []     # in registration order
        self.had_consumer = False
        self.seq = 0
        self.max_priority = args.get("x-max-priority")
        self.single_active = args.get("x-single-active-consumer") is True
        self.expiring = False   # whether LavinMQ's expire loop runs for the queue
        self.armed = None       # the deadline it sleeps until

    # numeric settings take the lower of argument and policy (docs/policies.md),
    # the others prefer the argument
    def number(self, arg, policy):
        values = [v for v in (self.args.get(arg), self.policy.get(policy))
                  if isinstance(v, int) and not isinstance(v, bool)]
        return min(values) if values else None

    def setting(self, arg, policy):
        v = self.args.get(arg)
        return v if v is not None else self.policy.get(policy)

    @property
    def max_length(self):
        return self.number("x-max-length", "max-length")

    @property
    def max_length_bytes(self):
        return self.number("x-max-length-bytes", "max-length-bytes")

    @property
    def message_ttl(self):
        return self.number("x-message-ttl", "message-ttl")

    @property
    def delivery_limit(self):
        return self.number("x-delivery-limit", "delivery-limit")

    @property
    def overflow(self):
        policy = self.policy.get("overflow") if self.policy.get("overflow") in ("drop-head", "reject-publish") else None
        arg = self.args.get("x-overflow")
        v = (policy or arg) if on("overflow-policy-wins") else (arg or policy)
        if v == "reject-publish-dlx" and on("reject-publish-dlx-is-drop-head"):
            return "drop-head"
        return v if v in ("reject-publish", "reject-publish-dlx") else "drop-head"

    @property
    def dlx(self):
        return self.setting("x-dead-letter-exchange", "dead-letter-exchange")

    @property
    def dlrk(self):
        return self.setting("x-dead-letter-routing-key", "dead-letter-routing-key")

    def priority(self, m):
        if self.max_priority is None:
            return 0
        return min(m.props.get("priority") or 0, self.max_priority)

    def insert(self, m, requeue=False):
        m.home = self
        if not requeue:
            self.seq += 1
            m.seq = self.seq
        key = (-self.priority(m), m.seq)
        i = len(self.ready)
        while i > 0 and (-self.priority(self.ready[i - 1]), self.ready[i - 1].seq) > key:
            i -= 1
        self.ready.insert(i, m)

    def bytes(self):
        return sum(m.bytesize() for m in self.ready)


class Exchange:
    def __init__(self, name, type, durable, auto_delete, internal, args):
        self.name, self.type, self.durable, self.auto_delete, self.internal, self.args = \
            name, type, durable, auto_delete, internal, args
        self.policy = {}
        self.had_binding = False

    @property
    def alternate(self):
        return self.args.get("x-alternate-exchange") or self.args.get("alternate-exchange") or \
            self.policy.get("alternate-exchange")

    @property
    def route_type(self):
        return self.args.get("x-delayed-type", "direct") if self.type == "x-delayed-message" else self.type


class Consumer:
    def __init__(self, tag, ch, queue, no_ack, exclusive, priority, prefetch):
        self.tag, self.ch, self.queue, self.no_ack, self.exclusive, self.priority, self.prefetch = \
            tag, ch, queue, no_ack, exclusive, priority, prefetch
        self.unacked = 0


class Channel:
    def __init__(self, cid):
        self.id = cid
        self.conn = cid.split(".")[0]
        self.reset()

    def reset(self):
        self.open = False
        self.confirm = False
        self.tx = False
        self.next_tag = 1
        self.pub_seq = 0
        self.prefetch = 0          # for new consumers
        self.global_prefetch = 0
        self.flow = True
        self.unacked = {}          # tag -> (queue name, Msg, consumer tag or None for basic.get)
        self.consumers = {}        # tag -> Consumer
        self.tx_pubs = []
        self.tx_acks = []
        self.tx_pending = set()    # tags settled inside the open transaction

    def consumer_unacked(self):
        return sum(1 for (_q, _m, c) in self.unacked.values() if c is not None)


class Model:
    def __init__(self):
        self.queues = {}
        self.exchanges = {n: Exchange(n, t, True, False, False, {}) for n, t in AMQ_EXCHANGES.items()}
        self.bindings = set()     # (kind "q"/"x", destination, source, key, frozen args)
        self.bind_seq = {}        # binding -> creation order; LavinMQ routes in that order
        self.channels = {}
        self.policies = {}        # name -> (pattern, definition, priority, apply_to)
        self.delayed = []         # (due, exchange, Msg)
        self.events = {}          # channel id -> events
        self.now = time.time()
        self.dead_letter_depth = 0
        self.restarting = False

    # -- helpers -------------------------------------------------------------------

    def ch(self, cid):
        if cid not in self.channels:
            self.channels[cid] = Channel(cid)
        return self.channels[cid]

    def event(self, cid, e):
        self.events.setdefault(cid, []).append(e)

    def take_events(self):
        events, self.events = self.events, {}
        return events

    def queue(self, name, cid):
        q = self.queues.get(name)
        if q is None:
            raise ChannelError(NOT_FOUND)
        if q.exclusive_conn is not None and q.exclusive_conn != cid.split(".")[0]:
            raise ChannelError(RESOURCE_LOCKED)
        return q

    def exchange(self, name):
        if name == "":
            return Exchange("", "default", True, False, False, {})
        x = self.exchanges.get(name)
        if x is None:
            raise ChannelError(NOT_FOUND)
        return x

    def sorted_bindings(self):
        return sorted(self.bindings, key=lambda b: (self.bind_seq.get(b, 0), b))

    # -- routing -------------------------------------------------------------------

    def route(self, exchange, routing_keys, headers):
        """The queues a message reaches: depth first in binding order, CC keys
        routed again from each exchange with a fresh visited set (exchange.cr
        find_queues)."""
        queues = []
        cc = list(routing_keys[1:])
        headers_without_cc = {k: v for k, v in (headers or {}).items() if k not in ("CC", "BCC")}

        def bound(x, key, args, rk, hdrs):
            t = x.route_type
            if t == "fanout":
                return True
            if t == "direct":
                return key == rk
            if t == "topic":
                return topic_match(key, rk)
            if t == "headers":
                return headers_match(dict(args), hdrs)
            return False

        def find(name, rk, hdrs, seen, with_cc):
            if name in seen:
                return
            seen.add(name)
            matched = False
            if name == "":
                if rk in self.queues and rk not in queues:
                    queues.append(rk)
            else:
                x = self.exchanges.get(name)
                if x is None:
                    return
                for kind, dest, src, key, args in self.sorted_bindings():
                    if src != name or not bound(x, key, args, rk, hdrs):
                        continue
                    matched = True
                    if kind == "q":
                        if dest in self.queues and dest not in queues:
                            queues.append(dest)
                    else:
                        find(dest, rk, hdrs, seen, with_cc)
            if with_cc:
                for key in cc:
                    find(name, key, headers_without_cc, set(), False)
            if name != "":
                x = self.exchanges.get(name)
                unrouted = not queues if on("alternate-exchange-per-pass") else not matched
                if x is not None and x.alternate and unrouted:
                    find(x.alternate, rk, hdrs, seen, with_cc)

        find(exchange, routing_keys[0], headers, set(), True)
        return queues

    def enqueue(self, qname, m):
        """Put a copy of m in the queue; False if the queue refuses it."""
        q = self.queues[qname]
        m = m.clone()
        expiration = m.props.get("expiration")
        m.ttl = int(expiration) if expiration is not None and str(expiration).isdigit() else None
        if not m.keep_ts:
            m.ts = self.now * 1000
        was_empty = not q.ready
        if q.overflow in ("reject-publish", "reject-publish-dlx"):
            ml, mlb = q.max_length, q.max_length_bytes
            if mlb is not None:
                size = q.bytes() + m.bytesize()
                over_bytes = size >= mlb if on("reject-publish-bytes-at-limit") else size > mlb
            else:
                over_bytes = False
            if (ml is not None and len(q.ready) >= ml) or over_bytes:
                if q.overflow == "reject-publish-dlx":
                    self.dead_letter(q, m, "maxlen")
                return False
        q.insert(m)
        self.drop_overflow(q)  # LavinMQ drops overflow before it looks at TTLs
        if was_empty:
            self.rearm(q)
        # a message with a TTL starts the expire loop if it isn't running; the loop
        # then expires a TTL 0 head, after the publish (ttl-zero-behind-head)
        if q.message_ttl is not None or m.ttl is not None:
            self.start_expiring(q)
        if m in q.ready and self.zero_ttl(q, m) and not on("ttl-zero-behind-head") and \
                not any(self.capacity(c) for c in q.consumers):
            # docs/ttl.md: a TTL 0 message is expired unless a consumer can take it
            q.ready.remove(m)
            self.dead_letter(q, m, "expired")
        return True

    def drop_overflow(self, q, requeue_or_policy=False):
        if requeue_or_policy and q.overflow != "drop-head" and not on("reject-publish-drops-on-apply"):
            return
        ml, mlb = q.max_length, q.max_length_bytes
        if on("zero-bytes-limit-skipped"):
            zero = ml == 0 if ml is not None else mlb == 0
        else:
            zero = ml == 0 or mlb == 0
        # a zero limit delivers to a consumer with capacity, even a waiting single active one
        if zero and on("zero-limit-delivers") and any(self.capacity(c) for c in q.consumers):
            return
        dropped = False
        while ml is not None and len(q.ready) > ml:
            self.dead_letter(q, q.ready.pop(0), "maxlen")
            dropped = True
        while mlb is not None and q.bytes() > mlb:
            self.dead_letter(q, q.ready.pop(0), "maxlenbytes")
            dropped = True
        if dropped and not on("expiry-not-rearmed-on-drop"):
            self.rearm(q)
            self.start_expiring(q)

    def dead_letter(self, q, m, reason):
        self.dead_letter_depth += 1
        try:
            self._dead_letter(q, m, reason)
        finally:
            self.dead_letter_depth -= 1

    def _dead_letter(self, q, m, reason):
        headers = m.props.get("headers") or {}
        dlx = headers.get("x-dead-letter-exchange", q.dlx)
        if dlx is None:
            return
        dlrk = headers.get("x-dead-letter-routing-key", q.dlrk)
        n = m.clone()
        n.keep_ts = False
        n.bcc = None  # dead_lettering.cr deletes BCC
        n.redelivered = False
        n.deliveries = 0
        headers = copy.deepcopy(headers)
        deaths = headers.get("x-death") or []
        entry = next((d for d in reversed(deaths) if d.get("queue") == q.name and d.get("reason") == reason), None)
        if entry:
            deaths.remove(entry)
            entry["count"] += 1
            if entry["count"] > 3 and reason != "rejected":
                raise DeadLetterLoop(q.name)  # only a loop, e.g. one paced by a TTL, gets here
            entry["routing-keys"] = list(m.rks)
        else:
            entry = {"queue": q.name, "reason": reason, "exchange": m.exchange, "count": 1,
                     "routing-keys": list(m.rks)}
        if "expiration" in m.props:
            entry["original-expiration"] = m.props["expiration"]
        deaths.insert(0, entry)
        headers["x-death"] = deaths
        headers.setdefault("x-first-death-reason", reason)
        headers.setdefault("x-first-death-queue", q.name)
        headers.setdefault("x-first-death-exchange", m.exchange)
        for k in ("x-dead-letter-exchange", "x-dead-letter-routing-key", "x-delivery-count"):
            headers.pop(k, None)
        n.props.pop("expiration", None)
        if dlrk is not None:
            headers.pop("CC", None)
            headers.pop("BCC", None)
            routing_keys = [dlrk]
            n.rk = dlrk
        else:
            routing_keys = [m.rk] + list(headers.get("CC") or []) + list(headers.pop("BCC", None) or [])
        n.props["headers"] = headers
        n.exchange = dlx
        n.rks = [n.rk] + list(headers.get("CC") or [])

        def cycle(dest):
            if self.dead_letter_depth > 40:
                raise DeadLetterLoop(dest)
            if not on("cycle-detection-newest-rejection") and any(d.get("reason") == "rejected" for d in deaths):
                return False
            # newest first: a rejection before the matching death means it isn't a cycle
            for d in deaths:
                if d.get("reason") == "rejected":
                    return False
                if d.get("queue") == dest and d.get("reason") == reason:
                    return True
            return False
        for dest in self.route(dlx, routing_keys, headers):
            if not cycle(dest):
                self.enqueue(dest, n)

    # -- expiry --------------------------------------------------------------------

    def deadline(self, q, m):
        """LavinMQ computes expiry when it checks, from the message timestamp and the
        queue's current TTL, so a TTL policy applies to messages already queued."""
        ttl = min([t for t in (q.message_ttl, m.ttl) if t is not None], default=None)
        return None if ttl is None else (m.ts + ttl) // 100 * 100

    def rearm(self, q):
        """A running expire loop recomputes its wait from the head: when the queue
        gets a message after being empty, on a get, a purge, a policy apply and when
        the last consumer leaves."""
        q.armed = self.deadline(q, q.ready[0]) if q.expiring and q.ready else None

    def start_expiring(self, q):
        """ensure_expire_fiber: start the expire loop if it isn't running and the
        head, or the queue, has a TTL. Once started it keeps running; LavinMQ stops
        it only after 30 s idle, longer than a run's waits."""
        if not q.expiring and q.ready and not q.consumers and \
                (q.message_ttl is not None or q.ready[0].ttl is not None):
            q.expiring = True
            self.rearm(q)

    def zero_ttl(self, q, m):
        return m.ttl == 0 or q.message_ttl == 0

    def expired(self, q, m):
        if self.zero_ttl(q, m):
            return not q.consumers
        deadline = self.deadline(q, m)
        return deadline is not None and deadline <= self.now * 1000

    def expire_ready(self):
        """Expire messages at the head of each queue (docs/ttl.md)."""
        now = self.now * 1000
        for q in list(self.queues.values()):
            if q.consumers and on("no-expiry-with-consumers"):
                continue
            while q.ready:
                m = q.ready[0]
                deadline = self.deadline(q, m)
                armed = q.armed is not None and q.armed <= now
                if deadline is not None and not self.zero_ttl(q, m) and deadline <= now and armed:
                    q.ready.pop(0)
                    self.dead_letter(q, m, "expired")
                    head = q.ready[0] if q.ready else None
                    if not (head and self.deadline(q, head) is not None and self.deadline(q, head) <= now):
                        self.rearm(q)
                elif self.zero_ttl(q, m) and not q.consumers and armed:
                    q.ready.pop(0)
                    self.dead_letter(q, m, "expired")
                else:
                    if armed:
                        self.rearm(q)  # the loop woke and found nothing expired
                    break

    def pending_deadline(self):
        """The latest near deadline, which the runner waits out."""
        deadlines = [self.deadline(q, m) / 1000 for q in self.queues.values() for m in q.ready
                     if self.deadline(q, m) is not None and not self.zero_ttl(q, m)
                     and self.now < self.deadline(q, m) / 1000 < self.now + 60]
        deadlines += [d for (d, _x, _m) in self.delayed if d > self.now - 1]
        return max(deadlines) if deadlines else None

    def advance(self, now):
        """Move the clock to now: delayed messages arrive and are delivered at their
        due time, then whatever has expired by now expires."""
        due = sorted((d for d in self.delayed if d[0] <= now), key=lambda d: d[0])
        self.delayed = [d for d in self.delayed if d[0] > now]
        for at, exchange, m in due:
            self.now = max(self.now, at)
            headers = m.props.get("headers") or {}
            headers.pop("x-delay", None)
            if exchange in self.exchanges:
                destinations = self.route_publish(exchange, m)
                if "BCC" in headers:
                    m.bcc = headers.pop("BCC")
                for q in destinations:
                    self.enqueue(q, m)
                self.dispatch()
        self.now = now
        self.expire_ready()
        self.dispatch()

    # -- delivery ------------------------------------------------------------------

    def capacity(self, c):
        ch = self.channels[c.ch]
        if not ch.open or not ch.flow:
            return False
        if c.no_ack:
            return True
        if c.prefetch and c.unacked >= c.prefetch:
            return False
        if ch.global_prefetch and ch.consumer_unacked() >= ch.global_prefetch:
            return False
        return True

    def pick(self, q):
        if not q.consumers:
            return None
        if q.single_active:
            c = q.consumers[0]
            return c if self.capacity(c) else None
        best = None
        for c in q.consumers:
            if self.capacity(c) and (best is None or c.priority > best.priority):
                best = c
        return best

    def pop(self, q):
        while q.ready:
            m = q.ready.pop(0)
            if self.expired(q, m):
                self.dead_letter(q, m, "expired")
                continue
            return m
        return None

    def deliver_props(self, q, m, no_ack):
        props = copy.deepcopy(m.props)
        if q.delivery_limit is not None and not no_ack:
            if m.deliveries > 0:
                props.setdefault("headers", {})["x-delivery-count"] = m.deliveries
            m.deliveries += 1
        return props

    def redelivered(self, m):
        return "?" if m.unknown_redelivered else m.redelivered

    def dispatch(self):
        progress = True
        while progress:
            progress = False
            for q in list(self.queues.values()):
                while (c := self.pick(q)) is not None and (m := self.pop(q)) is not None:
                    ch = self.channels[c.ch]
                    tag = ch.next_tag
                    ch.next_tag += 1
                    props = self.deliver_props(q, m, c.no_ack)
                    self.event(c.ch, ("deliver", c.tag, tag, self.redelivered(m), m.exchange, m.rk, m.id, props))
                    if not c.no_ack:
                        c.unacked += 1
                        ch.unacked[tag] = (q.name, m, c.tag)
                    progress = True

    def requeue(self, qname, m):
        q = self.queues.get(qname)
        if q is None or (m.home is not None and m.home is not q):
            return
        m.redelivered = True
        # a requeued message keeps its original expiry (RabbitMQ does the same)
        if self.zero_ttl(q, m) or self.expired(q, m):
            self.dead_letter(q, m, "expired")
            return
        if q.delivery_limit is not None and m.deliveries > q.delivery_limit:
            self.dead_letter(q, m, "delivery_limit")
            return
        q.insert(m, requeue=True)
        self.drop_overflow(q, requeue_or_policy=True)
        self.start_expiring(q)

    def settle(self, cid, tag, ack, requeue):
        ch = self.channels[cid]
        qname, m, ctag = ch.unacked.pop(tag)
        if ctag is not None:
            c = ch.consumers.get(ctag)
            if c is None and qname in self.queues:
                c = next((c for c in self.queues[qname].consumers if c.tag == ctag and c.ch == cid), None)
            if c is not None:
                c.unacked -= 1
        if ack:
            return
        q = self.queues.get(qname)
        if q is None or (m.home is not None and m.home is not q):
            return  # its queue is gone, maybe declared again under its name
        if requeue:
            self.requeue(qname, m)
        else:
            self.dead_letter(q, m, "rejected")

    def remove_consumer(self, c, notify=False):
        self.channels[c.ch].consumers.pop(c.tag, None)
        q = self.queues.get(c.queue)
        if q is None:
            return
        if c in q.consumers:
            q.consumers.remove(c)
        if notify:
            self.event(c.ch, ("cancel", c.tag))
        if not q.consumers:
            self.rearm(q)
            self.start_expiring(q)
        if q.auto_delete and q.had_consumer and not q.consumers:
            self.delete_queue(q.name)

    def delete_queue(self, name):
        q = self.queues.pop(name, None)
        if q is None:
            return 0
        for c in list(q.consumers):
            self.channels[c.ch].consumers.pop(c.tag, None)
            self.event(c.ch, ("cancel", c.tag))
        self.bindings = {b for b in self.bindings if not (b[0] == "q" and b[1] == name)}
        self.auto_delete_exchanges()
        return len(q.ready)

    def auto_delete_exchanges(self):
        if self.restarting and on("auto-delete-exchange-survives-restart"):
            return
        changed = True
        while changed:
            changed = False
            for x in list(self.exchanges.values()):
                if x.auto_delete and x.had_binding and not any(b[2] == x.name for b in self.bindings):
                    self.delete_exchange(x.name)
                    changed = True

    def delete_exchange(self, name):
        self.exchanges.pop(name, None)
        self.bindings = {b for b in self.bindings if b[2] != name and not (b[0] == "x" and b[1] == name)}
        self.delayed = [d for d in self.delayed if d[1] != name]

    def close_channel(self, cid):
        ch = self.channels[cid]
        if not ch.open:
            return
        consumers = list(ch.consumers.values())
        ch.open = False
        # channel.cr close removes the consumers first, then requeues in tag order
        for c in consumers:
            self.remove_consumer(c)
        for tag in sorted(ch.unacked):
            qname, m, _ctag = ch.unacked[tag]
            self.requeue(qname, m)
        ch.reset()

    def close_conn(self, conn):
        for cid, ch in list(self.channels.items()):
            if ch.conn == conn:
                self.close_channel(cid)
        for q in list(self.queues.values()):
            if q.exclusive_conn == conn:
                self.delete_queue(q.name)

    # -- policies ------------------------------------------------------------------

    def effective_policy(self, kind, name):
        best = None
        for policy, (pattern, definition, priority, apply_to) in self.policies.items():
            if apply_to not in ("all", kind) or not re.search(pattern, name):
                continue
            ties_go_to_last = on("policy-tie-last-wins")
            if best is None or priority > best[2] or (ties_go_to_last and priority == best[2]):
                best = (policy, definition, priority)
        return best

    def apply_policies(self, only=None):
        """Apply the policies to every queue and exchange, as a policy change does,
        or `only` to a new one, as a declare does."""
        for kind, objects in (("queues", self.queues), ("exchanges", self.exchanges)):
            for o in objects.values():
                if only is None or o is only:
                    best = self.effective_policy(kind, o.name)
                    o.policy = dict(best[1]) if best else {}
        for q in self.queues.values():
            if only is not None and q is not only:
                continue
            # applying a policy signals the expire loop, then drops overflow in a fiber
            self.rearm(q)
            if q.message_ttl is not None:
                self.start_expiring(q)
            self.drop_overflow(q, requeue_or_policy=True)
            limit = q.delivery_limit
            if limit is not None:
                while q.ready and q.ready[0].deliveries > limit:
                    self.dead_letter(q, q.ready.pop(0), "delivery_limit")

    # -- restart ---------------------------------------------------------------------

    def restart(self):
        self.restarting = True
        try:
            for conn in sorted({c.conn for c in self.channels.values()}):
                self.close_conn(conn)
            for name in [n for n, q in self.queues.items() if not q.durable]:
                self.delete_queue(name)
            for name in [n for n, x in self.exchanges.items() if not x.durable]:
                self.delete_exchange(name)
            for q in self.queues.values():
                q.expiring = False
                self.start_expiring(q)
                for m in q.ready:
                    if m.redelivered:
                        m.unknown_redelivered = True
            self.channels = {}
            self.take_events()
        finally:
            self.restarting = False

    # -- publish ---------------------------------------------------------------------

    def route_publish(self, exchange, m):
        headers = m.props.get("headers") or {}
        routing_keys = [m.rk] + [c for c in (headers.get("CC") or []) if isinstance(c, str)] + \
                       [c for c in (headers.get("BCC") or []) if isinstance(c, str)]
        return self.route(exchange, routing_keys, headers)

    def publish(self, cid, exchange, routing_key, mid, body, props, mandatory, in_commit=False):
        ch = self.channels[cid]
        x = self.exchange(exchange)
        if x.internal:
            raise ChannelError(ACCESS_REFUSED)
        if ch.tx and not in_commit:
            ch.tx_pubs.append((exchange, routing_key, mid, body, props, mandatory))
            return
        if ch.confirm:
            ch.pub_seq += 1
        headers = props.get("headers") or {}
        m = Msg(mid, body, copy.deepcopy(props), exchange, routing_key,
                [routing_key] + list(headers.get("CC") or []))
        delay = headers.get("x-delay")
        delayed = x.type == "x-delayed-message" and "x-delay" in headers and not headers.get("x-death")
        if delayed and not on("delay-zero-delayed"):
            delayed = isinstance(delay, int) and delay > 0
        if delayed:
            held = m.clone()
            held.ts, held.keep_ts = self.now * 1000, on("delayed-ttl-from-publish")
            self.delayed.append((self.now + max(delay if isinstance(delay, int) else 0, 0) / 1000, exchange, held))
            if ch.confirm:
                self.event(cid, ("confirm", ch.pub_seq, "ack"))
            return
        destinations = self.route_publish(exchange, m)
        message_headers = m.props.get("headers")
        if message_headers is not None and "BCC" in message_headers:
            m.bcc = message_headers.pop("BCC")
        accepted = [self.enqueue(q, m) for q in destinations]
        refused = destinations and not any(accepted)
        if mandatory and (not destinations or (refused and on("reject-publish-returns"))):
            self.event(cid, ("return", 312, exchange, routing_key, mid))
        if ch.confirm:
            self.event(cid, ("confirm", ch.pub_seq, "ack" if all(accepted) else "nack"))

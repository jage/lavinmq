#!/usr/bin/env python3
"""Model-based testing of AMQP semantics.

Generates random op sequences, runs each against a broker and the reference
model, and compares everything a client observes: replies, deliveries in
order with their properties and headers, returns, confirms, cancels, and
every queue's contents at the end. A divergence is shrunk to the smallest op
sequence, and arguments, that still shows it.

    run.py campaign [--minutes N] [--seed S] [--length L] [--strict QUIRK ...] [--out DIR] [--port P]
    run.py replay CASE.json [--strict QUIRK ...] [--port P]
    run.py quirks

`campaign` exits 1 when a divergence's signature isn't in known.txt."""
import argparse
import copy
import fnmatch
import json
import os
import sys
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:0] = [os.path.join(HERE, "..", "lib"), HERE]
import broker  # noqa: E402
import mgmt  # noqa: E402
import model as M  # noqa: E402
import ops as O  # noqa: E402
import quirks  # noqa: E402
from amqp import Closed  # noqa: E402
from sut import Sut  # noqa: E402

SETTLE = 0.03     # how long to collect asynchronous events after each op
CONFIRM = 0.3     # the longer settle a divergence must reproduce with
WAIT = 3          # how long to wait for events the broker may still send


class SlowVhostDelete(RuntimeError):
    """The broker took more than 30 s to delete a run's vhost, which happened once
    with an expire loop spinning while the vhost closed."""


class Divergence(Exception):
    def __init__(self, index, op, kind, detail):
        super().__init__(kind)
        self.index, self.op, self.kind, self.detail = index, op, kind, detail

    def shape(self):
        """What diverged, without the values: the same bug gives the same shape."""
        if self.kind == "reply":
            return f"{self.detail['model'][0]}/{self.detail['sut'][0]}"
        if self.kind == "events":
            parts = set()
            for d in self.detail.values():
                parts |= {k for k in d["model"] if d["model"][k] != d["sut"].get(k)}
            return ",".join(sorted(parts))
        return ""

    def key(self):
        return (self.kind, self.op.get("op"), self.shape())

    def json(self):
        return {"index": self.index, "op": self.op, "kind": self.kind, "detail": self.detail}


# -- comparison ---------------------------------------------------------------------

def plain(v):
    """Bytes as text, for comparing the broker's values with the model's."""
    if isinstance(v, (bytes, bytearray)):
        return v.decode("utf-8", "replace")
    if isinstance(v, dict):
        return {k: plain(x) for k, x in v.items()}
    if isinstance(v, (list, tuple)):
        return [plain(x) for x in v]
    return v


def props_key(p):
    p = {k: v for k, v in plain(p or {}).items() if v is not None}
    headers = dict(p.get("headers") or {})
    if isinstance(headers.get("x-death"), list):
        headers["x-death"] = [{k: v for k, v in d.items() if k != "time"} if isinstance(d, dict) else d
                              for d in headers["x-death"]]
    if headers:
        p["headers"] = headers
    else:
        p.pop("headers", None)
    return json.dumps(p, sort_keys=True)


def jsonable(v):
    if isinstance(v, set):
        return sorted(jsonable(x) for x in v)
    if isinstance(v, dict):
        return {k: jsonable(x) for k, x in v.items()}
    if isinstance(v, (list, tuple)):
        return [jsonable(x) for x in v]
    return v


class Confirms:
    """Expands the broker's multiple-acks into one confirm per publish."""

    def __init__(self):
        self.done = {}

    def expand(self, cid, events):
        done = self.done.setdefault(cid, set())
        out = set()
        for _, tag, multiple, kind in events:
            for t in ([t for t in range(1, tag + 1) if t not in done] if multiple else [tag]):
                done.add(t)
                out.add((t, kind))
        return out


def summarize(events, confirms=None, cid=None):
    d = {"deliver": {}, "return": [], "confirm": set(), "cancel": []}
    raw = []
    for e in events:
        if e[0] == "deliver":
            d["deliver"].setdefault(e[1], []).append((e[3], e[4], e[5], e[6], props_key(e[7])))
        elif e[0] == "return":
            d["return"].append(tuple(e[1:]))
        elif e[0] == "confirm":
            d["confirm"].add((e[1], e[2]))
        elif e[0] == "confirm-raw":
            raw.append(e)
        elif e[0] == "cancel":
            d["cancel"].append(e[1])
    if raw:
        d["confirm"] |= confirms.expand(cid, raw)
    d["return"].sort()
    d["cancel"].sort()
    return d


def deliveries_match(model, sut):
    if set(model) != set(sut):
        return False
    for tag in model:
        a, b = model[tag], sut[tag]
        if len(a) != len(b):
            return False
        for x, y in zip(a, b):
            if (x[0] != "?" and x[0] != y[0]) or x[1:] != y[1:]:
                return False
    return True


def count(d):
    return sum(len(v) for v in d["deliver"].values()) + len(d["return"]) + len(d["confirm"]) + len(d["cancel"])


def compare_events(model_events, sut_events, confirms):
    """(equal, the broker may not have sent everything yet, detail). Confirms are
    expanded on a copy, so a retry doesn't count them twice."""
    snapshot = copy.deepcopy(confirms.done)
    equal, incomplete, detail = True, False, {}
    for cid in sorted(set(model_events) | set(sut_events)):
        md = summarize(model_events.get(cid, []))
        sd = summarize(sut_events.get(cid, []), confirms, cid)
        if not (deliveries_match(md["deliver"], sd["deliver"]) and
                all(md[k] == sd[k] for k in ("return", "confirm", "cancel"))):
            equal = False
            incomplete |= count(sd) < count(md)
            detail[cid] = {"model": jsonable(md), "sut": jsonable(sd)}
    if not equal:
        confirms.done = snapshot
    return equal, incomplete, detail


def adopt_delivery_tags(m, model_events, sut_events):
    """Take the broker's delivery tags where the order of deliveries to several
    consumers on one channel isn't defined."""
    for cid, events in model_events.items():
        mine = [(e[1], e[6], e[2]) for e in events if e[0] == "deliver"]
        if not mine or cid not in m.channels:
            continue
        theirs = {}
        for consumer, mid, tag in ((e[1], e[6], e[2]) for e in sut_events.get(cid, []) if e[0] == "deliver"):
            theirs.setdefault((consumer, mid), []).append(tag)
        ch = m.channels[cid]
        unacked = dict(ch.unacked)
        moved = {}
        for consumer, mid, tag in mine:
            tags = theirs.get((consumer, mid))
            if not tags:
                return
            their_tag = tags.pop(0)
            if tag in ch.unacked:
                moved[their_tag] = ch.unacked[tag]
                del unacked[tag]
        unacked.update(moved)
        ch.unacked = unacked


# -- running ------------------------------------------------------------------------

def check_events(m, sut, model_events, confirms, i, op, settle):
    sut.pump(settle)
    sut_events = sut.take_events()
    deadline = time.monotonic() + WAIT
    while True:
        equal, incomplete, detail = compare_events(model_events, sut_events, confirms)
        if equal:
            break
        # a short TTL can expire in the broker while its events are collected: the
        # broker's clock runs up to ~100 ms ahead of the model's rounding, so wait
        # out a deadline that close, then catch the model up
        due = m.pending_deadline()
        if due is not None and due - time.time() < 0.25:
            time.sleep(max(0, due - time.time()) + 0.02)
        m.advance(time.time())
        late = m.take_events()
        if late:
            for k, v in late.items():
                model_events.setdefault(k, []).extend(v)
            continue
        if not incomplete or time.monotonic() > deadline:
            raise Divergence(i, op, "events", detail)
        sut.pump(0.05)
        for k, v in sut.take_events().items():
            sut_events.setdefault(k, []).extend(v)
    adopt_delivery_tags(m, model_events, sut_events)


def comparable(get_ok):
    """A get-ok reply without the delivery tag, and its properties as a stable string."""
    r = get_ok
    return r[:1] + r[2:6] + (props_key(r[6]), r[7])


def run(ops, b, vhost, settle=SETTLE, log=None):
    """Run ops against the broker and the model; raises Divergence at the first difference."""
    for path, body in ((f"/api/vhosts/{vhost}", {}),
                       (f"/api/permissions/{vhost}/guest", {"configure": ".*", "write": ".*", "read": ".*"})):
        status, reply = mgmt.call(b.http, "PUT", path, body, timeout=60)
        if status not in (200, 201, 204):
            raise RuntimeError(f"PUT {path}: {status} {reply[:200]!r}")
    m = M.Model()
    sut = Sut(b, vhost, m)
    state = {"confirms": Confirms()}

    def step(i, op):
        m.advance(time.time())
        model_events = m.take_events()
        op = O.resolve(op, m)
        if op is None or not O.safe(m, op):
            return
        if op["op"] in ("ack", "nack", "reject"):
            op["sut_tag"] = op["tag"]
        expected = O.apply(m, op)
        m.dispatch()
        for k, v in m.take_events().items():
            model_events.setdefault(k, []).extend(v)
        try:
            got = sut.apply(op)
        except (Closed, OSError, RuntimeError) as e:
            got = ("client-error", repr(e))
        confirms = state["confirms"]
        if op["op"] == "restart":
            confirms = state["confirms"] = Confirms()
        elif op["op"] == "close_conn" or expected[0] == "connclose":
            conn = op.get("conn") or op["ch"].split(".")[0]
            for cid in [c for c in confirms.done if c.startswith(conn + ".")]:
                del confirms.done[cid]
        if op["op"] == "close_channel" or expected[0] == "close":
            confirms.done.pop(op.get("ch"), None)
        want, have = expected, got
        if expected[0] == "get-ok" and got[0] == "get-ok":
            want, have = comparable(expected), comparable(got)
            if expected[2] == "?":
                have = have[:1] + ("?",) + have[2:]
        if want != have:
            raise Divergence(i, op, "reply", {"model": jsonable(expected), "sut": jsonable(got)})
        if expected[0] == "get-ok":
            ch = m.channels[op["ch"]]
            if expected[1] in ch.unacked and expected[1] != got[1]:
                ch.unacked[got[1]] = ch.unacked.pop(expected[1])
        check_events(m, sut, model_events, confirms, i, op, settle)
        if log:
            log.write(json.dumps({"i": i, "op": op, "reply": jsonable(expected)}) + "\n")
        due = m.pending_deadline()
        if due is not None:
            time.sleep(max(0, due - time.time()) + 0.6)
            m.advance(time.time())
            check_events(m, sut, m.take_events(), confirms, i, {"op": "timer"}, settle)

    try:
        for i, op in enumerate(ops):
            step(i, op)
        # empty every queue without consumers, comparing contents and order
        n = len(ops)
        for name in sorted(m.queues):
            q = m.queues.get(name)
            if q is None or q.consumers:
                continue
            for _ in range(len(q.ready) + 1):
                step(n, {"op": "get", "ch": f"{q.exclusive_conn or 'c0'}.9", "queue": name, "no_ack": True})
                n += 1
        for name in sorted(m.queues):
            status, body = mgmt.call(b.http, "GET", f"/api/queues/{vhost}/{name}")
            if status != 200:
                raise Divergence(len(ops), {"op": "final", "queue": name}, "final-missing", {"http": status})
            j = json.loads(body)
            if j["messages_ready"] != len(m.queues[name].ready):
                raise Divergence(len(ops), {"op": "final", "queue": name}, "final-count",
                                 {"model": len(m.queues[name].ready),
                                  "sut": {k: j.get(k) for k in ("messages_ready", "messages_unacknowledged",
                                                                "state")}})
    finally:
        sut.close()
        started = time.monotonic()
        status, _ = mgmt.call(b.http, "DELETE", f"/api/vhosts/{vhost}", timeout=300)
        took = time.monotonic() - started
        if (status is None or took > 30) and sys.exc_info()[0] is None:
            raise SlowVhostDelete(f"deleting vhost {vhost} took {took:.0f}s, status {status}")


# -- shrinking ------------------------------------------------------------------------

class Runs:
    """Names a fresh vhost for every run against one broker."""

    def __init__(self, b, prefix):
        self.b, self.prefix, self.n = b, prefix, 0

    def divergence(self, ops, settle):
        self.n += 1
        try:
            run(ops, self.b, f"{self.prefix}{self.n}", settle)
        except Divergence as d:
            return d
        return None

    def reproduces(self, ops, key, settle):
        try:
            d = self.divergence(ops, settle)
        except Exception:
            return False
        return d is not None and d.key() == key


SHRINKABLE = {"declare_queue": "args", "declare_exchange": "args", "bind_queue": "args",
              "bind_exchange": "args", "set_policy": "definition"}
FLAGS = ["mandatory", "no_ack", "exclusive", "durable", "auto_delete", "if_unused", "if_empty",
         "multiple", "requeue", "global", "internal"]


def simpler(op):
    """Variants of an op with one argument, property, header or flag less."""
    out = []
    field = SHRINKABLE.get(op["op"])
    if field and op.get(field):
        for k in op[field]:
            if k == "x-match" or (field == "definition" and len(op[field]) == 1):
                continue
            v = copy.deepcopy(op)
            del v[field][k]
            out.append(v)
    if op["op"] == "publish":
        for k in op["props"]:
            if k not in ("message-id", "delivery-mode"):
                v = copy.deepcopy(op)
                del v["props"][k]
                out.append(v)
        for k in op["props"].get("headers") or {}:
            v = copy.deepcopy(op)
            del v["props"]["headers"][k]
            if not v["props"]["headers"]:
                del v["props"]["headers"]
            out.append(v)
    for flag in FLAGS:
        if op.get(flag) is True:
            out.append({**op, flag: False})
    if op.get("priority"):
        out.append({**op, "priority": 0})
    return out


def shrink(ops, runs, key, settle, budget=300, until=None):
    """Delta debugging over the ops, then over each op's arguments, for at most
    `budget` runs or until the monotonic time `until`."""
    tries = 0

    def spent():
        return tries >= budget or (until is not None and time.monotonic() > until)

    chunk = max(1, len(ops) // 2)
    while chunk >= 1 and not spent():
        i, progress = 0, False
        while i < len(ops) and not spent():
            candidate = ops[:i] + ops[i + chunk:]
            tries += 1
            if candidate and runs.reproduces(candidate, key, settle):
                ops, progress = candidate, True
            else:
                i += chunk
        if not progress:
            chunk //= 2
    progress = True
    while progress and not spent():
        progress = False
        for i, op in enumerate(ops):
            for variant in simpler(op):
                tries += 1
                candidate = ops[:i] + [variant] + ops[i + 1:]
                if runs.reproduces(candidate, key, settle):
                    ops, progress = candidate, True
                    break
            if progress or spent():
                break
    return ops


# -- signatures -------------------------------------------------------------------------

def features(ops):
    """The behaviour a shrunk case involves: its op kinds and the arguments,
    policy keys, properties and flags that remain."""
    out = set()
    for op in ops:
        k = op["op"]
        out.add(k)
        for key in (op.get("args") or {}):
            if key not in ("x-match",):
                out.add(key)
        if op.get("args", {}).get("x-overflow"):
            out.add("x-overflow=" + op["args"]["x-overflow"])
        if k == "declare_exchange" and op.get("type"):
            out.add("type=" + op["type"])
        for key in (op.get("definition") or {}):
            out.add("policy:" + key)
        if k == "publish":
            out |= {p for p in op["props"] if p not in ("message-id", "delivery-mode", "headers")}
            out |= {"header:" + h for h in (op["props"].get("headers") or {})}
        for flag in FLAGS:
            if op.get(flag) is True:
                out.add(f"{k}:{flag}")
        if k == "consume" and op.get("priority"):
            out.add("consume:x-priority")
    return sorted(out)


def signature(d, ops):
    kind, op, shape = d.key()
    return f"{kind} {op} {shape} | {' '.join(features(ops))}".replace("  ", " ")


def known_signatures():
    out = []
    for line in open(os.path.join(HERE, "known.txt")):
        pattern, _, note = line.rstrip("\n").partition("#")
        if pattern.strip():
            out.append((pattern.strip(), note.strip()))
    return out


def known(sig, patterns):
    return next((note or pattern for pattern, note in patterns if fnmatch.fnmatchcase(sig, pattern)), None)


# -- commands ----------------------------------------------------------------------------

def start_broker(out, port):
    b = broker.Broker(os.path.join(out, "broker"), port)
    if not b.start():
        raise RuntimeError("the broker didn't start:\n" + b.log()[-2000:])
    return b


def healthy(b):
    return b.alive() and mgmt.call(b.http, "GET", "/api/overview", timeout=5)[0] == 200


def campaign(args):
    out = os.path.abspath(args.out)
    cases_dir = os.path.join(out, "cases")
    os.makedirs(cases_dir, exist_ok=True)
    b = start_broker(out, args.port)
    patterns = known_signatures()
    stats = {"runs": 0, "ops": 0, "divergences": 0, "flaky": 0, "errors": 0}
    found = {}   # signature -> case files
    flaky = []
    errors = []
    started = time.monotonic()
    end = started + args.minutes * 60
    seed = args.seed
    try:
        while time.monotonic() < end:
            seed += 1
            runs = Runs(b, f"s{seed}-")
            ops = None
            try:
                ops = O.generate(seed, args.length, M.Model)
                try:
                    d = runs.divergence(ops, SETTLE)
                except (M.DeadLetterLoop, SlowVhostDelete):
                    raise
                except Exception:
                    if not healthy(b):
                        raise
                    d = runs.divergence(ops, SETTLE)  # once more: on a busy machine a request can time out
                stats["runs"] += 1
                stats["ops"] += len(ops)
            except M.DeadLetterLoop:
                # the run reached the dead-letter loop LavinMQ can't stop (dead-letter-ping-pong);
                # its vhost is deleted, which ends the loop
                stats["loops"] = stats.get("loops", 0) + 1
                continue
            except Exception:
                stats["errors"] += 1
                errors.append(seed)
                with open(os.path.join(cases_dir, f"error-{seed}.txt"), "w") as f:
                    f.write(traceback.format_exc())
                    f.write("\nops:\n" + json.dumps(ops, default=str))
                    f.write("\nbroker log:\n" + "\n".join(b.log().splitlines()[-200:]))
                if not healthy(b):
                    errors.append(f"{seed}: broker {'unresponsive' if b.alive() else 'died'}")
                    b.kill()
                    if not b.start():
                        raise RuntimeError("the broker didn't start again:\n" + b.log()[-2000:])
                continue
            if d is None:
                continue
            stats["divergences"] += 1
            prefix = ops[:d.index + 1]
            if not runs.reproduces(prefix, d.key(), CONFIRM):
                stats["flaky"] += 1
                flaky.append(seed)
                with open(os.path.join(cases_dir, f"flaky-{seed}.json"), "w") as f:
                    json.dump({"seed": seed, "divergence": d.json(), "ops": prefix}, f, indent=1, default=str)
                continue
            small = shrink(prefix, runs, d.key(), 0.1, until=end + 600)
            final = runs.divergence(small, 0.1) or d
            sig = signature(final, small)
            path = os.path.join(cases_dir, f"case-{seed}.json")
            with open(path, "w") as f:
                json.dump({"seed": seed, "signature": sig, "strict": args.strict, "ops": small,
                           "divergence": final.json()}, f, indent=1, default=str)
            found.setdefault(sig, []).append(os.path.relpath(path, out))
            print(f"seed {seed}: {sig} ({len(small)} ops)", flush=True)
    finally:
        b.stop()
    return report(out, stats, found, flaky, errors, patterns, args, time.monotonic() - started)


def report(out, stats, found, flaky, errors, patterns, args, elapsed):
    new = {s: cs for s, cs in found.items() if known(s, patterns) is None}
    lines = [f"# AMQP model: {stats['runs']} runs, {stats['ops']} ops in {elapsed / 60:.0f} min", "",
             f"Seeds {args.seed + 1} and up, {args.length} ops each"
             + (f", strict: {', '.join(args.strict)}" if args.strict else "") + ".", "",
             f"{stats['divergences']} divergences: {sum(len(c) for c in found.values())} confirmed with "
             f"{len(found)} signatures, {len(new)} not in known.txt; {stats['flaky']} didn't reproduce. "
             f"{stats['errors']} harness errors.", ""]
    if new:
        lines += ["## New", ""] + [f"- `{s}`: {len(cs)} cases, e.g. `{cs[0]}`" for s, cs in sorted(new.items())] + [""]
    lines += ["## Known", ""] + [f"- `{s}`: {len(cs)} cases ({known(s, patterns)})"
                                 for s, cs in sorted(found.items()) if s not in new] + [""]
    if flaky:
        lines += ["## Didn't reproduce", "", ", ".join(map(str, flaky)), ""]
    if errors:
        lines += ["## Harness errors", "", ", ".join(map(str, errors)), ""]
    text = "\n".join(lines)
    with open(os.path.join(out, "summary.md"), "w") as f:
        f.write(text)
    print(text)
    return 1 if new or errors else 0


def replay(args):
    case = json.load(open(args.case))
    out = os.path.abspath(args.out)
    b = start_broker(out, args.port)
    try:
        with open(os.path.join(out, "replay.log"), "w") as log:
            try:
                run(case["ops"], b, "replay", settle=CONFIRM, log=log)
                print("no divergence")
                return 0
            except Divergence as d:
                print(signature(d, case["ops"]))
                print(json.dumps(d.json(), indent=1, default=str))
                return 1
    finally:
        b.stop()


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command", required=True)
    for name in ("campaign", "replay"):
        s = sub.add_parser(name)
        s.add_argument("--strict", nargs="+", default=[], metavar="QUIRK",
                       help="turn quirks off (ids from `run.py quirks`, or all)")
        s.add_argument("--out", default=os.path.join(HERE, "..", "runs", "model"))
        s.add_argument("--port", type=int, default=31000)
        if name == "campaign":
            s.add_argument("--minutes", type=float, default=30)
            s.add_argument("--seed", type=int, default=int(time.strftime("%Y%m%d")) * 1000)
            s.add_argument("--length", type=int, default=60)
        else:
            s.add_argument("case")
    sub.add_parser("quirks", help="list the quirks")
    args = p.parse_args()
    if args.command == "quirks":
        for q in quirks.QUIRKS.values():
            print(f"{q.id:40} {q.mode:6} {q.kind:10} {q.ref}{' (hazard)' if q.hazard else ''}\n    {q.description}")
        return 0
    if args.strict:
        quirks.strict(args.strict)
    return campaign(args) if args.command == "campaign" else replay(args)


if __name__ == "__main__":
    sys.exit(main())

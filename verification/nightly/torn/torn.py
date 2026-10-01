#!/usr/bin/env python3
"""Damaged data dirs at startup.

Seeds a broker with every kind of persistent state, then starts the broker on
copies of that data dir, each damaged the way a crash or power loss can leave
it, and checks what comes back against the intact seed.

    torn.py run [--sample N] [--seed S] [--jobs J] [--out DIR]
    torn.py replay '<case json>' [--out DIR]

`run` exits 1 when a failure signature isn't in known.txt."""
import argparse
import concurrent.futures
import hashlib
import json
import os
import queue
import random
import re
import shutil
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:0] = [os.path.join(HERE, "..", "lib"), HERE]
import broker  # noqa: E402
import state  # noqa: E402

SEGMENT_SIZE = 262144
CONFIG = {"segment_size": SEGMENT_SIZE}
PAGE = 4096
STORES = ["q.classic", "q.prio", "q.src", "q.dlx", "q.stream", "mqtt:sess1", "mqtt:sess2"]
# which definitions each file holds, so losing them there is expected
DEFINES = {"users.json": ["users", "permissions"],
           # a vhost lost from vhosts.json takes everything in it along
           "vhosts.json": ["vhosts", "queues", "exchanges", "bindings", "policies", "parameters",
                           "mqtt_permissions", "vhost_limits", "operator_policies"],
           "policies.json": ["policies"], "operator_policies.json": ["operator_policies"],
           "parameters.json": ["parameters", "global_parameters"], "limits.json": ["vhost_limits"],
           "mqtt_permissions.json": ["mqtt_permissions"],
           "definitions.amqp": ["queues", "exchanges", "bindings"]}


# -- files and cases ----------------------------------------------------------

def files(seed_dir):
    out = []
    for root, _, names in os.walk(seed_dir):
        out += [os.path.relpath(os.path.join(root, n), seed_dir) for n in names if n != ".lock"]
    return sorted(out)


def store_of(seed_dir, path):
    """The queue or MQTT session a file belongs to, if any."""
    parts = path.split(os.sep)
    if len(parts) < 3:
        return None
    qdir = os.path.join(seed_dir, parts[0], parts[1])
    if os.path.exists(os.path.join(qdir, ".queue")):
        return open(os.path.join(qdir, ".queue")).read().strip()
    if os.path.exists(os.path.join(qdir, ".metadata")):
        return "mqtt:" + json.load(open(os.path.join(qdir, ".metadata")))["client_id"]
    return None


def file_kind(seed_dir, path):
    base = os.path.basename(path)
    store = store_of(seed_dir, path)
    for prefix in ("msgs", "acks", "meta"):
        if base.startswith(prefix + "."):
            return f"{prefix}:{store}"
    if base.endswith(".msg"):
        return "retained-msg"
    if base == "index":
        return "retained-index"
    if base in (".queue", ".metadata"):
        return f"{base[1:]}:{store}"
    return base


def cases(seed_dir):
    """Every damage case for the seed, in a stable order."""
    rng = random.Random(1)
    out = []

    def add(kind, path, mode="single", **kw):
        out.append(dict(kind=kind, path=path, mode=mode, **kw))

    for path in files(seed_dir):
        full = os.path.join(seed_dir, path)
        size = os.path.getsize(full)
        base = os.path.basename(path)
        if base.startswith("msgs."):
            ends = [e for e, _, _ in state.record_ends(open(full, "rb").read())]
            picks = {ends[0], ends[-1], *rng.sample(ends, min(3, len(ends)))} if ends else set()
            cuts = {0, 1, 2, 3, 4, 5, 8, 12}
            cuts |= {b + d for b in picks for d in (-9, -5, -4, -3, -1, 0, 1, 2, 3, 4, 8, 12, 20, 30)
                     if 0 <= b + d <= size}
            cuts = sorted(cuts)
            for at in cuts:
                add("truncate", path, at=at)
            for at in rng.sample(cuts, min(4, len(cuts))):
                add("truncate", path, at=at, mode="double")
            for at in rng.sample(cuts, min(8, len(cuts))) + [size]:
                add("zerotail", path, at=at)
                add("zerotail", path, at=at, mode="double")
            # page tears: a record crossing a page boundary loses the rest
            prev = 4
            tears = []
            for e in ends:
                boundary = (prev // PAGE + 1) * PAGE
                if prev < boundary < e:
                    tears.append(boundary)
                prev = e
            for at in rng.sample(tears, min(4, len(tears))):
                add("zerotail", path, at=at)
                add("zerotail", path, at=at, mode="double")
                add("zeropage", path, at=at)
            if size > 2 * PAGE:
                add("zeropage", path, at=PAGE)
                add("zeropage", path, at=size // 2 // PAGE * PAGE)
            add("delete", path)
        elif base.startswith(("acks.", "meta.")) or base in ("consumer_offsets", "definitions.amqp", "index"):
            span = range(0, size + 1) if base == "definitions.amqp" else range(max(0, size - 40), size + 1)
            for at in sorted(set(span) | {0, 1, 2, 3, 4, size // 2}):
                add("truncate", path, at=at)
            for at in sorted({size, max(0, size - 1), max(0, size - 3), max(0, size - 5), size // 2}):
                add("zerotail", path, at=at)
                add("zerotail", path, at=at, mode="double")
            add("truncate", path, at=max(0, size - 3), mode="double")
            add("delete", path)
            if base in ("consumer_offsets", "definitions.amqp", "index"):
                for tmp in ("garbage", "copy", "partial", "empty"):
                    add("staletmp", path, tmp=tmp)
                    add("staletmp", path, tmp=tmp, mode="double")
        else:
            for at in sorted({0, 1, size // 2, max(0, size - 1)}):
                add("truncate", path, at=at)
            add("zerotail", path, at=size)
            add("zerotail", path, at=size // 2)
            add("delete", path)
            if base.endswith(".json") or base == ".metadata":
                for tmp in ("garbage", "copy", "partial", "empty"):
                    add("staletmp", path, tmp=tmp)
            if base.endswith(".msg"):
                add("orphan", path)
    unique = {}
    for c in out:
        unique.setdefault(hashlib.sha1(json.dumps(c, sort_keys=True).encode()).hexdigest()[:10], c)
    for case_id, c in unique.items():
        c["id"] = case_id
    return list(unique.values())


def mutate(data_dir, seed_dir, c):
    p = os.path.join(data_dir, c["path"])
    kind = c["kind"]
    if kind == "truncate":
        os.truncate(p, c["at"])
    elif kind == "zerotail":
        # cut, then zeros to the capacity: what a preallocated mmap file looks like
        base = os.path.basename(p)
        capacity = SEGMENT_SIZE if base.startswith("msgs.") else os.path.getsize(os.path.join(seed_dir, c["path"])) + PAGE
        os.truncate(p, c["at"])
        os.truncate(p, max(capacity, c["at"]))
    elif kind == "zeropage":
        with open(p, "r+b") as f:
            f.seek(c["at"])
            f.write(b"\0" * PAGE)
    elif kind == "delete":
        os.remove(p)
    elif kind == "staletmp":
        data = open(p, "rb").read()
        tmp = {"garbage": random.Random(c["id"]).randbytes(97), "copy": data,
               "partial": data[:len(data) // 2], "empty": b""}[c["tmp"]]
        with open(p + ".tmp", "wb") as f:
            f.write(tmp)
    elif kind == "orphan":
        shutil.copy(p, os.path.join(os.path.dirname(p), "0" * 32 + ".msg"))


# -- oracle ---------------------------------------------------------------------

def allowed_loss(seed_dir, c):
    """(store, seq) records the damage may lose: those in the damaged region of a
    segment. Damage to any other file must lose no messages."""
    if not os.path.basename(c["path"]).startswith("msgs."):
        return set()
    store = store_of(seed_dir, c["path"])
    ends = state.record_ends(open(os.path.join(seed_dir, c["path"]), "rb").read())
    if c["kind"] in ("truncate", "zerotail", "zeropage"):
        # a store can't resync past a hole, so everything after it may go too
        lost = {seq for end, _, seq in ends if end > c["at"]}
    elif c["kind"] == "delete":
        lost = {seq for _, _, seq in ends}
    else:
        lost = set()
    return {(store, seq) for seq in lost}


# the line naming what failed; the lines around it say the same thing less precisely
EXCEPTION = re.compile(r"\([A-Z]\w+(Error|Exception)\)|Unhandled exception|Failed to load|BUG:")


def normalize(text):
    text = re.sub(r"^\S+Z\s+", "", text)
    text = re.sub(r"\[vhost: [^]]*\]", "", text)
    text = re.sub(r"^Caused by: ", "", text)
    text = re.sub(r"/\S+", "PATH", text)
    text = re.sub(r"0x[0-9a-f]+|[0-9a-f]{16,}|\d+", "N", text)
    return re.sub(r"\s+", " ", text).strip()[:120]


def check(c, seed_dir, expected, got, log_failures):
    """Findings as (check, detail) pairs; an empty list means the case passed."""
    findings = [("log", normalize(line)) for line in log_failures if EXCEPTION.search(line)]
    findings += [("read-error", read_error(e)) for e in got["errors"]]
    findings += [("corrupt", "retained" if e.startswith("r/") else e.split(":")[0]) for e in got["corrupt"]]
    damaged = file_kind(seed_dir, c["path"])
    damaged_store = store_of(seed_dir, c["path"])
    may_lose = allowed_loss(seed_dir, c)
    for store in STORES:
        if store not in got["queues"]:
            continue
        ids = got["queues"][store]
        real = [i for i in ids if i[1] < state.POKE]
        want = set(map(tuple, expected["queues"].get(store, [])))
        if len(real) != len(set(real)):
            findings.append(("duplicate", store))
        phantoms = set(real) - want
        # damaged acks may bring back acked messages: at-least-once, not a phantom
        if phantoms and not (damaged.startswith("acks:") and damaged_store == store):
            findings.append(("phantom", store))
        if {i for i in want - set(real) if (store, i[1]) not in may_lose}:
            findings.append(("lost", store))
        if c["mode"] == "double" and store in ("q.classic", "q.prio", "q.stream"):
            if len([i for i in ids if i[1] >= state.POKE]) < 5:
                findings.append(("poke-lost", store))
    for tag, offset in (got.get("stream_offsets") or {}).items():
        before = expected["stream_offsets"][tag]
        if offset is not None and before is not None and offset > before:
            findings.append(("offset-forward", tag))
        elif offset is None and before is not None and damaged != "consumer_offsets":
            findings.append(("offset-lost", tag))
    if "retained" in got:
        want, have = expected["retained"], got["retained"]
        if any(t not in want or have[t] != want[t] for t in have):
            findings.append(("retained-wrong", ""))
        lost = set(want) - set(have)
        own = {t for t in lost if c["kind"] in ("truncate", "zerotail", "delete")
               and os.path.basename(c["path"]) == hashlib.md5(t.encode()).hexdigest() + ".msg"}
        if lost - own:
            findings.append(("retained-lost", ""))
    delayed = got.get("delayed")
    if delayed is not None and delayed != expected["delayed"] and not (
            delayed < expected["delayed"] and damaged_store == "amq.delayed-x.delay"):
        findings.append(("delayed-changed", ""))
    defines = DEFINES.get(os.path.basename(c["path"]), [])
    for key, items in (got.get("definitions") or {}).items():
        before = set(expected["definitions"].get(key, []))
        if set(items) - before:
            findings.append(("defs-extra", key))
        if before - set(items) and key not in defines:
            findings.append(("defs-lost", key))
    if damaged == "definitions.amqp":
        # losing definitions loses what they declared, and the messages with them
        findings = [f for f in findings if f[0] not in ("lost", "poke-lost", "offset-lost", "delayed-changed")
                    and not (f[0] == "read-error" and ("NOT_FOUND" in f[1] or "404" in f[1]))]
    return sorted(set(findings))


def read_error(text):
    """'where: Type' plus the AMQP reply, e.g. 'q.prio: Closed 541 INTERNAL_ERROR'."""
    where, _, rest = text.partition(": ")
    kind = rest.split(":", 1)[0]
    reply = re.search(r"reply-code': (\d+), 'reply-text': b?['\"]([A-Z_]+)", rest)
    status = re.search(r": (\d{3}) b'", rest)
    return f"{where}: {kind}" + (f" {reply.group(1)} {reply.group(2)}" if reply else "") + \
        (f" {status.group(1)}" if status else "")


def signature(c, seed_dir, finding):
    name, detail = finding
    return f"{name} {detail} | {c['kind']} {file_kind(seed_dir, c['path'])} {c['mode']}".replace("  ", " ")


# -- running ----------------------------------------------------------------------

def start_on(directory, port):
    b = broker.Broker(directory, port, fresh=False, config=CONFIG)
    return b, b.start(timeout=60)


def run_case(c, seed_dir, expected, work, port, keep=False):
    d = os.path.join(work, c["id"])
    shutil.rmtree(d, ignore_errors=True)
    shutil.copytree(seed_dir, os.path.join(d, "data"), symlinks=True)
    mutate(os.path.join(d, "data"), seed_dir, c)
    b, up = start_on(d, port)
    findings = []
    try:
        if not up:
            findings = [("no-start", normalize((b.failures() or [b.log().strip()[-200:]])[0]))]
            return findings
        if c["mode"] == "double":
            try:
                state.poke(b)
            except Exception as e:  # the broker misbehaving is what's tested
                findings.append(("poke-failed", normalize(f"{type(e).__name__}: {e}")))
            b.kill()
            if not b.start(timeout=60):
                return findings + [("no-restart", normalize((b.failures() or [""])[0]))]
        got = state.dump(b)
        b.stop()
        return sorted(set(findings + check(c, seed_dir, expected, got, b.failures())))
    finally:
        b.kill()
        if not keep:
            shutil.rmtree(d, ignore_errors=True)


def make_seed(work, port):
    """Seed a fresh broker, then dump an intact copy for the expected state."""
    seed_broker = broker.Broker(os.path.join(work, "seed"), port, config=CONFIG)
    if not seed_broker.start():
        raise RuntimeError("seed broker didn't start:\n" + seed_broker.log()[-2000:])
    state.seed(seed_broker)
    seed_broker.stop()
    control = os.path.join(work, "control")
    shutil.rmtree(control, ignore_errors=True)
    shutil.copytree(seed_broker.data, os.path.join(control, "data"))
    b, up = start_on(control, port)
    if not up:
        raise RuntimeError("broker didn't start on the intact seed:\n" + b.log()[-2000:])
    expected = state.dump(b)
    b.stop()
    if expected["errors"] or expected["corrupt"] or b.failures():
        raise RuntimeError(f"the intact seed doesn't read back cleanly: {expected['errors']} "
                           f"{expected['corrupt']} {b.failures()}")
    shutil.rmtree(control)
    with open(os.path.join(work, "expected.json"), "w") as f:
        json.dump(expected, f)
    return seed_broker.data, json.loads(json.dumps(expected))


def known_signatures():
    out = {}
    for line in open(os.path.join(HERE, "known.txt")):
        sig, _, note = line.rstrip("\n").partition("#")
        if sig.strip():
            out[sig.strip()] = note.strip()
    return out


def run(args):
    work = os.path.abspath(args.out)
    os.makedirs(work, exist_ok=True)
    started = time.monotonic()
    seed_dir, expected = make_seed(work, args.port)
    todo = cases(seed_dir)
    total = len(todo)
    if args.sample and args.sample < total:
        todo = random.Random(args.seed).sample(todo, args.sample)
    # an undamaged double start is the control for the double mode
    todo.insert(0, dict(id="control", kind="none", path="schema_version", mode="double"))
    print(f"{len(todo)} of {total} cases, seed {args.seed}, {args.jobs} jobs", flush=True)
    ports = queue.Queue()
    for n in range(args.jobs):
        ports.put(args.port + 10 * (n + 1))
    results = []

    def one(c):
        port = ports.get()
        try:
            return c, run_case(c, seed_dir, expected, os.path.join(work, "cases"), port)
        except Exception as e:  # a harness bug fails its case, not the run
            return c, [("harness-error", normalize(f"{type(e).__name__}: {e}"))]
        finally:
            ports.put(port)

    with open(os.path.join(work, "results.jsonl"), "w") as out, \
            concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        for n, (c, findings) in enumerate(pool.map(one, todo), start=1):
            results.append((c, findings))
            out.write(json.dumps({"case": c, "findings": findings}) + "\n")
            out.flush()
            if n % 100 == 0:
                print(f"{n}/{len(todo)} {time.monotonic() - started:.0f}s", flush=True)
    return report(results, seed_dir, work, time.monotonic() - started)


def report(results, seed_dir, work, elapsed):
    known = known_signatures()
    seen = {}
    for c, findings in results:
        for f in findings:
            seen.setdefault(signature(c, seed_dir, f), []).append(c)
    control = next(f for c, f in results if c["id"] == "control")
    new = {s: cs for s, cs in seen.items() if s not in known}
    lines = [f"# Damaged data dirs: {len(results)} cases in {elapsed / 60:.0f} min", ""]
    if control:
        lines += [f"The undamaged control failed: {control}", ""]
    lines += [f"{sum(1 for _, f in results if f)} cases failed, with {len(seen)} signatures; "
              f"{len(new)} not in known.txt.", ""]
    if new:
        lines += ["## New", ""]
        lines += [f"- `{s}`: {len(cs)} cases, e.g. `{json.dumps(cs[0])}`" for s, cs in sorted(new.items())]
        lines.append("")
    lines += ["## Known", ""]
    lines += [f"- `{s}`: {len(cs)} cases ({known[s]})" for s, cs in sorted(seen.items()) if s in known]
    text = "\n".join(lines) + "\n"
    with open(os.path.join(work, "summary.md"), "w") as f:
        f.write(text)
    print(text)
    return 1 if new or control else 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command", required=True)
    r = sub.add_parser("run")
    r.add_argument("--sample", type=int, help="run this many randomly chosen cases")
    r.add_argument("--seed", type=int, default=int(time.strftime("%Y%m%d")))
    r.add_argument("--jobs", type=int, default=4)
    r.add_argument("--port", type=int, default=30000)
    r.add_argument("--out", default=os.path.join(HERE, "..", "runs", "torn"))
    rp = sub.add_parser("replay", help="rerun one case from results.jsonl and keep its data dir")
    rp.add_argument("case")
    rp.add_argument("--out", default=os.path.join(HERE, "..", "runs", "torn"))
    rp.add_argument("--port", type=int, default=30500)
    args = p.parse_args()
    if args.command == "run":
        sys.exit(run(args))
    work = os.path.abspath(args.out)
    c = json.loads(args.case)
    c = c.get("case", c)  # a whole results.jsonl line works too
    expected = json.load(open(os.path.join(work, "expected.json")))
    findings = run_case(c, os.path.join(work, "seed", "data"), expected, os.path.join(work, "replay"),
                        args.port, keep=True)
    print(json.dumps(findings), "data dir:", os.path.join(work, "replay", c["id"]))


if __name__ == "__main__":
    main()

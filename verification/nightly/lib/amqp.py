"""A raw AMQP 0-9-1 client: frame codec plus a blocking connection that sends
any method with any field values. Built for tests that need byte-level
control, so it validates nothing it sends."""
import socket
import struct
import time

from amqp_methods import METHODS

FRAME_METHOD, FRAME_HEADER, FRAME_BODY, FRAME_HEARTBEAT = 1, 2, 3, 8
FRAME_END = 0xCE
BY_NAME = {v[0]: k for k, v in METHODS.items()}

# Basic content properties, in property flag order
PROPERTIES = [
    ("content-type", "shortstr"), ("content-encoding", "shortstr"),
    ("headers", "table"), ("delivery-mode", "octet"), ("priority", "octet"),
    ("correlation-id", "shortstr"), ("reply-to", "shortstr"),
    ("expiration", "shortstr"), ("message-id", "shortstr"),
    ("timestamp", "longlong"), ("type", "shortstr"), ("user-id", "shortstr"),
    ("app-id", "shortstr"), ("cluster-id", "shortstr"),
]


class Closed(Exception):
    """The connection or channel was closed, by the server or the socket."""


# -- encoding -----------------------------------------------------------------

def shortstr(s):
    if isinstance(s, str):
        s = s.encode()
    return struct.pack("B", len(s) & 0xFF) + s


def longstr(s):
    if isinstance(s, str):
        s = s.encode()
    return struct.pack(">I", len(s)) + s


def field_value(v):
    """Encode a Python value as a typed field value. A (tag, bytes) tuple is
    sent as is, for values Python has no type for."""
    if isinstance(v, tuple):
        tag, raw = v
        return tag.encode() + raw
    if v is None:
        return b"V"
    if isinstance(v, bool):
        return b"t" + bytes([v])
    if isinstance(v, int):
        if -2**31 <= v < 2**31:
            return b"I" + struct.pack(">i", v)
        return b"l" + struct.pack(">q", v)
    if isinstance(v, float):
        return b"d" + struct.pack(">d", v)
    if isinstance(v, (str, bytes)):
        return b"S" + longstr(v)
    if isinstance(v, dict):
        return b"F" + table(v)
    if isinstance(v, list):
        body = b"".join(field_value(x) for x in v)
        return b"A" + struct.pack(">I", len(body)) + body
    raise TypeError(f"no AMQP field type for {v!r}")


def table(d):
    """Encode a dict as a field table; bytes are sent as the table body."""
    if isinstance(d, bytes):
        return struct.pack(">I", len(d)) + d
    body = b"".join(shortstr(k) + field_value(v) for k, v in d.items())
    return struct.pack(">I", len(body)) + body


def encode_fields(fields, args):
    out = bytearray()
    bits = []

    def flush_bits():
        if bits:
            out.append(sum(1 << i for i, b in enumerate(bits) if b))
            bits.clear()

    for name, typ in fields:
        v = args.get(name)
        if typ == "bit":
            bits.append(bool(v))
            if len(bits) == 8:
                flush_bits()
            continue
        flush_bits()
        if typ == "octet":
            out += struct.pack("B", (v or 0) & 0xFF)
        elif typ == "short":
            out += struct.pack(">H", (v or 0) & 0xFFFF)
        elif typ == "long":
            out += struct.pack(">I", (v or 0) & 0xFFFFFFFF)
        elif typ == "longlong":
            out += struct.pack(">Q", (v or 0) & 0xFFFFFFFFFFFFFFFF)
        elif typ == "shortstr":
            out += shortstr(v or "")
        elif typ == "longstr":
            out += longstr(v or b"")
        elif typ == "table":
            out += table(v if v is not None else {})
        else:
            raise ValueError(f"unknown field type {typ}")
    flush_bits()
    return bytes(out)


def method_payload(name, args):
    class_id, method_id = BY_NAME[name]
    return struct.pack(">HH", class_id, method_id) + encode_fields(METHODS[(class_id, method_id)][1], args)


def frame(frame_type, channel, payload):
    return struct.pack(">BHI", frame_type, channel & 0xFFFF, len(payload)) + payload + bytes([FRAME_END])


def header_payload(body_size, props, class_id=60):
    flags = 0
    data = b""
    for i, (name, typ) in enumerate(PROPERTIES):
        if name in props:
            flags |= 1 << (15 - i)
            data += encode_fields([(name, typ)], props)
    return struct.pack(">HHQH", class_id, 0, body_size, flags) + data


# -- decoding -----------------------------------------------------------------

class Reader:
    def __init__(self, data):
        self.data = data
        self.pos = 0

    def take(self, n):
        v = self.data[self.pos:self.pos + n]
        if len(v) < n:
            raise EOFError
        self.pos += n
        return v

    def unpack(self, fmt):
        return struct.unpack(fmt, self.take(struct.calcsize(fmt)))[0]

    def shortstr(self):
        return self.take(self.unpack("B"))

    def longstr(self):
        return self.take(self.unpack(">I"))

    def table(self):
        r = Reader(self.longstr())
        out = {}
        while r.pos < len(r.data):
            key = r.shortstr().decode("utf-8", "replace")
            out[key] = r.value()
        return out

    def value(self):
        tag = chr(self.unpack("B"))
        fmt = {"b": ">b", "B": "B", "s": ">h", "u": ">H", "I": ">i", "i": ">I",
               "l": ">q", "L": ">Q", "f": ">f", "d": ">d", "T": ">Q"}.get(tag)
        if fmt:
            return self.unpack(fmt)
        if tag == "t":
            return bool(self.unpack("B"))
        if tag in "Sx":
            return self.longstr()
        if tag == "D":
            scale = self.unpack("B")
            return ("decimal", scale, self.unpack(">i"))
        if tag == "A":
            r = Reader(self.longstr())
            out = []
            while r.pos < len(r.data):
                out.append(r.value())
            return out
        if tag == "F":
            return self.table()
        if tag == "V":
            return None
        raise ValueError(f"bad field type {tag!r}")

    def fields(self, fields):
        out = {}
        bit = 8
        byte = 0
        for name, typ in fields:
            if typ == "bit":
                if bit == 8:
                    byte, bit = self.unpack("B"), 0
                out[name] = bool(byte & (1 << bit))
                bit += 1
                continue
            bit = 8
            if typ == "table":
                out[name] = self.table()
            elif typ in ("shortstr", "longstr"):
                out[name] = getattr(self, typ)()
            else:
                out[name] = self.unpack({"octet": "B", "short": ">H", "long": ">I", "longlong": ">Q"}[typ])
        return out

    def properties(self):
        flags = self.unpack(">H")
        present = [p for i, p in enumerate(PROPERTIES) if flags & (1 << (15 - i))]
        return self.fields(present)


class Frame:
    def __init__(self, frame_type, channel, payload):
        self.type, self.channel, self.payload = frame_type, channel, payload
        self.name = {FRAME_HEADER: "header", FRAME_BODY: "body", FRAME_HEARTBEAT: "heartbeat"}.get(frame_type)
        self.args = {}
        if frame_type == FRAME_METHOD and len(payload) >= 4:
            key = struct.unpack(">HH", payload[:4])
            name, fields, _content = METHODS.get(key, (str(key), [], False))
            self.name = name
            try:
                self.args = Reader(payload[4:]).fields(fields)
            except (EOFError, ValueError, KeyError) as e:
                self.args = {"decode-error": repr(e)}
        elif frame_type == FRAME_HEADER:
            r = Reader(payload)
            r.take(4)
            self.args = {"body-size": r.unpack(">Q")}
            self.args["properties"] = r.properties()

    def __repr__(self):
        return f"<{self.channel}:{self.name} {self.args}>"


class Message:
    def __init__(self, method, properties, body):
        self.method, self.properties, self.body = method, properties, body

    @property
    def delivery_tag(self):
        return self.method.args["delivery-tag"]


# -- connection ---------------------------------------------------------------

class Connection:
    def __init__(self, port, user="guest", password="guest", vhost="/", timeout=5,
                 frame_max=131072, channel_max=2047, heartbeat=0, handshake=True):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout)
        self.buf = b""
        self.frames = []
        self.closed = None
        self.frame_max = frame_max
        if handshake:
            self.handshake(user, password, vhost, frame_max, channel_max, heartbeat)

    def raw(self, data):
        try:
            self.sock.sendall(data)
        except OSError as e:
            raise Closed(repr(e)) from e

    def send(self, channel, name, **args):
        """Send a method. Fields use the spec's names, e.g. **{"routing-key": "q"}."""
        self.raw(frame(FRAME_METHOD, channel, method_payload(name, args)))

    def publish(self, channel, exchange, routing_key, body, props=None, mandatory=False):
        data = frame(FRAME_METHOD, channel, method_payload(
            "basic.publish", {"exchange": exchange, "routing-key": routing_key, "mandatory": mandatory}))
        data += frame(FRAME_HEADER, channel, header_payload(len(body), props or {}))
        size = self.frame_max - 8
        for i in range(0, len(body), size):
            data += frame(FRAME_BODY, channel, body[i:i + size])
        self.raw(data)

    def _read(self, timeout):
        self.sock.settimeout(max(timeout, 0.001))
        try:
            data = self.sock.recv(1 << 20)
        except socket.timeout:
            return False
        except OSError as e:
            self.closed = self.closed or ("socket", repr(e))
            raise Closed(repr(e)) from e
        if not data:
            self.closed = self.closed or ("eof",)
            raise Closed("eof")
        self.buf += data
        return True

    def _parse(self):
        while len(self.buf) >= 7:
            frame_type, channel, size = struct.unpack(">BHI", self.buf[:7])
            if len(self.buf) < size + 8:
                return
            payload, end = self.buf[7:7 + size], self.buf[7 + size]
            self.buf = self.buf[size + 8:]
            if end != FRAME_END:
                raise Closed("bad frame end from server")
            f = Frame(frame_type, channel, payload)
            if f.name == "connection.close":
                self.closed = ("connection.close", f.args.get("reply-code"), f.args.get("reply-text"))
                try:
                    self.send(0, "connection.close-ok")
                except Closed:
                    pass
            self.frames.append(f)

    def recv(self, timeout=5, until=None):
        """The first frame matching `until`, or None after the timeout."""
        deadline = time.monotonic() + timeout
        while True:
            self._parse()
            while self.frames:
                f = self.frames.pop(0)
                if until is None or until(f):
                    return f
            left = deadline - time.monotonic()
            if left <= 0:
                return None
            self._read(left)

    def drain(self, timeout=0.05):
        """Every frame that arrives within the timeout."""
        out = []
        deadline = time.monotonic() + timeout
        try:
            while True:
                self._parse()
                out += self.frames
                self.frames = []
                left = deadline - time.monotonic()
                if left <= 0 or not self._read(left):
                    break
        except Closed:
            out += self.frames
            self.frames = []
        return out

    def expect(self, name, channel=None, timeout=5):
        """Wait for a method; raise Closed if the channel or connection closes first."""
        def match(f):
            if f.name == name and (channel is None or f.channel == channel):
                return True
            if f.name == "connection.close" or (f.name == "channel.close" and f.channel in (channel, None)):
                raise Closed(f"{f.name} {f.args}")
            return False
        f = self.recv(timeout, match)
        if f is None:
            raise TimeoutError(f"no {name} within {timeout}s")
        return f

    def call(self, channel, name, reply, **args):
        self.send(channel, name, **args)
        return self.expect(reply, channel)

    def handshake(self, user, password, vhost, frame_max, channel_max, heartbeat):
        self.raw(b"AMQP\x00\x00\x09\x01")
        start = self.expect("connection.start")
        self.server_properties = start.args.get("server-properties")
        capabilities = {"publisher_confirms": True, "consumer_cancel_notify": True,
                        "basic.nack": True, "connection.blocked": True}
        self.send(0, "connection.start-ok", **{
            "client-properties": {"product": "lavinmq-nightly", "capabilities": capabilities},
            "mechanism": "PLAIN", "locale": "en_US",
            "response": b"\x00" + user.encode() + b"\x00" + password.encode()})
        tune = self.expect("connection.tune")
        self.frame_max = min(frame_max, tune.args["frame-max"] or frame_max)
        self.send(0, "connection.tune-ok", **{"channel-max": channel_max, "frame-max": self.frame_max,
                                              "heartbeat": heartbeat})
        self.call(0, "connection.open", "connection.open-ok", **{"virtual-host": vhost})

    def channel(self, number=1, confirm=False, prefetch=None):
        self.call(number, "channel.open", "channel.open-ok")
        if confirm:
            self.call(number, "confirm.select", "confirm.select-ok")
        if prefetch is not None:
            self.call(number, "basic.qos", "basic.qos-ok", **{"prefetch-count": prefetch})
        return number

    def read_message(self, method, timeout=5):
        """The header and body frames that follow a deliver or get-ok."""
        header = self.recv(timeout, lambda f: f.type == FRAME_HEADER and f.channel == method.channel)
        if header is None:
            raise TimeoutError("no content header")
        body = b""
        while len(body) < header.args["body-size"]:
            f = self.recv(timeout, lambda f: f.type == FRAME_BODY and f.channel == method.channel)
            if f is None:
                raise TimeoutError("no content body")
            body += f.payload
        return Message(method, header.args["properties"], body)

    def get(self, channel, queue, no_ack=False, timeout=5):
        """basic.get: a Message, or None when the queue is empty."""
        self.send(channel, "basic.get", queue=queue, **{"no-ack": no_ack})
        f = self.recv(timeout, lambda f: f.channel == channel and f.name in (
            "basic.get-ok", "basic.get-empty", "channel.close", "connection.close"))
        if f is None:
            raise TimeoutError("no basic.get reply")
        if f.name in ("channel.close", "connection.close"):
            raise Closed(f"{f.name} {f.args}")
        return self.read_message(f, timeout) if f.name == "basic.get-ok" else None

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

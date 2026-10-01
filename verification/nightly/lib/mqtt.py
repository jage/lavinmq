"""A raw MQTT 3.1.1 client: packet builders plus a blocking connection. Like
the AMQP client, it validates nothing it sends."""
import socket
import struct
import time

NAMES = {1: "CONNECT", 2: "CONNACK", 3: "PUBLISH", 4: "PUBACK", 5: "PUBREC",
         6: "PUBREL", 7: "PUBCOMP", 8: "SUBSCRIBE", 9: "SUBACK", 10: "UNSUBSCRIBE",
         11: "UNSUBACK", 12: "PINGREQ", 13: "PINGRESP", 14: "DISCONNECT"}
CONNACK, PUBLISH, PUBACK, SUBACK, UNSUBACK = 2, 3, 4, 9, 11
PINGREQ = b"\xc0\x00"
DISCONNECT = b"\xe0\x00"


class Closed(Exception):
    """The server closed the connection."""


def remaining_length(n):
    out = bytearray()
    while True:
        b, n = n % 128, n // 128
        out.append(b | (128 if n else 0))
        if not n:
            return bytes(out)


def string(x):
    if isinstance(x, str):
        x = x.encode()
    return struct.pack(">H", len(x)) + x


def packet(first, body):
    return bytes([first]) + remaining_length(len(body)) + body


def connect(client_id, clean=True, keepalive=60, user="guest", password="guest", will=None):
    """will is (topic, payload, qos, retain)."""
    flags = 2 if clean else 0
    payload = string(client_id)
    if will:
        topic, message, qos, retain = will
        flags |= 4 | (qos << 3) | (32 if retain else 0)
        payload += string(topic) + string(message)
    if user is not None:
        flags |= 128
        payload += string(user)
    if password is not None:
        flags |= 64
        payload += string(password)
    return packet(0x10, string("MQTT") + bytes([4, flags]) + struct.pack(">H", keepalive) + payload)


def publish(topic, payload=b"", qos=0, packet_id=1, retain=False, dup=False):
    if isinstance(payload, str):
        payload = payload.encode()
    first = 0x30 | (qos << 1) | (1 if retain else 0) | (8 if dup else 0)
    body = string(topic) + (struct.pack(">H", packet_id) if qos else b"")
    return packet(first, body + payload)


def subscribe(packet_id, filters):
    """filters is [(filter, qos)]."""
    body = struct.pack(">H", packet_id) + b"".join(string(f) + bytes([q]) for f, q in filters)
    return packet(0x82, body)


def unsubscribe(packet_id, filters):
    return packet(0xA2, struct.pack(">H", packet_id) + b"".join(string(f) for f in filters))


def puback(packet_id):
    return packet(0x40, struct.pack(">H", packet_id))


class Packet:
    def __init__(self, first, body):
        self.first, self.body = first, body
        self.type, self.flags = first >> 4, first & 15

    @property
    def name(self):
        return NAMES.get(self.type, str(self.type))

    @property
    def qos(self):
        return (self.flags >> 1) & 3

    @property
    def retain(self):
        return bool(self.flags & 1)

    @property
    def dup(self):
        return bool(self.flags & 8)

    def _topic_length(self):
        return struct.unpack(">H", self.body[:2])[0]

    @property
    def topic(self):
        return self.body[2:2 + self._topic_length()].decode("utf-8", "surrogateescape")

    @property
    def packet_id(self):
        if self.type != PUBLISH:
            return struct.unpack(">H", self.body[:2])[0]
        n = self._topic_length()
        return struct.unpack(">H", self.body[2 + n:4 + n])[0] if self.qos else None

    @property
    def payload(self):
        return self.body[2 + self._topic_length() + (2 if self.qos else 0):]

    def __repr__(self):
        if self.type == PUBLISH:
            return (f"PUBLISH(topic={self.topic!r}, qos={self.qos}, retain={self.retain}, "
                    f"dup={self.dup}, id={self.packet_id}, payload={self.payload[:40]!r})")
        return f"{self.name}({self.body.hex()})"


class Connection:
    def __init__(self, port, timeout=5):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=timeout)
        self.buf = b""
        self.session_present = None

    @classmethod
    def open(cls, port, client_id, clean=True, **kwargs):
        """Connect and wait for a successful CONNACK."""
        c = cls(port)
        c.send(connect(client_id, clean, **kwargs))
        ack = c.expect(CONNACK)
        if ack.body[1] != 0:
            raise ConnectionError(f"CONNACK return code {ack.body[1]}")
        c.session_present = bool(ack.body[0] & 1)
        return c

    def send(self, data):
        try:
            self.sock.sendall(data)
        except OSError as e:
            raise Closed(repr(e)) from e

    def _fill(self, n, deadline):
        while len(self.buf) < n:
            left = deadline - time.monotonic()
            if left <= 0:
                raise TimeoutError("no MQTT packet")
            self.sock.settimeout(left)
            try:
                data = self.sock.recv(65536)
            except socket.timeout as e:
                raise TimeoutError("no MQTT packet") from e
            except OSError as e:
                raise Closed(repr(e)) from e
            if not data:
                raise Closed("eof")
            self.buf += data

    def recv(self, timeout=5):
        """The next packet; TimeoutError if none arrives, Closed if the server closes."""
        deadline = time.monotonic() + timeout
        self._fill(2, deadline)
        i, multiplier, length = 1, 1, 0
        while True:
            self._fill(i + 1, deadline)
            b = self.buf[i]
            length += (b & 127) * multiplier
            multiplier *= 128
            i += 1
            if not b & 128:
                break
        self._fill(i + length, deadline)
        p = Packet(self.buf[0], self.buf[i:i + length])
        self.buf = self.buf[i + length:]
        return p

    def expect(self, packet_type, timeout=5):
        p = self.recv(timeout)
        if p.type != packet_type:
            raise AssertionError(f"expected {NAMES[packet_type]}, got {p!r}")
        return p

    def drain(self, timeout=0.5):
        """Every packet that arrives until none comes within the timeout."""
        out = []
        try:
            while True:
                out.append(self.recv(timeout))
        except (TimeoutError, Closed):
            pass
        return out

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

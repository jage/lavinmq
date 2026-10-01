"""A small client for the management HTTP API."""
import base64
import json
import socket
import urllib.error
import urllib.parse
import urllib.request

GUEST = "Basic " + base64.b64encode(b"guest:guest").decode()


def quote(name):
    return urllib.parse.quote(name, safe="")


def call(port, method, path, body=None, raw=None, timeout=10, auth=GUEST):
    """(status, body bytes); status is None when the request didn't complete."""
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, method=method)
    if auth:
        req.add_header("Authorization", auth)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except (urllib.error.URLError, socket.timeout, ConnectionError, TimeoutError) as e:
        return None, repr(e).encode()


def get_json(port, path, timeout=10):
    status, body = call(port, "GET", path, timeout=timeout)
    if status != 200:
        raise RuntimeError(f"GET {path}: {status} {body[:200]!r}")
    return json.loads(body)


def put(port, path, body):
    status, reply = call(port, "PUT", path, body)
    if status not in (200, 201, 204):
        raise RuntimeError(f"PUT {path}: {status} {reply[:200]!r}")

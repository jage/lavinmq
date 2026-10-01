"""Start, stop and kill a LavinMQ process on its own ports and data dir."""
import os
import re
import shutil
import signal
import socket
import subprocess
import time

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
BIN = os.environ.get("LAVINMQ_BIN", os.path.join(REPO, "bin", "lavinmq"))

# Log lines that mean the broker failed, as opposed to a client misbehaving
FAILURE = re.compile(
    r"Unhandled exception|Invalid memory access|Stack overflow|GC Warning|"
    r"Index out of bounds|Arithmetic overflow|Nil assertion|"
    r"(IndexError|KeyError|OverflowError|TypeCastError|DivisionByZeroError|ArgumentError)\)|"
    r"Unexpected error|Failed to load|BUG:")


class Broker:
    """One broker. Ports are base_port (AMQP), +1 (HTTP), +2 (MQTT), +3 (metrics)."""

    def __init__(self, directory, base_port, fresh=True, sync=False):
        self.dir = directory
        self.data = os.path.join(directory, "data")
        self.log_path = os.path.join(directory, "broker.log")
        self.amqp, self.http, self.mqtt, self.metrics = (base_port + i for i in range(4))
        self.sync = sync
        self.proc = None
        self.log_pos = 0
        if fresh:
            shutil.rmtree(directory, ignore_errors=True)
        os.makedirs(self.data, exist_ok=True)

    def command(self):
        cmd = [BIN, "--data-dir", self.data, "--bind", "127.0.0.1",
               "--amqp-port", str(self.amqp), "--http-port", str(self.http),
               "--mqtt-port", str(self.mqtt), "--metrics-http-port", str(self.metrics),
               "--amqps-port=-1", "--mqtts-port=-1",
               "--control-unix-path", os.path.join(self.dir, "ctl.sock")]
        if not self.sync:
            cmd.append("--no-sync")
        return cmd

    def start(self, timeout=30):
        """Start and wait until every listener accepts. False if it exits or times out."""
        with open(self.log_path, "ab") as log:
            self.proc = subprocess.Popen(self.command(), stdout=log, stderr=subprocess.STDOUT,
                                         start_new_session=True)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                return False
            try:
                for port in (self.amqp, self.http, self.mqtt):
                    socket.create_connection(("127.0.0.1", port), 0.5).close()
                return True
            except OSError:
                time.sleep(0.1)
        return False

    def alive(self):
        return self.proc is not None and self.proc.poll() is None

    def stop(self, timeout=30):
        """Graceful shutdown. Returns the exit code, or None if it had to be killed."""
        if not self.alive():
            return self.proc.returncode if self.proc else None
        self.proc.send_signal(signal.SIGTERM)
        try:
            return self.proc.wait(timeout)
        except subprocess.TimeoutExpired:
            self.kill()
            return None

    def kill(self):
        """SIGKILL: the process dies, the page cache keeps what it wrote."""
        if self.alive():
            self.proc.kill()
            self.proc.wait()

    def log(self):
        with open(self.log_path, "rb") as f:
            return f.read().decode("utf-8", "replace")

    def new_log(self):
        """Log written since the previous call."""
        with open(self.log_path, "rb") as f:
            f.seek(self.log_pos)
            data = f.read()
            self.log_pos = f.tell()
        return data.decode("utf-8", "replace")

    def failures(self, text=None):
        """Log lines that look like broker-side failures."""
        return [line for line in (self.log() if text is None else text).splitlines() if FAILURE.search(line)]

    def rss_kib(self):
        with open(f"/proc/{self.proc.pid}/status") as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1])
        return 0

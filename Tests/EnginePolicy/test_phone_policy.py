#!/usr/bin/env python3
"""Test the built engine's stdin policy path with an isolated JavaScript fixture.

Usage: python3 Tests/EnginePolicy/test_phone_policy.py /path/to/passtrami-engine
No browser or Apple Passwords request is made. The fixture never opens its FIFO.
"""

import json
import os
from pathlib import Path
import queue
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid


SESSION_SCRIPT = r"""
const held = new Set();
const post = message => __nativePost(JSON.stringify(message));
const emit = name => post({op: "emit", event: {type: "fixture", name}});
const reply = connection => post({
    op: "reply", connection,
    text: JSON.stringify({ok: true, password: "synthetic-policy-test-value"})
});
globalThis.Passtrami = {
    receive(text) {
        const event = JSON.parse(text);
        if (event.type === "ready") {
            post({op: "emit", event: {type: "state", state: "unlocked"}});
        } else if (event.type === "request") {
            const request = JSON.parse(event.text);
            if (request.op !== "get" || request.domain !== "example.invalid") {
                throw new Error("Unexpected fixture request");
            }
            if (request.username === "mint") reply(event.connection);
            else if (request.username === "pending") {
                held.add(event.connection);
                emit("pending");
            } else throw new Error("Unexpected fixture account");
        } else if (event.type === "clientClosed" && held.has(event.connection)) {
            emit("cancelled");
        } else if (event.type === "approvalPolicyChanged") {
            // A reply that races cancellation must not create another lease.
            for (const connection of held) reply(connection);
            held.clear();
            emit("policyChanged");
        } else if (event.type === "command") {
            if (event.command.op === "fixtureBarrier") emit("barrier");
            else if (event.command.op === "shutdown") post({op: "shutdown"});
        }
    }
};
"""


class EngineFixture:
    def __init__(self, executable):
        self.executable = executable
        self.temp = tempfile.TemporaryDirectory(prefix="pas-policy-", dir="/tmp")
        self.root = Path(self.temp.name)
        self.data = self.root / "data"
        self.events = queue.Queue()
        self.received = []
        self.process = None
        self.reader = None
        self.error_file = None

    def __enter__(self):
        try:
            resources = self.root / "resources"
            scripts = resources / "Engine"
            scripts.mkdir(parents=True)
            (scripts / "credentials.js").write_text("// No credential implementation.\n")
            (scripts / "session.js").write_text(SESSION_SCRIPT)
            self.error_file = (self.root / "stderr").open("wb")
            self.process = subprocess.Popen(
                [str(self.executable), "--resources", str(resources),
                 "--data-dir", str(self.data)],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.error_file,
                text=True, start_new_session=True,
            )
            self.reader = threading.Thread(target=self.read_events, daemon=True)
            self.reader.start()
            self.wait_event({"type": "state", "state": "unlocked"})
            self.send({"op": "mcp", "enabled": True})
            self.barrier()
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def read_events(self):
        for line in self.process.stdout:
            try:
                self.events.put(json.loads(line))
            except json.JSONDecodeError:
                self.events.put({"invalid_json": True})

    def wait_event(self, expected, timeout=3):
        deadline = time.monotonic() + timeout
        while True:
            for index, event in enumerate(self.received):
                if event == expected:
                    return self.received.pop(index)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError("Expected engine event was not received")
            try:
                self.received.append(self.events.get(timeout=remaining))
            except queue.Empty:
                raise AssertionError("Expected engine event was not received") from None

    def send(self, value):
        self.process.stdin.write(json.dumps(value) + "\n")
        self.process.stdin.flush()

    def barrier(self):
        self.send({"op": "fixtureBarrier"})
        self.wait_event({"type": "fixture", "name": "barrier"})

    def request(self, value):
        client = socket.socket(socket.AF_UNIX)
        client.settimeout(3)
        try:
            client.connect(str(self.data / "passtrami.sock"))
            client.sendall(json.dumps(value).encode() + b"\n")
            return client
        except BaseException:
            client.close()
            raise

    @staticmethod
    def response(client):
        data = bytearray()
        while b"\n" not in data:
            chunk = client.recv(4096)
            if not chunk:
                raise AssertionError("Engine closed the client before its response")
            data.extend(chunk)
            if len(data) > 16_384:
                raise AssertionError("Unexpected response size")
        return json.loads(data.split(b"\n", 1)[0])

    def __exit__(self, *_):
        try:
            if self.process is not None:
                if self.process.poll() is None:
                    try:
                        self.send({"op": "shutdown"})
                        self.process.wait(timeout=3)
                    except (BrokenPipeError, subprocess.TimeoutExpired):
                        os.killpg(self.process.pid, signal.SIGKILL)
                        self.process.wait(timeout=3)
                self.process.stdin.close()
                if self.reader is not None:
                    self.reader.join(timeout=1)
                self.process.stdout.close()
        finally:
            if self.error_file is not None:
                self.error_file.close()
            self.temp.cleanup()


class PhonePolicyTests(unittest.TestCase):
    def test_repeated_false_revokes_leases_and_cancels_pending_requests(self):
        with EngineFixture(ENGINE) as engine:
            for _ in range(2):
                request = {"op": "mcp_prepare", "domain": "example.invalid",
                           "username": "mint", "session": str(uuid.uuid4())}
                with engine.request(request) as client:
                    lease = engine.response(client)
                self.assertTrue(lease.get("ok"), "Fixture lease was not created")
                self.assertNotIn("password", lease)
                pipe = Path(lease["path"])
                self.assertEqual(pipe.parent, engine.data / "password-pipes")
                self.assertTrue(stat.S_ISFIFO(pipe.lstat().st_mode))

                request["username"] = "pending"
                with engine.request(request) as pending:
                    engine.wait_event({"type": "fixture", "name": "pending"})
                    # No true policy is sent: initial and subsequent values are false.
                    engine.send({"op": "phoneApprovalPolicy", "required": False})
                    engine.barrier()
                    self.assertFalse(pipe.exists(), "Same-false policy retained a live lease")
                    result = engine.response(pending)
                    self.assertFalse(result.get("ok"))
                    self.assertEqual(result.get("code"), "cancelled")
                    engine.wait_event({"type": "fixture", "name": "cancelled"})
                    engine.wait_event({"type": "fixture", "name": "policyChanged"})

                self.assertEqual(list((engine.data / "password-pipes").iterdir()), [],
                                 "A late reply recreated a revoked lease")
                self.assertFalse((engine.data / "approval-preference.json").exists())
            with engine.request({"op": "mcp_status"}) as client:
                self.assertEqual(engine.response(client),
                                 {"ok": True, "enabled": True, "state": "unlocked"})
        self.assertEqual(engine.process.returncode, 0, "Engine did not stop cleanly")
        self.assertFalse(engine.root.exists(), "Temporary engine files were not removed")


if __name__ == "__main__":
    if len(sys.argv) != 2 or not Path(sys.argv[1]).is_file():
        sys.exit("Usage: test_phone_policy.py /path/to/passtrami-engine")
    ENGINE = Path(sys.argv.pop()).resolve()
    unittest.main()

#!/usr/bin/env python3
"""Exercise the actual SDK stdio server with an isolated, fake engine."""
import json
import os
import queue
import secrets
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


class Engine:
    def __init__(self, path):
        self.secret = secrets.token_hex(32)
        self.requests = []
        self.held = threading.Event()
        self.disconnected = threading.Event()
        self.closed_session = threading.Event()
        self.stop = threading.Event()
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.bind(path)
        self.socket.listen()
        self.socket.settimeout(0.1)
        self.thread = threading.Thread(target=self.listen, daemon=True)
        self.workers = []
        self.thread.start()

    def listen(self):
        while not self.stop.is_set():
            try:
                connection, _ = self.socket.accept()
            except socket.timeout:
                continue
            worker = threading.Thread(target=self.respond, args=(connection,), daemon=True)
            self.workers.append(worker)
            worker.start()

    def respond(self, connection):
        with connection:
            connection.settimeout(3)
            data = b""
            while b"\n" not in data:
                chunk = connection.recv(8192)
                if not chunk:
                    return
                data += chunk
            request = json.loads(data.split(b"\n")[0])
            self.requests.append(request)
            domain = request.get("domain")
            operation = request["op"]
            if domain == "hold.example":
                self.held.set()
                try:
                    if connection.recv(1) == b"":
                        self.disconnected.set()
                except (ConnectionResetError, socket.timeout):
                    pass
                return
            if operation == "mcp_close":
                self.closed_session.set()
            if domain == "malformed.example":
                connection.sendall(self.secret.encode() + b"\n")
                return
            if domain == "disabled.example":
                reply = {"ok": False, "code": "mcp_disabled", "message": self.secret}
            elif domain == "failed.example":
                reply = {"ok": False, "code": self.secret, "message": self.secret}
            elif operation == "mcp_status":
                reply = {"ok": True, "enabled": True, "state": "unlocked"}
            elif operation == "mcp_list":
                reply = {"ok": True, "usernames": ["person@example.com"]}
            elif operation == "mcp_prepare":
                reply = {"ok": True, "lease_id": str(uuid.uuid4()), "path": "/tmp/aster-test/password",
                         "expires_at": "2099-01-01T00:00:00Z", "format": "utf8", "single_use": True}
                if domain == "invalid.example":
                    reply["lease_id"] = self.secret
            else:
                reply = {"ok": True}
            # Every response contains fields that must never leave the helper.
            reply.update(password=self.secret, unexpected={"secret": self.secret}, message=self.secret)
            try:
                connection.sendall(json.dumps(reply).encode() + b"\n")
            except BrokenPipeError:
                pass

    def close(self):
        self.stop.set()
        self.thread.join(timeout=2)
        self.socket.close()
        for worker in self.workers:
            worker.join(timeout=4)


class Client:
    processes = []

    def __init__(self, helper, path):
        self.process = subprocess.Popen([helper, path], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE)
        self.processes.append(self.process)
        self.output = []
        self.messages = queue.Queue()

        def read():
            for line in self.process.stdout:
                self.output.append(line)
                self.messages.put(json.loads(line))

        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()
        self.send("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                 "clientInfo": {"name": "aster-test", "version": "1"}}, 1)
        initialized = self.receive(1)["result"]
        require("aster://docs/credential-access" in initialized["instructions"], "Missing startup instructions")
        self.send("notifications/initialized", {})

    def send(self, method, params, request_id=None):
        message = {"jsonrpc": "2.0", "method": method, "params": params}
        if request_id is not None:
            message["id"] = request_id
        self.process.stdin.write(json.dumps(message).encode() + b"\n")
        self.process.stdin.flush()

    def receive(self, request_id):
        message = self.messages.get(timeout=5)
        require(message.get("id") == request_id, "Unexpected response ID")
        return message

    def tool(self, name, arguments, request_id):
        self.send("tools/call", {"name": name, "arguments": arguments}, request_id)
        return self.receive(request_id)

    def finish(self, secret, terminate=False):
        if terminate:
            self.process.terminate()
        else:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            raise RuntimeError("Helper did not stop") from None
        self.reader.join(timeout=2)
        stderr = self.process.stderr.read()
        output = b"".join(self.output) + stderr
        require(secret.encode() not in output, "Concealed test value reached stdio")
        require(self.process.returncode == 0, "Helper exited with an error")


def normal_flow(helper, path, engine):
    client = Client(helper, path)
    try:
        client.send("tools/list", {}, 2)
        tools = client.receive(2)["result"]["tools"]
        require({tool["name"] for tool in tools} == {"status", "list_accounts", "prepare_password", "revoke_password"},
                "Wrong tool set")
        client.send("resources/list", {}, 3)
        require(len(client.receive(3)["result"]["resources"]) == 1, "Wrong resource set")
        client.send("resources/read", {"uri": "aster://docs/credential-access"}, 4)
        guide = client.receive(4)["result"]["contents"][0]["text"]
        require("Do not run `cat`" in guide and "60 seconds" in guide, "Incomplete workflow guide")
        status = client.tool("status", {}, 5)["result"]["structuredContent"]
        require(status == {"enabled": True, "state": "unlocked"}, "Status leaked unexpected fields")
        accounts = client.tool("list_accounts", {"domain": "example.com"}, 6)["result"]["structuredContent"]
        require(accounts == {"usernames": ["person@example.com"]}, "Account response leaked fields")
        prepared = client.tool("prepare_password", {"domain": "example.com", "username": "person@example.com"}, 7)["result"]
        metadata = prepared["structuredContent"]
        require(set(metadata) == {"lease_id", "path", "expires_at", "format", "single_use"}, "Wrong lease metadata")
        client.tool("revoke_password", {"lease_id": metadata["lease_id"]}, 8)
        prepare_request = next(item for item in engine.requests if item["op"] == "mcp_prepare")
        revoke_request = next(item for item in engine.requests if item["op"] == "mcp_revoke")
        require(prepare_request["session"] == revoke_request["session"], "Lease session was not preserved")
        for index, domain in enumerate(["disabled.example", "failed.example", "malformed.example"], 10):
            response = client.tool("list_accounts", {"domain": domain}, index)["result"]
            require(response["isError"] is True, "Backend failure was accepted")
            if domain == "disabled.example":
                require("Enable MCP" in response["content"][0]["text"], "Disabled guidance is missing")
        invalid = client.tool("prepare_password", {"domain": "invalid.example", "username": "person"}, 13)
        require(invalid["result"]["isError"] is True, "Invalid metadata was accepted")
        for index, (tool, arguments) in enumerate([
            ("get", {}), ("status", {"extra": "value"}), ("list_accounts", {"domain": 42}),
            ("prepare_password", {"domain": "example.com"}), ("revoke_password", {"lease_id": "invalid"}),
        ], 20):
            require("error" in client.tool(tool, arguments, index), "Invalid tool call was accepted")
        client.send("resources/read", {"uri": "/tmp/aster-test/password"}, 30)
        require("error" in client.receive(30), "Pipe path accepted as an MCP resource")

        engine.closed_session.clear()
        client.send("tools/call", {"name": "list_accounts", "arguments": {"domain": "hold.example"}}, 40)
        require(engine.held.wait(3), "Pending operation did not start")
        client.send("notifications/cancelled", {"requestId": 40})
        require(engine.disconnected.wait(3), "Cancellation did not close the IPC socket")
        require(engine.closed_session.wait(3), "Cancellation did not revoke session leases")
        client.tool("prepare_password", {"domain": "example.com", "username": "person"}, 41)
        sessions = [item["session"] for item in engine.requests if item["op"] == "mcp_prepare"]
        require(sessions[-1] != sessions[0], "Cancelled session was reused")
    finally:
        client.finish(engine.secret)


def main():
    helper = os.path.abspath(sys.argv[1])
    with tempfile.TemporaryDirectory(prefix="aster-mcp-", dir="/tmp") as directory:
        path = directory + "/engine.sock"
        engine = Engine(path)
        try:
            race = subprocess.run([helper, path, "--cancellation-race"], stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, timeout=8)
            require(race.returncode == 0, "I/O error during cancellation was not handled")
            require(engine.closed_session.wait(3), "I/O cancellation did not revoke its session")
            require(engine.secret.encode() not in race.stdout + race.stderr, "Cancellation race exposed a secret")
            normal_flow(helper, path, engine)
            for terminate in [False, True]:
                engine.held.clear()
                engine.disconnected.clear()
                engine.closed_session.clear()
                client = Client(helper, path)
                name = "prepare_password" if terminate else "list_accounts"
                arguments = {"domain": "hold.example"}
                if terminate:
                    arguments["username"] = "person"
                client.send("tools/call", {"name": name, "arguments": arguments}, 2)
                require(engine.held.wait(3), "EOF test did not reach engine")
                client.finish(engine.secret, terminate=terminate)
                require(engine.disconnected.wait(3), "Client close left an IPC connection open")
                require(engine.closed_session.wait(3), "Client close did not revoke leases")
            require(all(item["op"].startswith("mcp_") for item in engine.requests), "Helper requested a raw credential operation")
        finally:
            engine.close()
    print("MCP protocol, metadata-only responses, cancellation, EOF, and signal checks passed.")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Test failures report only fixed assertion labels, never captured responses.
        print("MCP checks failed: " + (str(error) if isinstance(error, RuntimeError) else type(error).__name__), file=sys.stderr)
        raise SystemExit(1) from None
    finally:
        for process in Client.processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()

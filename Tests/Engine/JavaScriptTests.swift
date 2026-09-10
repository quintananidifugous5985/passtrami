import Foundation
import JavaScriptCore

@MainActor
private final class ScriptFixture {
    var script: SessionScript!
    var posts: [[String: Any]] = []
    var failed = false

    init() throws {
        script = try SessionScript(directory: URL(fileURLWithPath: "Engine"), onPost: { [weak self] text in
            if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                self?.posts.append(object)
            }
        }, onFailure: { [weak self] in self?.failed = true })
    }

    func event(_ value: [String: Any]) { script.receive(value) }
    func command(_ op: String, pin: String? = nil) {
        var value = ["op": op]
        if let pin { value["pin"] = pin }
        event(["type": "command", "command": value])
    }
    func message(_ bridge: String, _ value: [String: Any]) throws {
        event(["type": "bridgeText", "connection": bridge,
               "text": String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)])
    }
    func state(_ bridge: String, _ state: String) throws {
        try message(bridge, ["type": "nativeState", "state": state])
    }
    func connect(_ bridge: String, token: String, state: String = "NotInSession") throws {
        event(["type": "bridgeOpen", "connection": bridge])
        try message(bridge, ["token": token])
        try self.state(bridge, state)
    }
    func request(_ id: String, op: String = "get", domain: String = "example.test", username: String = "person") throws {
        let text = String(decoding: try JSONSerialization.data(withJSONObject:
            ["op": op, "domain": domain, "username": username]), as: UTF8.self)
        event(["type": "request", "connection": id, "text": text])
    }
    func complete(_ operation: [String: Any], error: String? = nil) {
        var event: [String: Any] = ["type": "nativeResult", "id": operation["id"]!]
        if let error { event["error"] = ["code": "browser_start", "message": error] }
        self.event(event)
    }
    func take(_ op: String, connection: String? = nil) async throws -> [String: Any] {
        let end = ContinuousClock.now + .seconds(2)
        repeat {
            if let index = posts.firstIndex(where: { $0["op"] as? String == op && (connection == nil || $0["connection"] as? String == connection) }) {
                return posts.remove(at: index)
            }
            try engineExpect(!failed, "JavaScript threw an exception")
            try await Task.sleep(for: .milliseconds(2))
        } while ContinuousClock.now < end
        throw EngineFailure("test", "Missing JavaScript operation: \(op)")
    }
    func start() async throws -> String {
        event(["type": "ready"])
        let operation = try await take("startBrowser")
        complete(operation)
        return operation["token"] as! String
    }
    func sent(_ connection: String) async throws -> [String: Any] {
        let operation = try await take("send", connection: connection)
        return try JSONSerialization.jsonObject(with: Data((operation["text"] as! String).utf8)) as! [String: Any]
    }
    func response(_ connection: String) async throws -> [String: Any] {
        let operation = try await take("reply", connection: connection)
        return try JSONSerialization.jsonObject(with: Data((operation["text"] as! String).utf8)) as! [String: Any]
    }
    func status() async throws -> [String: Any] {
        try request("status", op: "status")
        return try await response("status")
    }
    func nativeReply(_ bridge: String, request: [String: Any], status: Int = 0) throws {
        try message(bridge, ["id": request["id"]!, "data": ["STATUS": status, "Entries": [
            ["USR": "person", "PWD": "fixture-only", "sites": ["example.test"]],
            ["USR": "person", "PWD": "Not Included", "sites": ["accounts.example.test"]]
        ]]])
    }
}

@MainActor
func runJavaScriptTests() async throws {
    let fixture = try ScriptFixture()
    var unitCount = 0
    var unitFailure: String?
    let test: @convention(block) (String, JSValue) -> Void = { name, function in
        fixture.script.context.exception = nil
        function.call(withArguments: [])
        if fixture.failed { unitFailure = name } else { unitCount += 1 }
    }
    fixture.script.context.setObject(test, forKeyedSubscript: "test" as NSString)
    fixture.script.context.setObject(try String(contentsOfFile: "Engine/bridge.js", encoding: .utf8),
                                     forKeyedSubscript: "__bridgeSource" as NSString)
    for name in ["credentials", "bridge"] {
        fixture.script.context.evaluateScript(try String(contentsOfFile: "Tests/Engine/\(name).js", encoding: .utf8))
        if let unitFailure { throw EngineFailure("test", unitFailure) }
        try engineExpect(!fixture.failed, "JavaScript unit fixture failed")
    }
    try engineExpect(unitCount == 14, "Some JavaScript unit tests did not run")

    // Native URL normalization is part of the credential trust boundary.
    for invalid in ["", "https://a:b@example.test", "https://a@example.test", "file:///example.test", "not a domain", "https://", "https://example.test%2fevil.test"] {
        try engineExpect(SessionScript.hostname(invalid) == nil, "Accepted an invalid website")
    }
    for (input, expected) in [("https://GOOGLE.com/path", "google.com"), ("google.com.", "google.com"),
                              ("https://example.test:443/login", "example.test"), ("https://bücher.example", "xn--bcher-kva.example")] {
        try engineExpect(SessionScript.hostname(input) == expected, "Website normalization changed")
    }

    // Settings can prepare or retry Chromium without starting a PIN challenge or a second setup.
    do {
        let f = try ScriptFixture()
        f.event(["type": "ready"])
        let first = try await f.take("startBrowser")
        f.command("prepareBrowser")
        f.command("prepareBrowser")
        try engineExpect(!f.posts.contains { $0["op"] as? String == "startBrowser" }, "Prepare duplicated the automatic browser setup")
        f.complete(first, error: "Fixture download failure")
        try engineExpect(try await f.status()["state"] as? String == "error", "Download failure did not finish setup")

        f.command("prepareBrowser")
        let retry = try await f.take("startBrowser")
        f.command("prepareBrowser")
        try engineExpect(!f.posts.contains { $0["op"] as? String == "startBrowser" }, "Prepare duplicated a retry")
        f.complete(retry)
        try f.connect("prepared", token: retry["token"] as! String)
        try engineExpect(try await f.status()["state"] as? String == "locked", "Prepare requested an unlock")
        f.command("prepareBrowser")
        try engineExpect(!f.posts.contains { $0["op"] as? String == "startBrowser" || $0["op"] as? String == "send" },
                         "Prepare restarted Chromium or sent a PIN challenge")
        try engineExpect(!f.posts.contains { ($0["event"] as? [String: Any])?["type"] as? String == "pinRequired" },
                         "Prepare opened the PIN window")
    }

    // Locked list waits for the PIN result and sends no password request.
    do {
        let f = try ScriptFixture(), token = try await f.start()
        try f.connect("bridge", token: token)
        try f.request("list", op: "list", domain: "https://EXAMPLE.test/path")
        try engineExpect(try await f.sent("bridge")["op"] as? String == "unlock", "List did not unlock")
        try f.state("bridge", "NotInSession")
        try engineExpect(try await f.status()["state"] as? String == "pairing", "Duplicate state cancelled pairing")
        try f.state("bridge", "MSG1Set")
        f.command("pin", pin: "12345")
        try engineExpect(!f.posts.contains { $0["op"] as? String == "send" }, "Accepted a short PIN")
        f.command("pin", pin: "123456")
        try engineExpect(try await f.sent("bridge")["op"] as? String == "pin", "PIN was not forwarded")
        try engineExpect(try await f.status()["state"] as? String == "pairing", "PIN submission unlocked before Apple replied")
        try f.state("bridge", "SessionKeySet")
        let request = try await f.sent("bridge")
        try engineExpect(request["cmd"] as? Int == 4, "List used a password command")
        try f.nativeReply("bridge", request: request)
        let response = try await f.response("list")
        try engineExpect(response["usernames"] as? [String] == ["person"] && response["password"] == nil, "List leaked a password or kept duplicates")
    }

    // Cancellation at queue, unlock, and native-request stages must be isolated.
    for op in ["get", "list"] {
        let f = try ScriptFixture(), token = try await f.start()
        try f.connect("bridge", token: token, state: "SessionKeySet")
        try f.request("first", op: op)
        let first = try await f.sent("bridge")
        try f.request("cancelled", op: op)
        f.event(["type": "clientClosed", "connection": "cancelled"])
        try f.request("next", op: op)
        try f.nativeReply("bridge", request: first)
        _ = try await f.response("first")
        let next = try await f.sent("bridge")
        try f.nativeReply("bridge", request: next)
        _ = try await f.response("next")
        try engineExpect(!f.posts.contains { $0["op"] as? String == "reply" && $0["connection"] as? String == "cancelled" }, "Cancelled client got a reply")

        try f.request("inflight", op: op)
        let stale = try await f.sent("bridge")
        try f.request("after", op: op)
        f.event(["type": "clientClosed", "connection": "inflight"])
        let stop = try await f.take("stopBrowser")
        try engineExpect(!f.posts.contains { $0["op"] as? String == "startBrowser" }, "New browser started before old browser stopped")
        f.complete(stop)
        let start = try await f.take("startBrowser")
        try engineExpect(start["token"] as? String != token, "New session reused token")
        f.complete(start)
        try f.nativeReply("bridge", request: stale)
        try f.connect("new", token: start["token"] as! String, state: "SessionKeySet")
        let after = try await f.sent("new")
        try f.nativeReply("new", request: after)
        _ = try await f.response("after")
    }

    do {
        let f = try ScriptFixture(), token = try await f.start()
        try f.connect("bridge", token: token)
        try f.request("waiting")
        _ = try await f.sent("bridge")
        f.event(["type": "clientClosed", "connection": "waiting"])
        f.complete(try await f.take("stopBrowser"))
        try engineExpect(try await f.status()["state"] as? String == "locked", "Cancelled unlock left pairing active")
        try f.connect("old", token: token, state: "SessionKeySet")
        _ = try await f.take("disconnect", connection: "old")
        try engineExpect(try await f.status()["state"] as? String == "locked", "Accepted old token after lock")
    }

    // Timeouts and native locks end the old session before retrying.
    for cause in ["timeout", "locked", "relogin", "bridgeClosed", "browserExited"] {
        let f = try ScriptFixture(), token = try await f.start()
        try f.connect("bridge", token: token, state: "SessionKeySet")
        try f.request("request")
        let request = try await f.sent("bridge")
        if cause == "timeout" {
            let timer = f.posts.first { $0["op"] as? String == "timer" && $0["milliseconds"] as? Int == 120000 }!
            f.event(["type": "timer", "id": timer["id"]!])
        } else if cause == "locked" { try f.nativeReply("bridge", request: request, status: 9) }
        else if cause == "relogin" {
            try f.state("bridge", "CheckEngine")
            try f.state("bridge", "NotInSession")
        }
        else if cause == "bridgeClosed" { f.event(["type": cause, "connection": "bridge"]) }
        else { f.event(["type": cause, "token": token]) }
        f.complete(try await f.take("stopBrowser"))
        if cause == "timeout" {
            try engineExpect(try await f.response("request")["code"] as? String == "timeout", "Timeout was not returned")
        } else {
            let start = try await f.take("startBrowser")
            f.complete(start)
            try f.connect("new", token: start["token"] as! String, state: "SessionKeySet")
            let retry = try await f.sent("new")
            try f.nativeReply("new", request: retry)
            try engineExpect(try await f.response("request")["password"] as? String == "fixture-only", "Retry failed")
        }
    }

    // A failed native helper must release the browser before Unlock or a CLI request retries.
    for op in ["unlock", "get", "list"] {
        let f = try ScriptFixture(), token = try await f.start()
        try f.connect("old", token: token, state: "SessionKeySet")
        try f.state("old", "NativeSupportNotInstalled")
        try engineExpect(try await f.status()["state"] as? String == "error", "Native helper failure did not reach the UI state")
        let stop = try await f.take("stopBrowser")
        if op == "unlock" { f.command("unlock") }
        else { try f.request("retry", op: op) }
        try engineExpect(!f.posts.contains { $0["op"] as? String == "startBrowser" }, "Recovery started before the old browser stopped")
        f.complete(stop)
        let start = try await f.take("startBrowser")
        try engineExpect(start["token"] as? String != token, "Helper recovery reused the failed session")
        f.complete(start)
        try f.state("old", "SessionKeySet")
        try engineExpect(try await f.status()["state"] as? String != "unlocked", "The failed helper restored an old session")
        try f.connect("new", token: start["token"] as! String)
        try engineExpect(try await f.sent("new")["op"] as? String == "unlock", "Helper recovery did not request pairing")
        try f.state("new", "MSG1Set")
        try engineExpect(f.posts.contains {
            $0["op"] as? String == "emit" && ($0["event"] as? [String: Any])?["type"] as? String == "pinRequired"
        }, "Helper recovery did not request the PIN window")
        try f.state("new", "SessionKeySet")
        if op != "unlock" {
            try f.nativeReply("new", request: await f.sent("new"))
            try engineExpect(try await f.response("retry")["ok"] as? Bool == true, "CLI request did not resume after helper recovery")
        }
        try engineExpect(try await f.status()["state"] as? String == "unlocked", "Helper recovery did not update the UI state")
    }

    // The final invalid-session reply must clear both CLI status and the menu state.
    for op in ["get", "list"] {
        let f = try ScriptFixture(), token = try await f.start()
        try f.connect("old", token: token, state: "SessionKeySet")
        try f.request("request", op: op)
        try f.nativeReply("old", request: await f.sent("old"), status: 9)
        f.complete(try await f.take("stopBrowser"))
        let start = try await f.take("startBrowser")
        f.complete(start)
        try f.connect("new", token: start["token"] as! String, state: "SessionKeySet")
        try f.nativeReply("new", request: await f.sent("new"), status: 9)
        f.complete(try await f.take("stopBrowser"))
        try engineExpect(try await f.response("request")["code"] as? String == "locked", "The final lock error was not returned")
        try engineExpect(try await f.status()["state"] as? String == "locked", "The final lock error left CLI status unlocked")
        let lastState = f.posts.compactMap { $0["event"] as? [String: Any] }.last { $0["type"] as? String == "state" }
        try engineExpect(lastState?["state"] as? String == "locked", "The final lock error left the menu state unlocked")
        try engineExpect(!f.posts.contains { $0["op"] as? String == "startBrowser" }, "Retried beyond the request limit")
    }

    // A failed startup must invalidate an already-connected extension.
    do {
        let f = try ScriptFixture()
        f.event(["type": "ready"])
        let first = try await f.take("startBrowser")
        try f.connect("old", token: first["token"] as! String)
        f.complete(first, error: "Fixture startup error")
        try engineExpect(try await f.status()["message"] as? String == "Fixture startup error", "Lost startup error details")
        f.command("unlock")
        _ = try await f.take("startBrowser")
        try f.state("old", "SessionKeySet")
        try engineExpect(try await f.status()["state"] as? String != "unlocked", "Stale bridge unlocked new generation")
        f.event(["type": "bridgeOpen", "connection": "invalid"])
        f.event(["type": "bridgeText", "connection": "invalid", "text": "null"])
        _ = try await f.take("disconnect", connection: "invalid")
        try engineExpect(!f.failed, "Malformed bridge message escaped into JSC")
    }

    // Stop a launch in progress and ignore its late success.
    do {
        let f = try ScriptFixture()
        f.event(["type": "ready"])
        let start = try await f.take("startBrowser")
        f.command("lock")
        let stop = try await f.take("stopBrowser")
        f.complete(start)
        f.complete(stop)
        try f.connect("late", token: start["token"] as! String, state: "SessionKeySet")
        _ = try await f.take("disconnect", connection: "late")
        try engineExpect(try await f.status()["state"] as? String == "locked", "Cancelled launch changed state")
        f.command("shutdown")
        f.complete(try await f.take("stopBrowser"))
        _ = try await f.take("shutdown")
    }
    print("JavaScriptCore: 14 credential/bridge tests and session lifecycle checks passed")
}

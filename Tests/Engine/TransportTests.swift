import Darwin
import Foundation

@MainActor
private func runEngineInstanceLockTests() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("passtrami-owner-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("engine.lock").path

    var first: EngineInstanceLock? = try EngineInstanceLock(directory: directory)
    var info = stat()
    try engineExpect(lstat(path, &info) == 0 && info.st_mode & 0o777 == 0o600,
                     "The engine lock must have owner-only permissions.")
    let inode = info.st_ino
    try withExtendedLifetime(first) {
        do {
            _ = try EngineInstanceLock(directory: directory)
            throw EngineFailure("test", "Two engine owners acquired the same directory.")
        } catch let error as EngineFailure {
            try engineExpect(error.code == "already_running", "Engine contention did not report an existing owner.")
        }
    }
    first = nil
    let next = try EngineInstanceLock(directory: directory)
    try withExtendedLifetime(next) {
        try engineExpect(lstat(path, &info) == 0 && info.st_ino == inode,
                         "Releasing the engine lock must not replace its inode.")
        do {
            _ = try EngineInstanceLock(directory: directory)
            throw EngineFailure("test", "A replacement owner did not retain its lock.")
        } catch let error as EngineFailure {
            try engineExpect(error.code == "already_running", "The replacement engine did not own the directory.")
        }
    }

    do {
        _ = try EngineInstanceLock(directory: directory.appendingPathComponent("missing"))
        throw EngineFailure("test", "An invalid lock directory was accepted.")
    } catch let error as EngineFailure {
        try engineExpect(error.code == "engine_lock", "Invalid lock path did not fail safely.")
    }
}

@MainActor
private func transportWait(_ message: String, until condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        if ContinuousClock.now >= deadline { throw EngineFailure("test", message) }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
private final class TransportTestClient {
    private(set) var descriptor: Int32 = -1

    init(path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw EngineFailure("test", "Test socket path is too long.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw EngineFailure("test", "Test socket creation failed.") }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        var noSignal: Int32 = 1
        guard result == 0, fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            close()
            throw EngineFailure("test", "Test socket connection failed.")
        }
    }

    init(port: UInt16) throws {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw EngineFailure("test", "Test TCP socket creation failed.") }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var noSignal: Int32 = 1
        guard result == 0, fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            close()
            throw EngineFailure("test", "Test TCP socket connection failed.")
        }
    }

    func write(_ data: Data) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if count > 0 { offset += count; continue }
            if count < 0, errno == EINTR { continue }
            guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK, ContinuousClock.now < deadline else {
                throw EngineFailure("test", "Test socket write failed.")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func response() async throws -> Data {
        let deadline = ContinuousClock.now + .seconds(5)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return data }
            if count > 0 { data.append(contentsOf: buffer.prefix(count)); continue }
            if errno == EINTR { continue }
            if errno == ECONNRESET { return data }
            guard errno == EAGAIN || errno == EWOULDBLOCK, ContinuousClock.now < deadline else {
                throw EngineFailure("test", "Test socket response failed.")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func close() {
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
    }
}

@MainActor
private func runUnixTransportTests() async throws {
    let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("passtrami-transport-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("cli.sock").path
    var requests: [(String, String)] = []
    var disconnected: [String] = []
    let listener = try CLIListener(path: path, onRequest: { requests.append(($0, $1)) },
                                   onDisconnect: { disconnected.append($0) })
    defer { listener.close() }
    var socketInfo = stat()
    try engineExpect(lstat(path, &socketInfo) == 0 && socketInfo.st_mode & 0o777 == 0o600,
                     "CLI socket permissions are not 0600.")

    let split = try TransportTestClient(path: path)
    defer { split.close() }
    try await split.write(Data("{\"op\":".utf8))
    await Task.yield()
    try engineExpect(requests.isEmpty, "A partial request was delivered.")
    try await split.write(Data("\"status\"}\n".utf8))
    try await transportWait("The complete request was not delivered.") { requests.count == 1 }
    try engineExpect(requests[0].1 == "{\"op\":\"status\"}", "Request bytes changed.")
    listener.reply(id: requests[0].0, json: "{\"ok\":true}")
    let firstResponse = try await split.response()
    try engineExpect(firstResponse == Data("{\"ok\":true}\n".utf8), "Reply framing changed.")
    try engineExpect(disconnected.isEmpty, "A completed reply was reported as cancellation.")

    let cancelled = try TransportTestClient(path: path)
    defer { cancelled.close() }
    try await cancelled.write(Data("{\"op\":\"get\"}\n".utf8))
    try await transportWait("The pending request was not delivered.") { requests.count == 2 }
    let cancelledID = requests[1].0
    cancelled.close()
    try await transportWait("Client EOF did not cancel the pending request.") { disconnected == [cancelledID] }
    listener.reply(id: cancelledID, json: "{\"ok\":true}")

    // The main queue cannot accept these connections until the next suspension.
    for _ in 0..<16 {
        let queued = try TransportTestClient(path: path)
        queued.close()
    }
    let afterQueue = try TransportTestClient(path: path)
    defer { afterQueue.close() }
    try await afterQueue.write(Data("{\"op\":\"status\"}\n".utf8))
    try await transportWait("Closed queued clients stopped the listener.") { requests.count == 3 }
    listener.reply(id: requests[2].0, json: "{\"ok\":true}")
    let queuedResponse = try await afterQueue.response()
    try engineExpect(queuedResponse == firstResponse, "The listener failed after queued cancellation.")

    for invalid in [Data(repeating: 0x61, count: 65_537), Data([0xff, 0x0a]), Data("{}\n{}\n".utf8)] {
        let client = try TransportTestClient(path: path)
        defer { client.close() }
        try await client.write(invalid)
        let response = try await client.response()
        try engineExpect(response.isEmpty && requests.count == 3, "An invalid request reached the engine.")
    }

    let large = try TransportTestClient(path: path)
    defer { large.close() }
    try await large.write(Data("{}\n".utf8))
    try await transportWait("The large-reply request was not delivered.") { requests.count == 4 }
    let payload = "{\"value\":\"" + String(repeating: "x", count: 2_097_152) + "\"}"
    listener.reply(id: requests[3].0, json: payload)
    let largeResponse = try await large.response()
    try engineExpect(largeResponse == Data((payload + "\n").utf8), "Partial writes truncated the reply.")

    let cancelledWrite = try TransportTestClient(path: path)
    defer { cancelledWrite.close() }
    try await cancelledWrite.write(Data("{}\n".utf8))
    try await transportWait("The write-cancellation request was not delivered.") { requests.count == 5 }
    listener.reply(id: requests[4].0, json: payload)
    cancelledWrite.close()

    let final = try TransportTestClient(path: path)
    defer { final.close() }
    try await final.write(Data("{}\n".utf8))
    try await transportWait("A cancelled write stopped the listener.") { requests.count == 6 }
    let finalID = requests[5].0
    listener.disconnect(id: finalID)
    listener.disconnect(id: finalID)
    try engineExpect(disconnected == [cancelledID, finalID], "Explicit client disconnect did not cancel once.")
    _ = try await final.response()

    let shutdown = try TransportTestClient(path: path)
    defer { shutdown.close() }
    try await shutdown.write(Data("{}\n".utf8))
    try await transportWait("The shutdown request was not delivered.") { requests.count == 7 }
    listener.close()
    try engineExpect(disconnected == [cancelledID, finalID, requests[6].0], "Listener close did not cancel pending work once.")
    try engineExpect(!FileManager.default.fileExists(atPath: path), "The socket file remained after close.")
    _ = try await shutdown.response()
}

private func transportWebSocketMessage(_ task: URLSessionWebSocketTask) async throws -> URLSessionWebSocketTask.Message {
    try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
        group.addTask { try await task.receive() }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            task.cancel(with: .goingAway, reason: nil)
            throw EngineFailure("test", "The WebSocket response timed out.")
        }
        defer { group.cancelAll() }
        guard let message = try await group.next() else { throw EngineFailure("test", "No WebSocket response.") }
        return message
    }
}

@MainActor
private func runWebSocketTransportTests() async throws {
    var opened: [String] = []
    var messages: [(String, String)] = []
    var closed: [String] = []
    let listener = BridgeListener(onOpen: { opened.append($0) }, onText: { messages.append(($0, $1)) },
                                  onClose: { closed.append($0) })
    defer { listener.close() }
    let port = try await listener.start()
    try engineExpect(port != 0, "The WebSocket listener has no port.")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 5
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let url = URL(string: "ws://127.0.0.1:\(port)/")!
    let client = session.webSocketTask(with: url)
    client.resume()
    defer { client.cancel(with: .goingAway, reason: nil) }
    try await client.send(.string("hello"))
    try await transportWait("The WebSocket did not deliver a text message.") { opened.count == 1 && messages.count == 1 }
    try engineExpect(messages[0].0 == opened[0] && messages[0].1 == "hello", "WebSocket identity or text changed.")
    listener.send(id: opened[0], text: "reply")
    guard case .string("reply") = try await transportWebSocketMessage(client) else {
        throw EngineFailure("test", "The WebSocket reply was not text.")
    }
    let maximum = String(repeating: "x", count: 1_048_576)
    try await client.send(.string(maximum))
    try await transportWait("A maximum-size text message was rejected.") { messages.count == 2 }
    try engineExpect(messages[1].1 == maximum, "The maximum-size message was truncated.")
    try? await client.send(.string(maximum + "x"))
    try await transportWait("An oversized WebSocket message did not close the connection.") { closed == [opened[0]] }
    try engineExpect(messages.count == 2, "An oversized message reached the engine.")

    let binary = session.webSocketTask(with: url)
    binary.resume()
    defer { binary.cancel(with: .goingAway, reason: nil) }
    try await binary.send(.data(Data([1, 2, 3])))
    try await transportWait("A binary WebSocket message did not close the connection.") { opened.count == 2 && closed.count == 2 }
    try engineExpect(messages.count == 2, "A binary message reached the engine.")

    let cancelled = session.webSocketTask(with: url)
    cancelled.resume()
    defer { cancelled.cancel(with: .goingAway, reason: nil) }
    try await cancelled.send(.string("cancel"))
    try await transportWait("The cancellation connection did not open.") { opened.count == 3 && messages.count == 3 }
    cancelled.cancel(with: .goingAway, reason: nil)
    try await transportWait("Client WebSocket close was not reported.") { closed.count == 3 }

    let final = session.webSocketTask(with: url)
    final.resume()
    defer { final.cancel(with: .goingAway, reason: nil) }
    try await final.send(.string("final"))
    try await transportWait("The final WebSocket connection did not open.") { opened.count == 4 && messages.count == 4 }
    listener.close()
    try engineExpect(Set(closed) == Set(opened) && closed.count == opened.count, "WebSocket close events were missing or repeated.")
    listener.close()
    listener.disconnect(id: opened[0])
    listener.send(id: opened[0], text: "ignored")
    try engineExpect(closed.count == 4, "An already closed WebSocket produced another close event.")
}

@MainActor
private final class BridgeAuthenticationFixture {
    private(set) var listener: BridgeListener!
    private var script: SessionScript!
    private(set) var token: String?
    private(set) var opened: [String] = []
    private(set) var closed: [String] = []
    private(set) var authenticated: [String] = []
    private(set) var failed = false

    init(timeout: Duration, limit: Int) throws {
        listener = BridgeListener(connectionLimit: limit, authenticationTimeout: timeout,
            onOpen: { [weak self] id in
                self?.opened.append(id)
                self?.script.receive(["type": "bridgeOpen", "connection": id])
            }, onText: { [weak self] id, text in
                self?.script.receive(["type": "bridgeText", "connection": id, "text": text])
            }, onClose: { [weak self] id in
                self?.closed.append(id)
                self?.script.receive(["type": "bridgeClosed", "connection": id])
            })
        script = try SessionScript(directory: URL(fileURLWithPath: "Engine"),
            onPost: { [weak self] in self?.post($0) }, onFailure: { [weak self] in self?.failed = true })
        script.receive(["type": "ready"])
    }

    private func post(_ text: String) {
        guard let message = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let operation = message["op"] as? String else { failed = true; return }
        switch operation {
        case "startBrowser", "stopBrowser":
            // Complete lifecycle I/O without starting Chromium or Apple's helper.
            if operation == "startBrowser" { token = message["token"] as? String }
            let id = message["id"] as! String
            Task { [weak self] in self?.script.receive(["type": "nativeResult", "id": id]) }
        case "bridgeAuthenticated":
            let id = message["connection"] as! String
            authenticated.append(id)
            listener.authenticated(id: id)
        case "disconnect": listener.disconnect(id: message["connection"] as! String)
        default: break
        }
    }
}

@MainActor
private func runBridgeAuthenticationTransportTests() async throws {
    let timeout: Duration = .seconds(1)
    do {
        let delayed = try BridgeAuthenticationFixture(timeout: timeout, limit: 1)
        defer { delayed.listener.close() }
        let port = try await delayed.listener.start()
        let client = try TransportTestClient(port: port)
        defer { client.close() }
        let started = ContinuousClock.now
        try await client.write(Data("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n".utf8))
        try await Task.sleep(for: .milliseconds(650))
        try await client.write(Data(("Upgrade: websocket\r\nConnection: Upgrade\r\n" +
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n").utf8))
        let response = try await client.response()
        try engineExpect(String(decoding: response, as: UTF8.self).contains("101"),
                         "The delayed WebSocket handshake did not complete.")
        try engineExpect(ContinuousClock.now - started < .milliseconds(1_400),
                         "The WebSocket upgrade restarted the accept-to-authenticate deadline.")
        try await transportWait("The upgraded connection did not close once at its original deadline.") {
            delayed.opened.count == 1 && delayed.closed == delayed.opened
        }
    }
    let fixture = try BridgeAuthenticationFixture(timeout: timeout, limit: 2)
    defer { fixture.listener.close() }
    let port = try await fixture.listener.start()

    // No bytes and an incomplete HTTP upgrade both time out before onOpen.
    let idle = try TransportTestClient(port: port)
    defer { idle.close() }
    let partial = try TransportTestClient(port: port)
    defer { partial.close() }
    try await partial.write(Data("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n".utf8))
    try engineExpect(try await idle.response().isEmpty, "Idle TCP was not closed without application data.")
    try engineExpect(try await partial.response().isEmpty, "An incomplete WebSocket upgrade was not closed.")
    try engineExpect(fixture.opened.isEmpty && fixture.closed.isEmpty,
                     "An incomplete upgrade emitted an application open or close event.")

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 5
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let url = URL(string: "ws://127.0.0.1:\(port)/")!

    // Upgrading does not extend the deadline or free an unauthenticated slot.
    let first = session.webSocketTask(with: url), second = session.webSocketTask(with: url)
    first.resume(); second.resume()
    defer { first.cancel(with: .goingAway, reason: nil); second.cancel(with: .goingAway, reason: nil) }
    try await transportWait("Unauthenticated WebSocket clients did not open.") { fixture.opened.count == 2 }
    let overflow = try TransportTestClient(port: port)
    defer { overflow.close() }
    let overflowStart = ContinuousClock.now
    try engineExpect(try await overflow.response().isEmpty, "A connection above the limit was not rejected.")
    try engineExpect(ContinuousClock.now - overflowStart < .milliseconds(500),
                     "The connection limit waited for the authentication deadline.")
    try await transportWait("Upgraded clients without a token survived the deadline.") { fixture.closed.count == 2 }
    try engineExpect(fixture.authenticated.isEmpty, "An upgrade alone authenticated a client.")

    let invalid = session.webSocketTask(with: url)
    invalid.resume()
    defer { invalid.cancel(with: .goingAway, reason: nil) }
    try await invalid.send(.string("{\"token\":\"invalid-fixture-token\"}"))
    try await transportWait("An invalid token was not rejected.") { fixture.closed.count == 3 }
    try engineExpect(fixture.authenticated.isEmpty, "An invalid token authenticated a client.")

    let valid = session.webSocketTask(with: url)
    valid.resume()
    defer { valid.cancel(with: .goingAway, reason: nil) }
    let token = try JSONSerialization.data(withJSONObject: ["token": fixture.token!])
    try await valid.send(.string(String(decoding: token, as: UTF8.self)))
    try await transportWait("A valid token did not authenticate after expired clients released their slots.") {
        fixture.authenticated.count == 1
    }
    let validID = fixture.authenticated[0]
    try await Task.sleep(for: timeout + .milliseconds(100))
    fixture.listener.send(id: validID, text: "still connected")
    guard case .string("still connected") = try await transportWebSocketMessage(valid) else {
        throw EngineFailure("test", "An authenticated bridge did not remain connected.")
    }
    try engineExpect(!fixture.closed.contains(validID) && !fixture.failed,
                     "Authentication did not cancel the deadline or caused a JavaScript failure.")

    fixture.listener.close()
    fixture.listener.authenticated(id: validID)
    fixture.listener.disconnect(id: validID)
    try engineExpect(fixture.closed.count == 4 && Set(fixture.closed).count == 4,
                     "Timeout, authentication, and close callbacks were missing or repeated.")
    print("Bridge accept-to-authenticate deadline and connection limit checks passed.")
}

@MainActor
func runTransportTests() async throws {
    try runEngineInstanceLockTests()
    try await runUnixTransportTests()
    try await runWebSocketTransportTests()
    try await runBridgeAuthenticationTransportTests()
    print("Native engine ownership, CLI, and WebSocket transport checks passed.")
}

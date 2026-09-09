import Darwin
import Foundation

@MainActor
// Owns native I/O. SessionScript decides when to unlock, send requests, or stop.
final class JavaScriptEngine {
    private let resources: URL
    private let dataDirectory: URL
    private var script: SessionScript?
    private var cli: CLIListener?
    private var mcp: MCPBroker?
    private var bridge: BridgeListener?
    private var port: UInt16 = 0
    private var browser: BrowserSession?
    private var startup: Task<Void, Never>?
    private var timers: [String: Task<Void, Never>] = [:]
    private var signals: [DispatchSourceSignal] = []
    private var input = Data()
    private var stopping = false

    init(resources: URL, dataDirectory: URL) {
        self.resources = resources
        self.dataDirectory = dataDirectory
    }

    func start() async throws {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dataDirectory.path)
        let pipes = try PasswordPipes(directory: dataDirectory.appendingPathComponent("password-pipes"))
        mcp = MCPBroker(pipes: pipes, forward: { [weak self] id, text in
            self?.deliver(["type": "request", "connection": id, "text": text])
        }, reply: { [weak self] id, text in
            self?.cli?.reply(id: id, json: text)
        }, cancel: { [weak self] id in
            self?.deliver(["type": "clientClosed", "connection": id])
        })
        script = try SessionScript(directory: resources.appendingPathComponent("Engine"), onPost: { [weak self] in
            self?.handle($0)
        }, onFailure: { [weak self] in
            self?.emit(["type": "state", "state": "error", "message": "The password service failed. Select Unlock to try again."])
            Task { await self?.shutdown(exitCode: 1) }
        })
        let listener = BridgeListener(onOpen: { [weak self] id in
            self?.deliver(["type": "bridgeOpen", "connection": id])
        }, onText: { [weak self] id, text in
            self?.deliver(["type": "bridgeText", "connection": id, "text": text])
        }, onClose: { [weak self] id in
            self?.deliver(["type": "bridgeClosed", "connection": id])
        })
        bridge = listener
        port = try await listener.start()
        cli = try CLIListener(path: dataDirectory.appendingPathComponent("aster.sock").path, onRequest: { [weak self] id, text in
            if self?.mcp?.receive(id, text: text) == true { return }
            self?.deliver(["type": "request", "connection": id, "text": text])
        }, onDisconnect: { [weak self] id in
            self?.mcp?.disconnected(id)
            self?.deliver(["type": "clientClosed", "connection": id])
        }, onFinish: { [weak self] id, delivered in
            self?.mcp?.responseFinished(id, delivered: delivered)
        })
        FileHandle.standardInput.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { self?.readInput(data) }
        }
        signal(SIGPIPE, SIG_IGN)
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.command(["op": "shutdown"]) }
            }
            signals.append(source)
            source.resume()
        }
        deliver(["type": "ready"])
    }

    private func deliver(_ event: [String: Any]) {
        guard !stopping else { return }
        script?.receive(event)
    }

    private func handle(_ text: String) {
        guard !stopping, let data = text.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let operation = message["op"] as? String else { return }
        let id = message["id"] as? String ?? ""
        let connection = message["connection"] as? String ?? ""
        switch operation {
        case "emit":
            if let event = message["event"] as? [String: Any] { emit(event) }
        case "timer":
            guard let milliseconds = message["milliseconds"] as? Int, milliseconds >= 0 else { return }
            timers[id] = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(milliseconds)) } catch { return }
                self?.timers.removeValue(forKey: id)
                self?.deliver(["type": "timer", "id": id])
            }
        case "cancelTimer": timers.removeValue(forKey: id)?.cancel()
        case "send":
            if let text = message["text"] as? String { bridge?.send(id: connection, text: text) }
        case "disconnect": bridge?.disconnect(id: connection)
        case "reply":
            if let text = message["text"] as? String {
                if connection.hasPrefix("mcp:") {
                    mcp?.receiveReply(String(connection.dropFirst(4)), text: text)
                } else { cli?.reply(id: connection, json: text) }
            }
        case "closeClient":
            if connection.hasPrefix("mcp:") {
                let id = String(connection.dropFirst(4))
                mcp?.disconnected(id)
                cli?.disconnect(id: id)
            } else { cli?.disconnect(id: connection) }
        case "startBrowser":
            guard let token = message["token"] as? String else { return }
            startup = Task { [weak self] in
                guard let self else { return }
                do {
                    let executable = try await BrowserRuntime.resolve(dataDirectory: dataDirectory) { [weak self] message in
                        self?.deliver(["type": "progress", "token": token, "message": message])
                    }
                    let session = try await BrowserSession.start(executable: executable, resources: resources,
                        dataDirectory: dataDirectory, port: port, token: token) { [weak self] in
                            self?.deliver(["type": "browserExited", "token": token])
                        }
                    if Task.isCancelled { await session.stop(); throw CancellationError() }
                    browser = session
                    complete(id)
                } catch {
                    let failure = error as? EngineFailure ?? EngineFailure("browser_start", "Could not start the password browser.")
                    complete(id, error: failure)
                }
            }
        case "stopBrowser":
            mcp?.revokePipes()
            Task { [weak self] in
                guard let self else { return }
                await stopBrowser()
                complete(id)
            }
        case "shutdown": Task { await shutdown(exitCode: 0) }
        default: break
        }
    }

    private func complete(_ id: String, error: EngineFailure? = nil) {
        var event: [String: Any] = ["type": "nativeResult", "id": id]
        if let error { event["error"] = ["code": error.code, "message": error.message] }
        deliver(event)
    }

    private func readInput(_ data: Data) {
        guard !stopping else { return }
        if data.isEmpty {
            command(["op": "shutdown"])
            return
        }
        input.append(data)
        guard input.count <= 1_048_576 else {
            Task { await shutdown(exitCode: 1) }
            return
        }
        while let newline = input.firstIndex(of: 0x0A) {
            let line = Data(input[..<newline])
            input.removeSubrange(...newline)
            guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  value["op"] is String else { continue }
            command(value)
        }
    }

    private func command(_ value: [String: Any]) {
        if value["op"] as? String == "mcp" {
            if let enabled = value["enabled"] as? Bool { mcp?.setEnabled(enabled) }
            return
        }
        if ["lock", "shutdown"].contains(value["op"] as? String ?? "") { mcp?.invalidate() }
        deliver(["type": "command", "command": value])
    }

    private func emit(_ event: [String: Any]) {
        if event["type"] as? String == "state", let state = event["state"] as? String { mcp?.setState(state) }
        guard var data = try? JSONSerialization.data(withJSONObject: event) else { return }
        data.append(0x0A)
        try? FileHandle.standardOutput.write(contentsOf: data)
    }

    private func stopBrowser() async {
        let pending = startup
        pending?.cancel()
        await pending?.value
        startup = nil
        let current = browser
        browser = nil
        await current?.stop()
    }

    private func shutdown(exitCode: Int32) async {
        guard !stopping else { return }
        mcp?.invalidate()
        stopping = true
        FileHandle.standardInput.readabilityHandler = nil
        for task in timers.values { task.cancel() }
        timers.removeAll()
        await stopBrowser()
        cli?.close()
        bridge?.close()
        for source in signals { source.cancel() }
        exit(exitCode)
    }
}

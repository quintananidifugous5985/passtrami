import Darwin
import Foundation
import Network

@MainActor
private func runtimeExpect(_ condition: Bool, _ message: String) throws {
    if !condition { throw EngineFailure("test", message) }
}

@MainActor
private func runtimeFailure(_ code: String, _ operation: () async throws -> Void) async throws {
    do { try await operation() }
    catch let failure as EngineFailure {
        try runtimeExpect(failure.code == code, "Unexpected runtime error code: \(failure.code)")
        return
    }
    throw EngineFailure("test", "Expected runtime error \(code)")
}

@MainActor
private func runtimeUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw EngineFailure("test", "Runtime fixture timed out.")
}

@MainActor
private final class RuntimeHTTPFixture {
    private let listener: NWListener
    private var clients: [NWConnection] = []
    private var startup: CheckedContinuation<URL, any Error>?

    init(status: Int = 200, body: String = "abc", hold: Bool = false) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                if case .ready = state, let port = self.listener.port {
                    self.startup?.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/archive")!)
                    self.startup = nil
                } else if case .failed = state {
                    self.startup?.resume(throwing: EngineFailure("test", "HTTP fixture did not start."))
                    self.startup = nil
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                self?.clients.append(connection)
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { _, _, _, _ in
                    let length = hold ? 1_000_000 : body.utf8.count
                    let response = "HTTP/1.1 \(status) Test\r\nContent-Type: application/octet-stream\r\nContent-Length: \(length)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: Data(response.utf8), contentContext: hold ? .defaultMessage : .finalMessage,
                                    isComplete: true, completion: .contentProcessed { _ in })
                }
            }
        }
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation {
            startup = $0
            listener.start(queue: .main)
        }
    }

    func stop() {
        listener.cancel()
        for client in clients { client.cancel() }
        clients.removeAll()
    }
}

@MainActor
private func runtimeDownloadTest(status: Int = 200, body: String = "abc", hold: Bool = false,
                                 _ test: (URL, URL) async throws -> Void) async throws {
    let directory = try BrowserRuntime.makePrivateDirectory(in: FileManager.default.temporaryDirectory, prefix: "passtrami-runtime-test-")
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = try RuntimeHTTPFixture(status: status, body: body, hold: hold)
    defer { server.stop() }
    try await test(server.start(), directory.appendingPathComponent("browser.dmg"))
}

@MainActor
private final class RuntimeBrowserState {
    var server: BridgeListener?
    var commands: [[String: Any]] = []
}

@MainActor
private final class RuntimeDownloadTask {
    var task: Task<Void, any Error>?
}

@MainActor
private func runtimeBrowserTest(mode: String) async throws {
    let manager = FileManager.default
    let root = try BrowserRuntime.makePrivateDirectory(in: manager.temporaryDirectory, prefix: "passtrami-browser-test-")
    defer { try? manager.removeItem(at: root) }
    let data = root.appendingPathComponent("data")
    let resources = root.appendingPathComponent("resources")
    for directory in [data, resources.appendingPathComponent("AppleExtension"), resources.appendingPathComponent("Engine")] {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try Data("// Fixture extension\n".utf8).write(to: resources.appendingPathComponent("AppleExtension/background.js"))
    try Data("// Fixture bridge\n".utf8).write(to: resources.appendingPathComponent("Engine/bridge.js"))
    let state = RuntimeBrowserState()
    let server = BridgeListener(onOpen: { _ in }, onText: { id, text in
        if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            state.commands.append(object)
            if mode == "ready" { state.server?.send(id: id, text: "{\"id\":1,\"result\":{}}") }
        }
    }, onClose: { _ in })
    state.server = server
    defer { server.close(); state.server = nil }
    let port = try await server.start()
    let quote = { (value: String) in "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    let pidFile = root.appendingPathComponent("pid")
    let executable = root.appendingPathComponent("browser")
    let endpoint = mode == "wait-ready" ? "" : "printf '\(port)\\n/devtools/browser/fixture\\n' > \"$profile/DevToolsActivePort\"\n"
    let script = """
    #!/bin/sh
    for argument in "$@"; do
      case "$argument" in --user-data-dir=*) profile=${argument#--user-data-dir=};; esac
    done
    printf '%s' "$$" > \(quote(pidFile.path))
    \(endpoint)exec /bin/sleep 30
    """
    try Data(script.utf8).write(to: executable)
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    var exits = 0
    let startup = Task {
        try await BrowserSession.start(executable: executable, resources: resources, dataDirectory: data,
                                       port: 1, token: "fixture-token", onExit: { exits += 1 })
    }
    var browser: BrowserSession?
    do {
        try await runtimeUntil { manager.fileExists(atPath: pidFile.path) }
        let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
        if mode == "ready" {
            browser = try await startup.value
            try runtimeExpect(state.commands.count == 1 && state.commands[0]["method"] as? String == "Extensions.loadUnpacked",
                              "Browser did not send the CDP load command.")
            let sessions = try manager.contentsOfDirectory(at: data, includingPropertiesForKeys: nil)
            try runtimeExpect(sessions.count == 1, "Browser created extra sessions.")
            let preferences = try JSONSerialization.jsonObject(with: Data(contentsOf: sessions[0].appendingPathComponent("profile/Default/Preferences"))) as! [String: Any]
            try runtimeExpect(preferences["password_manager_enabled"] as? Bool == false, "Browser enabled its own password manager.")
            let original = try String(contentsOf: resources.appendingPathComponent("AppleExtension/background.js"), encoding: .utf8)
            try runtimeExpect(original == "// Fixture extension\n", "Browser changed the source extension.")
            Darwin.kill(pid, SIGTERM)
            try await runtimeUntil { exits == 1 }
            await browser?.stop()
        } else {
            if mode == "wait-cdp" { try await runtimeUntil { !state.commands.isEmpty } }
            startup.cancel()
            try await runtimeFailure("cancelled") { _ = try await startup.value }
            try runtimeExpect(exits == 0, "Failed startup sent an active-session exit event.")
        }
        try runtimeExpect(Darwin.kill(pid, 0) != 0, "Browser test left a child running.")
        try runtimeExpect(try manager.contentsOfDirectory(atPath: data.path).isEmpty, "Browser test left a profile.")
    } catch {
        startup.cancel()
        if let running = try? await startup.value { await running.stop() }
        await browser?.stop()
        throw error
    }
}

@MainActor
func runRuntimeTests() async throws {
    let output = try await BrowserRuntime.runSystemCheck("Test check", command: "/bin/sh", arguments: ["-c", "printf '152.0.7977.82\\n'"])
    try runtimeExpect(output == "152.0.7977.82", "System check changed stdout.")
    do {
        _ = try await BrowserRuntime.runSystemCheck("Chromium signature check", command: "/bin/sh", arguments: ["-c", "printf 'private stdout'; printf 'private stderr' >&2; exit 7"])
        throw EngineFailure("test", "Expected a failing system check.")
    } catch let error as EngineFailure {
        try runtimeExpect(error.code == "browser_verify" && error.message == "Chromium signature check failed (sh, exit 7).", "System check leaked output or lost its error context.")
    }
    try await runtimeFailure("browser_setup") {
        _ = try await BrowserRuntime.runSystemCheck("Chromium Gatekeeper check", command: "/bin/sleep", arguments: ["10"], timeout: .milliseconds(25))
    }
    let cancelled = Task { try await BrowserRuntime.runSystemCheck("Test check", command: "/bin/sleep", arguments: ["10"]) }
    try await Task.sleep(for: .milliseconds(25))
    cancelled.cancel()
    try await runtimeFailure("cancelled") { _ = try await cancelled.value }

    let checksum = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    try await runtimeDownloadTest { url, file in
        var progress: [BrowserRuntime.Status] = []
        try await BrowserRuntime.downloadArchive(from: url, to: file, checksum: checksum, progress: { progress.append($0) })
        try runtimeExpect(try Data(contentsOf: file) == Data("abc".utf8), "Download bytes changed.")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        try runtimeExpect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Download file is not private.")
        try runtimeExpect(progress.first?.receivedBytes == 0 && progress.first?.fraction == 0,
                          "Download progress did not begin at zero.")
        try runtimeExpect(progress.last?.receivedBytes == 3 && progress.last?.fraction == 1,
                          "Download progress did not reach the full response length.")
        try runtimeExpect(progress.allSatisfy { $0.phase == .downloading && $0.totalBytes == 3 && $0.appPath == nil },
                          "Download progress used a wrong phase, total, or installed path.")
        let fractions = progress.compactMap(\.fraction)
        try runtimeExpect(fractions == fractions.sorted() && fractions.allSatisfy { (0...1).contains($0) },
                          "Download progress went backward or left its range.")
        let payload = progress.last!.value
        try runtimeExpect(payload["phase"] as? String == "downloading" && payload["receivedBytes"] as? Int64 == 3 && payload["totalBytes"] as? Int64 == 3,
                          "Download progress lost its structured fields.")
    }
    try await runtimeDownloadTest(body: "wrong archive") { url, file in
        try await runtimeFailure("browser_checksum") { try await BrowserRuntime.downloadArchive(from: url, to: file, checksum: checksum, progress: { _ in }) }
        try runtimeExpect(!FileManager.default.fileExists(atPath: file.path), "Checksum failure left an archive.")
    }
    try await runtimeDownloadTest(status: 503) { url, file in
        var progress: [BrowserRuntime.Status] = []
        try await runtimeFailure("browser_download") { try await BrowserRuntime.downloadArchive(from: url, to: file, checksum: checksum, progress: { progress.append($0) }) }
        try runtimeExpect(!FileManager.default.fileExists(atPath: file.path), "HTTP failure created an archive.")
        try runtimeExpect(progress.isEmpty, "HTTP failure reported successful download progress.")
    }
    try await runtimeDownloadTest { url, file in
        try Data("existing".utf8).write(to: file)
        try await runtimeFailure("browser_download") { try await BrowserRuntime.downloadArchive(from: url, to: file, checksum: checksum, progress: { _ in }) }
        try runtimeExpect(try String(contentsOf: file, encoding: .utf8) == "existing", "Download replaced an existing file.")
    }
    try await runtimeDownloadTest(body: String(repeating: "p", count: 8_192), hold: true) { url, file in
        let download = RuntimeDownloadTask()
        var progress: [BrowserRuntime.Status] = []
        download.task = Task {
            try await BrowserRuntime.downloadArchive(from: url, to: file, checksum: checksum, progress: {
                progress.append($0)
                if ($0.receivedBytes ?? 0) > 0 { download.task?.cancel() }
            })
        }
        try await runtimeFailure("cancelled") { try await download.task?.value }
        download.task = nil
        try runtimeExpect(!FileManager.default.fileExists(atPath: file.path), "Cancellation left a partial archive.")
        try runtimeExpect(progress.contains { ($0.receivedBytes ?? 0) > 0 } && progress.allSatisfy { ($0.fraction ?? 0) < 1 },
                          "Cancelled download did not report partial progress.")
    }
    var setupProgress: [BrowserRuntime.Status] = []
    let cancelledSetup = Task { try await BrowserRuntime.resolve(dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), progress: { setupProgress.append($0) }) }
    cancelledSetup.cancel()
    try await runtimeFailure("cancelled") { _ = try await cancelledSetup.value }
    try runtimeExpect(setupProgress.count == 1 && setupProgress[0].phase == .idle && setupProgress[0].message == nil,
                      "Cancelled setup reported a failure instead of idle.")
    let invalidDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("passtrami-invalid-runtime-" + UUID().uuidString)
    try Data("fixture file".utf8).write(to: invalidDirectory)
    defer { try? FileManager.default.removeItem(at: invalidDirectory) }
    setupProgress.removeAll()
    try await runtimeFailure("browser_setup") {
        _ = try await BrowserRuntime.resolve(dataDirectory: invalidDirectory, progress: { setupProgress.append($0) })
    }
    try runtimeExpect(setupProgress.last?.phase == .failed && setupProgress.last?.message != nil && setupProgress.last?.appPath == nil,
                      "Setup failure did not report a separate runtime error.")
    for mode in ["ready", "wait-ready", "wait-cdp"] { try await runtimeBrowserTest(mode: mode) }
    print("Runtime download, process, CDP, and cleanup checks passed.")
}

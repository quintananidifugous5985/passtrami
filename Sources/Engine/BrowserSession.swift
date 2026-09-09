import Foundation

@MainActor
final class BrowserSession {
    private static let nativeHost = "/System/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app/Contents/MacOS/PasswordManagerBrowserExtensionHelper"
    private let directory: URL
    private let onExit: @MainActor () -> Void
    private var child: EngineChildProcess?
    private var stopping: Task<Void, Never>?
    private var ready = false

    private init(directory: URL, onExit: @escaping @MainActor () -> Void) {
        self.directory = directory
        self.onExit = onExit
    }

    static func start(executable: URL, resources: URL, dataDirectory: URL, port: UInt16, token: String,
                      onExit: @escaping @MainActor () -> Void) async throws -> BrowserSession {
        try checkCancellation()
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: executable.path) else {
            throw EngineFailure("browser_start", "The Chromium executable is missing.")
        }
        guard manager.isExecutableFile(atPath: nativeHost) else {
            throw EngineFailure("native_helper", "Apple's password helper is not installed.")
        }
        let directory = try BrowserRuntime.makePrivateDirectory(in: dataDirectory, prefix: "session-")
        let session = BrowserSession(directory: directory, onExit: onExit)
        do {
            let profile = directory.appendingPathComponent("profile", isDirectory: true)
            let appleExtension = directory.appendingPathComponent("extension", isDirectory: true)
            try copyDirectory(resources.appendingPathComponent("AppleExtension"), to: appleExtension)
            let background = appleExtension.appendingPathComponent("background.js")
            let original = try String(contentsOf: background, encoding: .utf8)
            let bridge = try String(contentsOf: resources.appendingPathComponent("Engine/bridge.js"), encoding: .utf8)
            let config = try JSONSerialization.data(withJSONObject: ["port": port, "token": token], options: [.sortedKeys])
            let patched = original + "\nself.ASTER_CONFIG=" + String(decoding: config, as: UTF8.self) + ";\n" + bridge + "\n"
            try Data(patched.utf8).write(to: background)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: background.path)
            try checkCancellation()
            let hosts = profile.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            try manager.createDirectory(at: hosts, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try writeJSON([
                "name": "com.apple.passwordmanager", "description": "Apple Passwords",
                "path": nativeHost, "type": "stdio",
                "allowed_origins": ["chrome-extension://pejdijmoenmkgeppbflobdenhhabjlaj/"]
            ], to: hosts.appendingPathComponent("com.apple.passwordmanager.json"))
            let defaultProfile = profile.appendingPathComponent("Default", isDirectory: true)
            try manager.createDirectory(at: defaultProfile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try writeJSON([
                "profile": ["default_content_setting_values": ["notifications": 2]],
                "browser": ["check_default_browser": false], "credentials_enable_service": false,
                "password_manager_enabled": false
            ], to: defaultProfile.appendingPathComponent("Preferences"))
            try checkCancellation()
            session.child = try EngineChildProcess(executable: executable, arguments: [
                "--user-data-dir=\(profile.path)", "--remote-debugging-port=0", "--enable-unsafe-extension-debugging",
                "--headless=new", "--use-mock-keychain",
                "--disable-features=DialMediaRouteProvider,NativeNotifications,MacAppCodeSignClone",
                "--no-first-run", "--no-default-browser-check", "--disable-notifications",
                "--disable-background-timer-throttling", "--disable-backgrounding-occluded-windows"
            ]) { [weak session] in
                guard let session, session.ready, session.stopping == nil else { return }
                session.onExit()
            }
            try await withTaskCancellationHandler {
                let endpoint = try await session.debuggerEndpoint(profile: profile)
                try await loadExtension(at: appleExtension, endpoint: endpoint)
                try checkCancellation()
                guard session.child?.isRunning == true else {
                    throw EngineFailure("browser_start", "Chromium stopped during startup.")
                }
            } onCancel: {
                Task { @MainActor in session.child?.beginStop() }
            }
            session.ready = true
            return session
        } catch {
            await session.stop()
            if Task.isCancelled { throw EngineFailure("cancelled", "Browser startup was cancelled.") }
            throw error
        }
    }

    func stop() async {
        if let stopping { await stopping.value; return }
        ready = false
        let cleanup = Task { @MainActor in
            await child?.stop()
            child = nil
            try? FileManager.default.removeItem(at: directory)
        }
        stopping = cleanup
        await cleanup.value
    }

    private static func checkCancellation() throws {
        if Task.isCancelled { throw EngineFailure("cancelled", "Browser startup was cancelled.") }
    }

    private static func copyDirectory(_ source: URL, to destination: URL) throws {
        try checkCancellation()
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for url in try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]) {
            try checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            let target = destination.appendingPathComponent(url.lastPathComponent)
            if values.isDirectory == true { try copyDirectory(url, to: target) }
            else if values.isRegularFile == true { try manager.copyItem(at: url, to: target) }
        }
    }

    private static func writeJSON(_ value: [String: Any], to url: URL) throws {
        try checkCancellation()
        let output = try BrowserRuntime.createPrivateFile(url)
        defer { try? output.close() }
        try output.write(contentsOf: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
    }

    private func debuggerEndpoint(profile: URL) async throws -> URL {
        for _ in 0..<100 {
            try Self.checkCancellation()
            guard child?.isRunning == true else { throw EngineFailure("browser_start", "Chromium did not start.") }
            if let text = try? String(contentsOf: profile.appendingPathComponent("DevToolsActivePort"), encoding: .utf8) {
                let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n")
                if lines.count >= 2, let port = UInt16(lines[0]), port > 0,
                   lines[1].hasPrefix("/devtools/browser/"),
                   let url = URL(string: "ws://127.0.0.1:\(port)\(lines[1])") { return url }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw EngineFailure("browser_start", "Chromium did not start.")
    }

    private static func loadExtension(at extensionURL: URL, endpoint: URL) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        let connection = URLSession(configuration: configuration)
        let socket = connection.webSocketTask(with: endpoint)
        socket.resume()
        defer {
            socket.cancel(with: .goingAway, reason: nil)
            connection.invalidateAndCancel()
        }
        let command = try JSONSerialization.data(withJSONObject: [
            "id": 1, "method": "Extensions.loadUnpacked", "params": ["path": extensionURL.path]
        ])
        var timedOut = false
        let deadline = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            timedOut = true
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer { deadline.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await socket.send(.string(String(decoding: command, as: UTF8.self)))
                while true {
                    let message = try await socket.receive()
                    let data: Data
                    switch message {
                    case .data(let value): data = value
                    case .string(let value): data = Data(value.utf8)
                    @unknown default: throw EngineFailure("browser_connection", "Chromium sent an invalid response.")
                    }
                    guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw EngineFailure("browser_connection", "Chromium sent an invalid response.")
                    }
                    if response["id"] as? Int == 1 {
                        if response["error"] != nil {
                            throw EngineFailure("extension_start", "The password extension could not be loaded.")
                        }
                        return
                    }
                }
            } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
        } catch {
            try checkCancellation()
            if timedOut { throw EngineFailure("extension_start", "The password extension did not load.") }
            if let failure = error as? EngineFailure { throw failure }
            throw EngineFailure("browser_connection", "Could not connect to Chromium.")
        }
    }
}

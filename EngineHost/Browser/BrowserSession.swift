import Darwin
import Foundation

@MainActor
final class BrowserSession {
    private static let nativeHost = "/System/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app/Contents/MacOS/PasswordManagerBrowserExtensionHelper"
    private let directory: URL
    private let onExit: @MainActor () -> Void
    private var child: EngineChildProcess?
    private var debugger: BrowserDebugPipe?
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
            let patched = original + "\nself.PASSTRAMI_CONFIG=" + String(decoding: config, as: UTF8.self) + ";\n" + bridge + "\n"
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
            let debugger = try BrowserDebugPipe { [weak session] in session?.child?.beginStop() }
            session.debugger = debugger
            session.child = try EngineChildProcess(executable: executable, arguments: [
                "--user-data-dir=\(profile.path)", "--remote-debugging-pipe", "--enable-unsafe-extension-debugging",
                "--headless=new", "--use-mock-keychain",
                "--disable-features=DialMediaRouteProvider,NativeNotifications,MacAppCodeSignClone",
                "--no-first-run", "--no-default-browser-check", "--disable-notifications",
                "--disable-background-timer-throttling", "--disable-backgrounding-occluded-windows"
            ], inheritedDescriptors: [3: debugger.childInput, 4: debugger.childOutput]) { [weak session] in
                guard let session, session.ready, session.stopping == nil else { return }
                session.onExit()
            }
            debugger.closeChildEnds()
            try await withTaskCancellationHandler {
                try await debugger.loadExtension(at: appleExtension)
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
            debugger?.close()
            debugger = nil
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

}

// Chromium 152 uses child fd 3 for commands and fd 4 for replies. With no pipe
// mode argument, each CDP JSON message ends in NUL (DevToolsPipeHandler ASCIIZ).
@MainActor
final class BrowserDebugPipe {
    private static let maximumMessageSize = 1_048_576
    private let commandRead: FileHandle
    private let commandWrite: FileHandle
    private let replyRead: FileHandle
    private let replyWrite: FileHandle
    private let reader: any DispatchSourceRead
    private var writer: (any DispatchSourceWrite)?
    private let onFailure: @MainActor () -> Void
    private var incoming = Data()
    private var outgoing = Data()
    private var writeOffset = 0
    private var completion: CheckedContinuation<Void, any Error>?
    private var deadline: Task<Void, Never>?
    private var requested = false
    private var closed = false

    var childInput: Int32 { commandRead.fileDescriptor }
    var childOutput: Int32 { replyWrite.fileDescriptor }

    init(onFailure: @escaping @MainActor () -> Void) throws {
        var commands = [Int32](repeating: -1, count: 2)
        var replies = [Int32](repeating: -1, count: 2)
        guard pipe(&commands) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard pipe(&replies) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            for descriptor in commands { Darwin.close(descriptor) }
            throw error
        }
        do {
            for descriptor in commands + replies {
                guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            for descriptor in [commands[1], replies[0]] {
                let flags = fcntl(descriptor, F_GETFL)
                guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            guard fcntl(commands[1], F_SETNOSIGPIPE, 1) >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            for descriptor in commands + replies { Darwin.close(descriptor) }
            throw error
        }
        commandRead = FileHandle(fileDescriptor: commands[0], closeOnDealloc: true)
        commandWrite = FileHandle(fileDescriptor: commands[1], closeOnDealloc: true)
        replyRead = FileHandle(fileDescriptor: replies[0], closeOnDealloc: true)
        replyWrite = FileHandle(fileDescriptor: replies[1], closeOnDealloc: true)
        reader = DispatchSource.makeReadSource(fileDescriptor: replies[0], queue: .main)
        self.onFailure = onFailure
        reader.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.receive() } }
        reader.resume()
    }

    func closeChildEnds() {
        try? commandRead.close()
        try? replyWrite.close()
    }

    func loadExtension(at url: URL, timeout: Duration = .seconds(15)) async throws {
        guard !closed, !requested else { throw EngineFailure("browser_connection", "Chromium's command pipe is unavailable.") }
        try Task.checkCancellation()
        var command = try JSONSerialization.data(withJSONObject: [
            "id": 1, "method": "Extensions.loadUnpacked", "params": ["path": url.path]
        ])
        guard command.count <= Self.maximumMessageSize else { throw EngineFailure("extension_start", "The extension path is too long.") }
        command.append(0)
        requested = true
        outgoing = command
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                deadline = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.fail(EngineFailure("extension_start", "The password extension did not load."))
                }
                let writer = DispatchSource.makeWriteSource(fileDescriptor: commandWrite.fileDescriptor, queue: .main)
                self.writer = writer
                writer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.send() } }
                writer.resume()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.fail(EngineFailure("cancelled", "Browser startup was cancelled.")) }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        reader.cancel()
        writer?.cancel()
        writer = nil
        closeChildEnds()
        try? commandWrite.close()
        try? replyRead.close()
        incoming.removeAll()
        outgoing.removeAll()
        finish(EngineFailure("browser_connection", "Chromium's command pipe closed."))
    }

    private func finish(_ error: (any Error)? = nil) {
        deadline?.cancel()
        deadline = nil
        let continuation = completion
        completion = nil
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
    }

    private func fail(_ error: EngineFailure) {
        guard !closed else { return }
        finish(error)
        close()
        onFailure()
    }

    private func send() {
        guard !closed else { return }
        while writeOffset < outgoing.count {
            let count = outgoing.withUnsafeBytes { bytes in
                Darwin.write(commandWrite.fileDescriptor, bytes.baseAddress!.advanced(by: writeOffset), bytes.count - writeOffset)
            }
            if count > 0 { writeOffset += count; continue }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            fail(EngineFailure("browser_connection", "Could not send a command to Chromium."))
            return
        }
        outgoing.removeAll()
        writer?.cancel()
        writer = nil
    }

    private func receive() {
        guard !closed else { return }
        var bytes = [UInt8](repeating: 0, count: 16_384)
        var received = 0
        // Yield the main queue so a stream of events cannot prevent the deadline.
        while !closed && received < 262_144 {
            let count = Darwin.read(replyRead.fileDescriptor, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            guard count > 0 else {
                fail(EngineFailure("browser_connection", "Chromium's command pipe closed."))
                return
            }
            received += count
            incoming.append(contentsOf: bytes.prefix(count))
            while let end = incoming.firstIndex(of: 0) {
                guard incoming.distance(from: incoming.startIndex, to: end) <= Self.maximumMessageSize,
                      let response = try? JSONSerialization.jsonObject(with: incoming[..<end]) as? [String: Any] else {
                    fail(EngineFailure("browser_connection", "Chromium sent an invalid response."))
                    return
                }
                incoming.removeSubrange(...end)
                if response["id"] as? Int == 1, completion != nil {
                    guard response["error"] == nil, let result = response["result"] as? [String: Any], result["id"] is String else {
                        fail(EngineFailure("extension_start", "The password extension could not be loaded."))
                        return
                    }
                    finish()
                }
            }
            guard incoming.count <= Self.maximumMessageSize else {
                fail(EngineFailure("browser_connection", "Chromium sent an oversized response."))
                return
            }
        }
    }
}

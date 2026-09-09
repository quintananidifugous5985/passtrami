import CryptoKit
import Darwin
import Foundation

@MainActor
final class EngineChildProcess {
    struct Status { let code: Int32; let signalled: Bool }
    private let process = Process()
    private var result: Status?
    private var waiters: [CheckedContinuation<Status, Never>] = []
    private var killTask: Task<Void, Never>?
    private let onExit: @MainActor () -> Void
    private var stopping = false

    var isRunning: Bool { process.isRunning }

    init(executable: URL, arguments: [String], output: FileHandle? = nil,
         onExit: @escaping @MainActor () -> Void = {}) throws {
        self.onExit = onExit
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            let status = Status(code: process.terminationStatus,
                                signalled: process.terminationReason == .uncaughtSignal)
            Task { @MainActor [weak self] in self?.finished(status) }
        }
        try process.run()
    }

    private func finished(_ status: Status) {
        guard result == nil else { return }
        result = status
        process.terminationHandler = nil
        killTask?.cancel()
        killTask = nil
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations { continuation.resume(returning: status) }
        onExit()
    }

    func wait() async -> Status {
        if let result { return result }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func beginStop(grace: Duration = .seconds(3)) {
        guard result == nil, !stopping else { return }
        stopping = true
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGTERM) }
        killTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: grace) } catch { return }
            guard let self, self.result == nil, self.process.isRunning else { return }
            Darwin.kill(self.process.processIdentifier, SIGKILL)
        }
    }

    func stop(grace: Duration = .seconds(3)) async {
        beginStop(grace: grace)
        _ = await wait()
    }
}

@MainActor
final class BrowserRuntime {
    static let release = "152.0.7977.82-1.1"
    static let minimumVersion = "152.0.7977.82"
    private static let archiveURL = URL(string: "https://github.com/ungoogled-software/ungoogled-chromium-macos/releases/download/\(release)/ungoogled-chromium_\(release)_arm64-macos.dmg")!
    private static let checksum = "ba673876533e79b3c09edaf3ebd0dadcc29e9d0112b9b843d8c032cfb7bfb457"
    private static let signingRequirement = "=anchor apple generic and identifier \"io.ungoogled-software.ungoogled-chromium\" and certificate leaf[subject.OU] = \"B9A88FL5XJ\""

    static func checkCancellation() throws {
        if Task.isCancelled { throw EngineFailure("cancelled", "Browser setup was cancelled.") }
    }

    static func isCompatibleVersion(_ version: String) -> Bool {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4,
              components.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }) else { return false }
        let actual = components.compactMap { UInt64($0) }
        guard actual.count == 4, actual.allSatisfy({ $0 <= 9_007_199_254_740_991 }) else { return false }
        let required = minimumVersion.split(separator: ".").map { UInt64($0)! }
        for (value, minimum) in zip(actual, required) where value != minimum { return value > minimum }
        return true
    }

    static func makePrivateDirectory(in parent: URL, prefix: String) throws -> URL {
        let path = parent.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return path
    }

    static func createPrivateFile(_ url: URL) throws -> FileHandle {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    static func runSystemCheck(_ operation: String, command: String, arguments: [String],
                               timeout: Duration = .seconds(30)) async throws -> String {
        try checkCancellation()
        let directory = try makePrivateDirectory(in: FileManager.default.temporaryDirectory, prefix: "aster-check-")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("output")
        let output = try createPrivateFile(outputURL)
        defer { try? output.close() }
        let tool = URL(fileURLWithPath: command).lastPathComponent
        let child: EngineChildProcess
        do { child = try EngineChildProcess(executable: URL(fileURLWithPath: command), arguments: arguments, output: output) }
        catch { throw EngineFailure("browser_setup", "\(operation) could not start (\(tool)).") }
        var timedOut = false
        let deadline = Task { @MainActor in
            do { try await Task.sleep(for: timeout) } catch { return }
            timedOut = true
            child.beginStop(grace: .seconds(1))
        }
        let status = await withTaskCancellationHandler {
            await child.wait()
        } onCancel: {
            Task { @MainActor in child.beginStop(grace: .seconds(1)) }
        }
        deadline.cancel()
        try checkCancellation()
        if timedOut { throw EngineFailure("browser_setup", "\(operation) timed out (\(tool)).") }
        guard status.code == 0, !status.signalled else {
            let reason = status.signalled ? "signal \(status.code)" : "exit \(status.code)"
            throw EngineFailure("browser_verify", "\(operation) failed (\(tool), \(reason)).")
        }
        return String(decoding: try Data(contentsOf: outputURL), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validate(_ app: URL, pinned: Bool = false) async throws -> URL {
        try checkCancellation()
        let executable = app.appendingPathComponent("Contents/MacOS/Chromium")
        let attributes = try FileManager.default.attributesOfItem(atPath: executable.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw EngineFailure("browser_verify", "The Chromium executable is missing.")
        }
        let version = try await runSystemCheck("Chromium version check", command: "/usr/bin/plutil",
            arguments: ["-extract", "CFBundleShortVersionString", "raw", "-o", "-", app.appendingPathComponent("Contents/Info.plist").path])
        guard isCompatibleVersion(version), !pinned || version == minimumVersion else {
            throw EngineFailure("browser_version", "This Chromium version is not supported.")
        }
        _ = try await runSystemCheck("Chromium architecture check", command: "/usr/bin/codesign",
                                    arguments: ["--display", "--architecture", "arm64", executable.path])
        _ = try await runSystemCheck("Chromium signature check", command: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", "--test-requirement", signingRequirement, app.path])
        _ = try await runSystemCheck("Chromium Gatekeeper check", command: "/usr/sbin/spctl",
                                    arguments: ["--assess", "--type", "exec", app.path], timeout: .seconds(60))
        return executable
    }

    static func downloadArchive(from url: URL, to destination: URL, checksum: String,
                                progress: @escaping @MainActor (String) -> Void) async throws {
        try checkCancellation()
        let download = ArchiveDownload(url: url, destination: destination, checksum: checksum, progress: progress)
        try await withTaskCancellationHandler {
            try await download.run()
            try checkCancellation()
        } onCancel: {
            Task { @MainActor in download.cancel() }
        }
    }

    private static func detach(_ mount: URL) async throws {
        do {
            _ = try await runSystemCheck("Chromium disk image eject", command: "/usr/sbin/diskutil",
                                        arguments: ["eject", mount.path], timeout: .seconds(10))
        } catch {
            guard FileManager.default.fileExists(atPath: mount.appendingPathComponent("Chromium.app").path) else { return }
            _ = try await runSystemCheck("Chromium disk image detach", command: "/usr/bin/hdiutil",
                                        arguments: ["detach", "-force", mount.path], timeout: .seconds(10))
        }
    }

    static func resolve(dataDirectory: URL, progress: @escaping @MainActor (String) -> Void) async throws -> URL {
        try checkCancellation()
        #if !os(macOS) || !arch(arm64)
        throw EngineFailure("browser_platform", "Aster requires an Apple silicon Mac.")
        #else
        let manager = FileManager.default
        var installed = [URL(fileURLWithPath: "/Applications/Chromium.app")]
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            installed.append(URL(fileURLWithPath: home).appendingPathComponent("Applications/Chromium.app"))
        }
        for app in installed where manager.fileExists(atPath: app.path) {
            do {
                progress("Checking installed Chromium…")
                return try await validate(app)
            } catch { try checkCancellation() }
        }
        let cache = dataDirectory.appendingPathComponent("Browser", isDirectory: true)
        let versionDirectory = cache.appendingPathComponent(release, isDirectory: true)
        let cachedApp = versionDirectory.appendingPathComponent("Chromium.app")
        if manager.fileExists(atPath: cachedApp.path) {
            do {
                progress("Checking Chromium…")
                return try await validate(cachedApp, pinned: true)
            } catch { try checkCancellation() }
        }
        try checkCancellation()
        try manager.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cache.path)
        let staging = try makePrivateDirectory(in: cache, prefix: "download-")
        let mount = staging.appendingPathComponent("mount", isDirectory: true)
        let package = staging.appendingPathComponent("package", isDirectory: true)
        var attachStarted = false
        do {
            progress("Downloading Chromium…")
            let archive = staging.appendingPathComponent("browser.dmg")
            try await downloadArchive(from: archiveURL, to: archive, checksum: checksum, progress: progress)
            try checkCancellation()
            progress("Installing Chromium…")
            try manager.createDirectory(at: mount, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try manager.createDirectory(at: package, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            attachStarted = true
            _ = try await runSystemCheck("Chromium disk image mount", command: "/usr/sbin/diskutil",
                arguments: ["image", "attach", "--readOnly", "--nobrowse", "--mountPoint", mount.path, archive.path], timeout: .seconds(60))
            _ = try await runSystemCheck("Chromium copy", command: "/usr/bin/ditto",
                arguments: [mount.appendingPathComponent("Chromium.app").path, package.appendingPathComponent("Chromium.app").path], timeout: .seconds(120))
            try await detach(mount)
            attachStarted = false
            try checkCancellation()
            _ = try await runSystemCheck("Chromium Finder metadata cleanup", command: "/usr/bin/xattr",
                arguments: ["-dr", "com.apple.FinderInfo", package.appendingPathComponent("Chromium.app").path])
            progress("Checking Chromium…")
            _ = try await validate(package.appendingPathComponent("Chromium.app"), pinned: true)
            try checkCancellation()
            if manager.fileExists(atPath: versionDirectory.path) { try manager.removeItem(at: versionDirectory) }
            try checkCancellation()
            try manager.moveItem(at: package, to: versionDirectory)
            try manager.removeItem(at: staging)
            return cachedApp.appendingPathComponent("Contents/MacOS/Chromium")
        } catch {
            if attachStarted {
                // Cleanup must finish even when the setup task has been cancelled.
                try await Task { @MainActor in try await detach(mount) }.value
            }
            try? manager.removeItem(at: staging)
            throw error
        }
        #endif
    }
}

@MainActor
private final class ArchiveDownload: NSObject, @preconcurrency URLSessionDataDelegate {
    private let url: URL
    private let destination: URL
    private let expectedChecksum: String
    private let progress: @MainActor (String) -> Void
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var file: FileHandle?
    private var hasher = SHA256()
    private var received: Int64 = 0
    private var length: Int64 = 0
    private var lastProgress = Date.distantPast
    private var continuation: CheckedContinuation<Void, any Error>?
    private var finished = false
    private var created = false
    private var cancelled = false

    init(url: URL, destination: URL, checksum: String, progress: @escaping @MainActor (String) -> Void) {
        self.url = url
        self.destination = destination
        expectedChecksum = checksum
        self.progress = progress
    }

    func run() async throws {
        if cancelled { throw EngineFailure("cancelled", "Browser setup was cancelled.") }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 600
            configuration.timeoutIntervalForResource = 600
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
            self.session = session
            let task = session.dataTask(with: url)
            self.task = task
            task.resume()
        }
    }

    func cancel() {
        cancelled = true
        finish(EngineFailure("cancelled", "Browser setup was cancelled."))
    }

    private func finish(_ error: (any Error)?) {
        guard !finished else { return }
        finished = true
        try? file?.close()
        file = nil
        if error != nil, created { try? FileManager.default.removeItem(at: destination) }
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
        continuation = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard !finished else { completionHandler(.cancel); return }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            completionHandler(.cancel)
            finish(EngineFailure("browser_download", "Chromium could not be downloaded. Try Unlock again."))
            return
        }
        do {
            file = try BrowserRuntime.createPrivateFile(destination)
            created = true
            length = response.expectedContentLength
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            finish(EngineFailure("browser_download", "The Chromium download file could not be created."))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished else { return }
        do {
            try file?.write(contentsOf: data)
            hasher.update(data: data)
            received += Int64(data.count)
            let now = Date()
            if now.timeIntervalSince(lastProgress) >= 1 {
                let amount = length > 0 ? "\(min(100, Int(Double(received) / Double(length) * 100)))%" : "\(received / 1_048_576) MB"
                progress("Downloading Chromium: \(amount)")
                lastProgress = now
            }
        } catch { finish(EngineFailure("browser_download", "The Chromium download could not be saved.")) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard !finished else { return }
        if let error {
            let timeout = (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorTimedOut
            finish(EngineFailure("browser_download", timeout
                ? "The Chromium download took too long. Try Unlock again."
                : "Chromium could not be downloaded. Check your connection, then try Unlock again."))
            return
        }
        let checksum = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard checksum == expectedChecksum else {
            finish(EngineFailure("browser_checksum", "The Chromium download failed its checksum check. Try Unlock again."))
            return
        }
        do { try file?.synchronize(); finish(nil) }
        catch { finish(EngineFailure("browser_download", "The Chromium download could not be saved.")) }
    }
}

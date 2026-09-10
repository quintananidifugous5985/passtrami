import Darwin
import Foundation
import OSLog

// The Apple preference is shared by this macOS user. A separate guard restores it
// if the engine exits. This cannot isolate helpers or make propagation instant.
final class TouchIDPreferenceWindow: @unchecked Sendable {
    // Mutable session state is confined to queue; monitor only reads the immutable handles.
    private final class Session: @unchecked Sendable {
        let id: String
        let process: Process
        let input: FileHandle
        let output: FileHandle
        let exited: DispatchSemaphore
        var expired = false
        var ending: CheckedContinuation<Void, any Error>?

        init(id: String, process: Process, input: FileHandle, output: FileHandle, exited: DispatchSemaphore) {
            self.id = id
            self.process = process
            self.input = input
            self.output = output
            self.exited = exited
        }
    }

    private let queue = DispatchQueue(label: "io.zats.Passtrami.password-approval")
    private let directory: URL
    private let suite: String
    private let executable: URL
    private let onExpired: @Sendable (String) -> Void
    private var active: Session?
    private var expiredID: String?

    init(directory: URL, suite: String? = nil, executable: URL? = nil,
         onExpired: @escaping @Sendable (String) -> Void) {
        self.directory = directory
        self.suite = suite ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Preferences/com.apple.Safari").path
        self.executable = executable ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        self.onExpired = onExpired
    }

    func recover() async throws {
        try await perform {
            guard self.active == nil else { throw CocoaError(.fileWriteUnknown) }
            try PreferenceGuardStore(directory: self.directory, suite: self.suite).withLock { try $0.restore() }
        }
    }

    func begin(_ id: String) async throws {
        try await perform { [self] in
            guard active == nil else { throw CocoaError(.fileWriteUnknown) }
            let process = Process(), input = Pipe(), output = Pipe()
            let exited = DispatchSemaphore(value: 0)
            process.executableURL = executable
            process.arguments = ["--preference-guard", "--data-dir", directory.path, "--suite", suite]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in exited.signal() }
            // A later child must not keep this pipe open after the engine exits.
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
            try PreferenceGuardDiagnostics.check("launch") { try process.run() }
            try? input.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            let session = Session(id: id, process: process,
                input: input.fileHandleForWriting, output: output.fileHandleForReading, exited: exited)
            do {
                guard try PreferenceGuardIO.readLine(from: session.output, deadline: .now() + 4) == "READY" else {
                    throw CocoaError(.executableRuntimeMismatch)
                }
            } catch {
                PreferenceGuardDiagnostics.failure("startup-handshake", error)
                try? session.input.close()
                // Never kill the guard: a failed startup may still need to restore its journal.
                _ = exited.wait(timeout: .now() + 6)
                try? session.output.close()
                throw error
            }
            active = session
            expiredID = nil
            DispatchQueue.global(qos: .userInitiated).async { [self] in monitor(session) }
        }
    }

    func end(_ id: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                guard let session = active, session.id == id else {
                    continuation.resume(throwing: CocoaError(expiredID == id ? .userCancelled : .fileWriteUnknown))
                    return
                }
                guard session.ending == nil else {
                    continuation.resume(throwing: CocoaError(.fileWriteUnknown))
                    return
                }
                session.ending = continuation
                // EOF requests restoration. Only a verified guard exit completes this call.
                try? session.input.close()
            }
        }
    }

    private func monitor(_ session: Session) {
        var restored = false
        do {
            while let line = try PreferenceGuardIO.readLine(from: session.output, deadline: .now() + 6) {
                if line == "EXPIRED" { queue.async { [self] in expire(session) } }
                else if line == "RESTORED" { restored = true }
                else { break }
            }
        } catch { PreferenceGuardDiagnostics.failure("monitor-output", error) }
        let didExit = session.exited.wait(timeout: .now() + 6) == .success
        try? session.output.close()
        let succeeded = didExit && restored && session.process.terminationReason == .exit && session.process.terminationStatus == 0
        if !succeeded {
            let status = didExit ? session.process.terminationStatus : -1
            PreferenceGuardDiagnostics.logger.error("Guard failed: exited=\(didExit), restored=\(restored), status=\(status)")
        }
        queue.async { [self] in
            guard active === session else { return }
            try? session.input.close()
            if !succeeded {
                expire(session)
                // A killed guard cannot restore its journal. Keep this request failed,
                // and take the same lock before restoring in case the guard is still alive.
                try? PreferenceGuardDiagnostics.check("parent-recovery") {
                    try PreferenceGuardStore(directory: directory, suite: suite).withLock { try $0.restore() }
                }
            }
            active = nil
            if session.expired || !succeeded { session.ending?.resume(throwing: CocoaError(.userCancelled)) }
            else { session.ending?.resume() }
            session.ending = nil
        }
    }

    private func expire(_ session: Session) {
        guard active === session, !session.expired else { return }
        session.expired = true
        expiredID = session.id
        onExpired(session.id)
    }

    private func perform(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do { try work(); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Internal child mode. The parent keeps stdin open until the password operation ends.
    static func runGuardIfRequested(_ arguments: [String]) -> Int32? {
        guard arguments.first == "--preference-guard" else { return nil }
        guard arguments.count == 5, arguments[1] == "--data-dir", arguments[3] == "--suite" else { return 64 }
        signal(SIGPIPE, SIG_IGN)
        let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
        do {
            try PreferenceGuardStore(directory: directory, suite: arguments[4]).withLock { store in
                try PreferenceGuardDiagnostics.check("recover-previous") { try store.restore() }
                guard PreferenceGuardIO.parentIsConnected() else { return }
                try PreferenceGuardDiagnostics.check("snapshot") { try store.saveSnapshot() }
                let deadline = DispatchTime.now() + 1
                do {
                    guard PreferenceGuardIO.parentIsConnected() else { throw CocoaError(.userCancelled) }
                    try PreferenceGuardDiagnostics.check("write-temporary") { try store.write(false) }
                    guard DispatchTime.now() < deadline else { throw CocoaError(.userCancelled) }
                    try PreferenceGuardIO.send("READY")
                    let expired = try PreferenceGuardIO.waitForClose(deadline: deadline)
                    if expired { try? PreferenceGuardIO.send("EXPIRED") }
                    try PreferenceGuardDiagnostics.check("restore-original") { try store.restore() }
                    try? PreferenceGuardIO.send("RESTORED")
                } catch {
                    // A broken output pipe means the parent died; restoration must still finish.
                    try PreferenceGuardDiagnostics.check("restore-after-failure") { try store.restore() }
                    throw error
                }
            }
            return 0
        } catch {
            PreferenceGuardDiagnostics.failure("guard-exit", error)
            return 1
        }
    }
}

private enum PreferenceGuardDiagnostics {
    static let logger = Logger(subsystem: "io.zats.Passtrami", category: "PreferenceGuard")

    static func failure(_ stage: String, _ error: any Error) {
        let value = error as NSError
        // Error domains and codes identify permission failures without logging paths or plist contents.
        logger.error("\(stage, privacy: .public) failed: \(value.domain, privacy: .public) \(value.code)")
        if let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError {
            logger.error("\(stage, privacy: .public) underlying error: \(underlying.domain, privacy: .public) \(underlying.code)")
        }
    }

    static func check<T>(_ stage: String, _ operation: () throws -> T) rethrows -> T {
        do { return try operation() }
        catch { failure(stage, error); throw error }
    }
}

private enum PreferenceGuardIO {
    static func parentIsConnected() -> Bool {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
        let result = poll(&descriptor, 1, 0)
        return result >= 0 && descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) == 0
    }

    static func send(_ line: String) throws {
        try FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8))
    }

    static func readLine(from handle: FileHandle, deadline: DispatchTime) throws -> String? {
        var bytes = Data()
        while true {
            guard try wait(fd: handle.fileDescriptor, deadline: deadline) != 0 else { throw CocoaError(.executableRuntimeMismatch) }
            var byte: UInt8 = 0
            let size = Darwin.read(handle.fileDescriptor, &byte, 1)
            if size == 0 { return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self) }
            guard size == 1 else {
                if errno == EINTR { continue }
                throw CocoaError(.fileReadUnknown)
            }
            if byte == 0x0A { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
            guard bytes.count <= 32 else { throw CocoaError(.fileReadCorruptFile) }
        }
    }

    static func waitForClose(deadline: DispatchTime) throws -> Bool {
        while true {
            if try wait(fd: STDIN_FILENO, deadline: deadline) == 0 { return true }
            var byte: UInt8 = 0
            let size = Darwin.read(STDIN_FILENO, &byte, 1)
            if size == 0 { return false }
            if size < 0, errno != EINTR { throw CocoaError(.fileReadUnknown) }
            // Input grants no extra time; only EOF ends the interval early.
        }
    }

    private static func wait(fd: Int32, deadline: DispatchTime) throws -> Int16 {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard deadline.uptimeNanoseconds > now else { return 0 }
            let remaining = deadline.uptimeNanoseconds - now
            let milliseconds = Int32(min((remaining + 999_999) / 1_000_000, UInt64(Int32.max)))
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            let result = poll(&descriptor, 1, milliseconds)
            if result == 0 { return 0 }
            if result < 0 {
                if errno == EINTR { continue }
                throw CocoaError(.fileReadUnknown)
            }
            if descriptor.revents & Int16(POLLERR | POLLNVAL) != 0 { throw CocoaError(.fileReadUnknown) }
            return descriptor.revents
        }
    }
}

private struct PreferenceGuardStore {
    private struct Snapshot: Codable {
        let wasPresent: Bool
        let value: Bool
    }

    let directory: URL
    let suite: String
    private var journal: URL { directory.appendingPathComponent("approval-preference.json") }

    func withLock(_ work: (Self) throws -> Void) throws {
        let lock = directory.appendingPathComponent("approval-preference.lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        let deadline = DispatchTime.now() + 3
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, DispatchTime.now() < deadline else { throw CocoaError(.fileLocking) }
            usleep(10_000)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        try work(self)
    }

    func saveSnapshot() throws {
        try JSONEncoder().encode(read()).write(to: journal, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
    }

    func restore() throws {
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: journal))
        if snapshot.wasPresent { try write(snapshot.value) }
        else {
            _ = try run(["delete", suite, "TouchIDToAutoFill"])
            guard !(try read()).wasPresent else { throw CocoaError(.fileWriteUnknown) }
        }
        try FileManager.default.removeItem(at: journal)
    }

    private func read() throws -> Snapshot {
        let result = try run(["read", suite, "TouchIDToAutoFill"])
        if result.status == 0 {
            guard ["0", "1"].contains(result.output) else { throw CocoaError(.propertyListReadCorrupt) }
            return Snapshot(wasPresent: true, value: result.output == "1")
        }
        let path = URL(fileURLWithPath: suite + ".plist")
        do {
            // fileExists can return false for denied metadata access. Only a real missing
            // file or a readable plist without this key can establish an absent value.
            let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: path), format: nil)
            guard let dictionary = value as? [String: Any], dictionary["TouchIDToAutoFill"] == nil else { throw CocoaError(.fileReadUnknown) }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return Snapshot(wasPresent: false, value: true)
        }
        return Snapshot(wasPresent: false, value: true)
    }

    func write(_ value: Bool) throws {
        let status = try run(["write", suite, "TouchIDToAutoFill", "-bool", value ? "YES" : "NO"]).status
        guard status == 0 else {
            PreferenceGuardDiagnostics.logger.error("defaults write failed: status=\(status)")
            throw CocoaError(.fileWriteUnknown)
        }
        let result = try read()
        guard result.wasPresent, result.value == value else { throw CocoaError(.fileWriteUnknown) }
    }

    private func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process(), output = Pipe()
        let exited = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        guard exited.wait(timeout: .now() + 0.5) == .success else {
            let operation = arguments.first ?? "unknown"
            PreferenceGuardDiagnostics.logger.error("defaults \(operation, privacy: .public) timed out")
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            throw CocoaError(.executableRuntimeMismatch)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

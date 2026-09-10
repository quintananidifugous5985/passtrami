import Darwin
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
if let status = TouchIDPreferenceWindow.runGuardIfRequested(arguments) { exit(status) }

struct TestFailure: Error { let message: String }
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(message: message) }
}

final class Expirations: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ id: String) { lock.withLock { values.append(id) } }
    func contains(_ id: String) -> Bool { lock.withLock { values.contains(id) } }
}

struct Fixture {
    let directory: URL
    let suite: String
    var journal: URL { directory.appendingPathComponent("approval-preference.json") }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("passtrami-preference-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = directory.appendingPathComponent("isolated-preferences").path
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }

    func command(_ args: [String]) throws -> (Int32, String) {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = args
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func set(_ value: Bool?) throws {
        if let value {
            let result = try command(["write", suite, "TouchIDToAutoFill", "-bool", value ? "YES" : "NO"])
            try expect(result.0 == 0, "Could not set isolated preference")
        } else { _ = try command(["delete", suite, "TouchIDToAutoFill"]) }
    }

    func read() throws -> Bool? {
        let result = try command(["read", suite, "TouchIDToAutoFill"])
        if result.0 != 0 { return nil }
        try expect(result.1 == "0" || result.1 == "1", "Unexpected isolated preference")
        return result.1 == "1"
    }

    func window(_ expirations: Expirations) -> TouchIDPreferenceWindow {
        TouchIDPreferenceWindow(directory: directory, suite: suite) { expirations.append($0) }
    }

    func guardPID() throws -> pid_t {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(getpid()), "-f", suite]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let pids = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        guard process.terminationStatus == 0, pids.count == 1, let pid = pid_t(pids[0]) else {
            throw TestFailure(message: "Expected one guard for the isolated preference suite")
        }
        return pid
    }
}

if arguments.first == "--crash-parent", arguments.count == 3 {
    let window = TouchIDPreferenceWindow(directory: URL(fileURLWithPath: arguments[1]), suite: arguments[2]) { _ in }
    Task {
        do {
            try await window.begin("crash")
            try FileHandle.standardOutput.write(contentsOf: Data("ARMED\n".utf8))
        } catch { exit(1) }
    }
    RunLoop.main.run()
    exit(1)
}

func normalRestoration() async throws {
    for original: Bool? in [true, false, nil] {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.set(original)
        let events = Expirations(), window = fixture.window(events)
        try await window.recover()
        try await window.begin("normal")
        let temporary = try fixture.read()
        try expect(temporary == false, "READY must follow a verified false write")
        try await window.end("normal")
        let restored = try fixture.read()
        try expect(restored == original, "end must restore true, false, or absence before it completes")
        try expect(!FileManager.default.fileExists(atPath: fixture.journal.path), "Successful restoration must remove journal")
        try expect(!events.contains("normal"), "A successful window must not expire")
    }
}

func expiration() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.set(true)
    let events = Expirations(), window = fixture.window(events)
    try await window.begin("expire")
    try await Task.sleep(for: .milliseconds(1400))
    do { try await window.end("expire"); throw TestFailure(message: "Expired access was accepted") }
    catch is CocoaError { }
    try expect(events.contains("expire"), "Expiry must identify the access request")
    let restored = try fixture.read()
    try expect(restored == true, "Deadline must restore the isolated preference")
}

func parentCrash() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.set(true)
    let parent = Process(), output = Pipe()
    parent.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    parent.arguments = ["--crash-parent", fixture.directory.path, fixture.suite]
    parent.standardOutput = output
    parent.standardError = FileHandle.nullDevice
    try parent.run()
    defer {
        if parent.isRunning { kill(parent.processIdentifier, SIGKILL); parent.waitUntilExit() }
    }
    var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
    try expect(poll(&descriptor, 1, 5000) > 0, "Crash test parent did not become ready")
    let data = output.fileHandleForReading.availableData
    try expect(String(decoding: data, as: UTF8.self).contains("ARMED"), "Crash test did not open the isolated window")
    kill(parent.processIdentifier, SIGKILL)
    parent.waitUntilExit()
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        if try fixture.read() == true, !FileManager.default.fileExists(atPath: fixture.journal.path) { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw TestFailure(message: "Guard did not restore after parent SIGKILL")
}

func guardCrash() async throws {
    for endImmediately in [false, true] {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.set(true)
        let events = Expirations(), window = fixture.window(events)
        try await window.begin("guard-crash")
        let pid = try fixture.guardPID()
        let temporary = try fixture.read()
        try expect(temporary == false, "Guard crash must occur during the isolated preference window")
        try expect(kill(pid, SIGKILL) == 0, "Could not kill the isolated guard")
        if endImmediately {
            do { try await window.end("guard-crash"); throw TestFailure(message: "A killed guard released access") }
            catch is CocoaError { }
        } else {
            // Recovery must run even when the parent does not call end, begin, or recover.
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if try fixture.read() == true, !FileManager.default.fileExists(atPath: fixture.journal.path) { break }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        let restored = try fixture.read()
        try expect(restored == true, "Parent must restore after guard SIGKILL before end completes")
        try expect(!FileManager.default.fileExists(atPath: fixture.journal.path), "Parent recovery must remove the guard journal")
        try expect(events.contains("guard-crash"), "Guard crash must expire the request")
        if !endImmediately {
            do { try await window.end("guard-crash"); throw TestFailure(message: "Recovered guard crash released access") }
            catch is CocoaError { }
        }
    }
}

func startupFailure() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.set(true)
    try FileManager.default.createDirectory(at: fixture.journal, withIntermediateDirectories: false)
    let window = fixture.window(Expirations())
    do { try await window.begin("bad-journal"); throw TestFailure(message: "Invalid journal was accepted") }
    catch is CocoaError { }
    let restored = try fixture.read()
    try expect(restored == true, "Failed startup must not change the preference")
}

func journalRecovery() async throws {
    for original: Bool? in [true, false, nil] {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.set(false)
        let snapshot: [String: Any] = ["wasPresent": original != nil, "value": original ?? true]
        try JSONSerialization.data(withJSONObject: snapshot).write(to: fixture.journal)
        try await fixture.window(Expirations()).recover()
        let restored = try fixture.read()
        try expect(restored == original, "Recovery must preserve original presence and value")
    }
}

func overlappingGuards() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.set(nil)
    let events = Expirations(), first = fixture.window(events), second = fixture.window(Expirations())
    try await first.begin("first")
    // The second process must wait for the first guard's restoration before it snapshots.
    try await second.begin("second")
    try expect(events.contains("first"), "The second guard must not overlap the first window")
    try await second.end("second")
    let restored = try fixture.read()
    try expect(restored == nil, "Sequential guards must preserve the original absent value")
    do { try await first.end("first"); throw TestFailure(message: "First expired guard was accepted") }
    catch is CocoaError { }
}

func restorationFailure() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.set(true)
    let events = Expirations(), window = fixture.window(events)
    try await window.begin("restore-failure")
    // Corrupt only the isolated recovery journal. The guard must refuse success and retain it.
    try Data("invalid journal".utf8).write(to: fixture.journal)
    do { try await window.end("restore-failure"); throw TestFailure(message: "Failed restoration released access") }
    catch is CocoaError { }
    try expect(events.contains("restore-failure"), "Restoration failure must expire the request")
    try expect(FileManager.default.fileExists(atPath: fixture.journal.path), "Failed restoration must retain journal")
    let snapshot: [String: Any] = ["wasPresent": true, "value": true]
    try JSONSerialization.data(withJSONObject: snapshot).write(to: fixture.journal)
    try await window.recover()
    let restored = try fixture.read()
    try expect(restored == true, "Recovery after restoration failure must work")
}

Task {
    do {
        try await normalRestoration()
        try await expiration()
        try await parentCrash()
        try await guardCrash()
        try await startupFailure()
        try await journalRecovery()
        try await overlappingGuards()
        try await restorationFailure()
        print("Preference guard checks passed: original values, deadline, parent crash, guard crash, startup failure, restore failure, recovery, cross-process lock")
        exit(0)
    } catch {
        let message = (error as? TestFailure)?.message ?? String(describing: error)
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
RunLoop.main.run()

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
        try expect(restored == true, "end must enable protection regardless of the previous value")
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
    // The test helper reaches the vulnerable point: false was written, but no
    // READY or recovery marker exists. The production parent's repair must run.
    let helper = fixture.directory.appendingPathComponent("crash-before-ready")
    try Data("""
    #!/bin/sh
    /usr/bin/defaults write "$5" TouchIDToAutoFill -bool NO
    kill -KILL $$
    """.utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let events = Expirations()
    let window = TouchIDPreferenceWindow(directory: fixture.directory, suite: fixture.suite, executable: helper) { events.append($0) }
    do { try await window.begin("startup-crash"); throw TestFailure(message: "Startup crash was accepted") }
    catch is CocoaError { }
    let restored = try fixture.read()
    try expect(restored == true, "Parent must restore after a crash before READY even with no marker")
    try expect(events.contains("startup-crash"), "Startup crash must expire the request")
    try await window.recover()
}

func journalRecovery() async throws {
    for contents in [Data(), Data("corrupt".utf8), Data(#"{"wasPresent":true,"value":false}"#.utf8)] {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.set(false)
        try contents.write(to: fixture.journal)
        try await fixture.window(Expirations()).recover()
        let restored = try fixture.read()
        try expect(restored == true, "Empty, damaged, and forged recovery files must enable protection")
        try expect(!FileManager.default.fileExists(atPath: fixture.journal.path), "Repair must remove the marker")
    }
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.set(false)
    let window = fixture.window(Expirations())
    try await window.recover()
    let unchanged = try fixture.read()
    try expect(unchanged == false, "Local-only use with no interrupted operation must not change Apple's setting")
    try await window.recover(requireEnabled: true)
    let enabled = try fixture.read()
    try expect(enabled == true, "Required phone mode must repair protection even when the marker is missing")
}

func overlappingGuards() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.set(nil)
    let events = Expirations(), first = fixture.window(events), second = fixture.window(Expirations())
    try await first.begin("first")
    // The second process must wait for the first guard to restore protection.
    try await second.begin("second")
    try expect(events.contains("first"), "The second guard must not overlap the first window")
    try await second.end("second")
    let restored = try fixture.read()
    try expect(restored == true, "Sequential guards must leave protection enabled")
    do { try await first.end("first"); throw TestFailure(message: "First expired guard was accepted") }
    catch is CocoaError { }
}

func markerTamperingDuringAccess() async throws {
    for contents: Data? in [nil, Data("corrupt".utf8), Data(#"{"wasPresent":true,"value":false}"#.utf8)] {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.set(true)
        let window = fixture.window(Expirations())
        try await window.begin("tamper")
        if let contents { try contents.write(to: fixture.journal) }
        else { try FileManager.default.removeItem(at: fixture.journal) }
        try await window.end("tamper")
        let enabled = try fixture.read()
        try expect(enabled == true, "Changing or removing the marker must not weaken restoration")
    }
}

func restorationFailure() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.set(true)
    let events = Expirations(), window = fixture.window(events)
    try await window.begin("restore-failure")
    // Replace the isolated plist with a directory. A verified write must fail.
    let plist = URL(fileURLWithPath: fixture.suite + ".plist")
    try FileManager.default.removeItem(at: plist)
    try FileManager.default.createDirectory(at: plist, withIntermediateDirectories: false)
    do { try await window.end("restore-failure"); throw TestFailure(message: "Failed restoration released access") }
    catch is CocoaError { }
    try expect(events.contains("restore-failure"), "Restoration failure must expire the request")
    do { try await window.begin("blocked"); throw TestFailure(message: "Failed recovery allowed another request") }
    catch is CocoaError { }
    try FileManager.default.removeItem(at: plist)
    try fixture.set(false)
    try await window.recover()
    let enabled = try fixture.read()
    try expect(enabled == true, "Recovery after a failed write must enable protection")
}

@MainActor
func recoveryWhileEndIsPending() async throws {
    let fixture = try Fixture()
    var outputHolder: pid_t = 0
    defer {
        if outputHolder > 0 { kill(outputHolder, SIGKILL) }
        fixture.cleanup()
    }
    try fixture.set(true)
    let helper = fixture.directory.appendingPathComponent("expire-with-open-output")
    // A separate process keeps stdout open after this guard exits. This holds
    // monitor before its final callback while recover sees an exited guard.
    try Data("""
    #!/bin/sh
    /usr/bin/defaults write "$5" TouchIDToAutoFill -bool NO
    /bin/sleep 60 &
    printf '%s' "$!" > "$3/output-holder.pid"
    printf 'READY\\n'
    /bin/cat > /dev/null
    printf 'EXPIRED\\n'
    exit 0
    """.utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let events = Expirations()
    let window = TouchIDPreferenceWindow(directory: fixture.directory, suite: fixture.suite,
                                        executable: helper) { events.append($0) }
    try await window.begin("recover-pending-end")
    let guardPID = try fixture.guardPID()
    let holderText = try String(contentsOf: fixture.directory.appendingPathComponent("output-holder.pid"), encoding: .utf8)
    guard let holder = pid_t(holderText), holder > 0 else { throw TestFailure(message: "Missing output holder") }
    outputHolder = holder
    var completed = false
    var endError: NSError?
    Task { @MainActor in
        do { try await window.end("recover-pending-end") }
        catch { endError = error as NSError }
        completed = true
    }
    let exitDeadline = ContinuousClock.now + .seconds(3)
    while !(events.contains("recover-pending-end") && kill(guardPID, 0) != 0) {
        try expect(ContinuousClock.now < exitDeadline, "Guard did not expire and exit")
        try await Task.sleep(for: .milliseconds(10))
    }
    try expect(!completed, "Test must hold monitor before end completes")
    try await window.recover()
    let restored = try fixture.read()
    try expect(restored == true, "Recovery must enable protection before completing end")
    kill(outputHolder, SIGKILL)
    outputHolder = 0
    let endDeadline = ContinuousClock.now + .seconds(2)
    while !completed && ContinuousClock.now < endDeadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try expect(completed, "Recovery discarded the pending end continuation")
    try expect(endError?.domain == NSCocoaErrorDomain && endError?.code == CocoaError.Code.userCancelled.rawValue,
               "Recovered expired access must end with cancellation")
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
        try await markerTamperingDuringAccess()
        try await restorationFailure()
        try await recoveryWhileEndIsPending()
        print("Preference guard checks passed: safe baseline, forged/missing marker, deadline, parent crash, guard crash, pre-READY crash, restore failure, recovery, pending end recovery, cross-process lock")
        exit(0)
    } catch {
        let message = (error as? TestFailure)?.message ?? String(describing: error)
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
RunLoop.main.run()

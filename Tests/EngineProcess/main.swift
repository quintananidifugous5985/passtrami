import Foundation
import Darwin

@main
struct EngineProcessTests {
    @MainActor
    static func main() async throws {
        let resources = Bundle.main.resourceURL!
        let scenarioURL = resources.appendingPathComponent("scenario")
        let childPIDURL = resources.appendingPathComponent("held-writer-pid")
        let specific = "Full Disk Access is required for iPhone approval."
        let generic = "The password service stopped. Select Unlock to try again."
        let engine = EngineProcess()
        var events: [EngineEvent] = []
        engine.onEvent = { events.append($0) }

        func run(_ scenario: String, expectedCount: Int) async throws -> [EngineEvent] {
            events.removeAll()
            try Data(scenario.utf8).write(to: scenarioURL)
            try engine.start(phoneApprovalRequired: false)
            let deadline = Date().addingTimeInterval(2)
            while events.count < expectedCount && Date() < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            precondition(events.count == expectedCount, "Missing or extra events for \(scenario)")
            precondition(!engine.isRunning, "Exit must follow output for \(scenario)")
            return events
        }

        // Reuse the same controller to also check that restart resets retained errors.
        for _ in 0..<80 {
            let result = try await run("error", expectedCount: 2)
            precondition(result.allSatisfy { $0.state == .error && $0.message == specific },
                         "An immediate exit must keep the specific startup error")
        }
        let fragmented = try await run("fragmented", expectedCount: 2)
        precondition(fragmented.last?.message == specific, "Drain must finish a split JSON event")

        let unspecified = try await run("unspecified", expectedCount: 3)
        precondition(unspecified.last?.message == specific,
                     "An error without a message must not erase the last specific error")

        let recovered = try await run("recovered", expectedCount: 3)
        precondition(recovered[0].message == specific && recovered[1].state == .locked,
                     "State events must retain their stream order")
        precondition(recovered.last?.message == generic, "A later valid state must clear an old error")

        let empty = try await run("empty", expectedCount: 1)
        precondition(empty.last?.message == generic, "A new run must not retain a previous error")

        let started = Date()
        let inherited = try await run("inherited", expectedCount: 2)
        precondition(FileManager.default.fileExists(atPath: childPIDURL.path),
                     "The fixture must leave a writer for the runner to clean up")
        precondition(inherited.last?.message == specific, "An inherited pipe must retain the error")
        precondition(Date().timeIntervalSince(started) < 1,
                     "Exit must not wait for a descendant to close inherited stdout")
        await engine.shutdown()
        print("Engine process tests passed: immediate exit, split output, error recovery, restart, and inherited stdout")
    }
}

import Foundation
import Darwin

enum EngineState: String, Decodable, Sendable {
    case starting, locked, pairing, unlocked, error
}

struct EngineEvent: Decodable, Sendable {
    let type: String
    let state: EngineState?
    let message: String?
    var browserRuntime: BrowserRuntimeStatus? = nil
}

@MainActor
final class EngineProcess {
    var onEvent: ((EngineEvent) -> Void)?
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var pendingOutput = Data()
    private var stopping = false
    // Ignore output and exit callbacks from an earlier child after a restart.
    private var processGeneration = UUID()

    var isRunning: Bool { process?.isRunning == true }

    func start() throws {
        guard !isRunning else { return }
        guard let resources = Bundle.main.resourceURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        let child = Process()
        let generation = UUID()
        processGeneration = generation
        let stdin = Pipe()
        let stdout = Pipe()
        child.executableURL = resources.appendingPathComponent("passtrami-engine")
        child.arguments = [
            "--resources", resources.path,
            "--data-dir", FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/io.zats.Passtrami").path
        ]
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        stopping = false
        pendingOutput.removeAll(keepingCapacity: false)
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { [weak self] in self?.receive(data, generation: generation) }
        }
        child.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.didExit(generation: generation) }
        }
        process = child
        input = stdin
        output = stdout
        do {
            // Queue app-owned access policy before the child can accept requests.
            try writeCommand(["op": "mcp", "enabled": MCPSettings().isEnabled], to: stdin.fileHandleForWriting)
            try child.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            child.terminationHandler = nil
            process = nil
            input = nil
            output = nil
            throw error
        }
    }

    func send(_ operation: String, pin: String? = nil) {
        var command: [String: Any] = ["op": operation]
        if let pin { command["pin"] = pin }
        sendCommand(command)
    }

    func setMCPEnabled(_ enabled: Bool) {
        sendCommand(["op": "mcp", "enabled": enabled])
    }

    private func sendCommand(_ command: [String: Any]) {
        guard isRunning, let input else { return }
        do {
            try writeCommand(command, to: input.fileHandleForWriting)
        } catch {
            reportError("Could not contact the password service.")
        }
    }

    private func writeCommand(_ command: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: command)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    func shutdown() async {
        stopping = true
        guard let child = process else { return }
        send("shutdown")
        // Allow a cancelled runtime install to detach its disk image before exit.
        let deadline = Date().addingTimeInterval(30)
        while child.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if child.isRunning {
            child.terminate()
            let terminationDeadline = Date().addingTimeInterval(4)
            while child.isRunning && Date() < terminationDeadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
    }

    private func receive(_ data: Data, generation: UUID) {
        guard generation == processGeneration, !stopping, !data.isEmpty else { return }
        pendingOutput.append(data)
        guard pendingOutput.count <= 1_048_576 else {
            pendingOutput.removeAll(keepingCapacity: false)
            reportError("The password service sent an invalid response.")
            return
        }
        while let newline = pendingOutput.firstIndex(of: 0x0A) {
            let line = Data(pendingOutput[..<newline])
            pendingOutput.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard let event = try? JSONDecoder().decode(EngineEvent.self, from: line) else {
                reportError("The password service sent an invalid response.")
                continue
            }
            onEvent?(event)
        }
    }

    private func didExit(generation: UUID) {
        guard generation == processGeneration else { return }
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        if !stopping { reportError("The password service stopped. Select Unlock to try again.") }
    }

    private func reportError(_ message: String) {
        onEvent?(EngineEvent(type: "state", state: .error, message: message))
    }
}

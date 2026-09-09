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


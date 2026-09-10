import Darwin
import Foundation

@MainActor
final class EngineChildProcess {
    struct Status { let code: Int32; let signalled: Bool }
    private let pid: pid_t
    private var source: (any DispatchSourceProcess)?
    private var result: Status?
    private var waiters: [CheckedContinuation<Status, Never>] = []
    private var killTask: Task<Void, Never>?
    private let onExit: @MainActor () -> Void
    private var stopping = false

    var isRunning: Bool { result == nil }

    init(executable: URL, arguments: [String], output: FileHandle? = nil,
         inheritedDescriptors: [Int32: Int32] = [:],
         onExit: @escaping @MainActor () -> Void = {}) throws {
        self.onExit = onExit
        // Foundation Process does not expose arbitrary child descriptor mappings.
        // Snapshot the sources above all targets so dup2 ordering cannot overwrite one.
        guard inheritedDescriptors.keys.allSatisfy({ $0 >= 3 && $0 < 64 }) else { throw POSIXError(.EINVAL) }
        let null = Darwin.open("/dev/null", O_RDWR | O_CLOEXEC)
        guard null >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(null) }
        var mappings: [Int32: Int32] = [0: null, 1: output?.fileDescriptor ?? null, 2: null]
        mappings.merge(inheritedDescriptors) { _, new in new }
        var descriptors: [(target: Int32, source: Int32)] = []
        defer { for descriptor in descriptors { Darwin.close(descriptor.source) } }
        for (target, original) in mappings {
            let copy = fcntl(original, F_DUPFD_CLOEXEC, 64)
            guard copy >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            descriptors.append((target, copy))
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        func check(_ status: Int32) throws {
            guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO) }
        }
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        // The engine ignores termination signals while Dispatch handles them. Children
        // must start with their own default dispositions and no inherited blocked signals.
        var signals = sigset_t(), mask = sigset_t()
        sigfillset(&signals)
        sigdelset(&signals, SIGKILL)
        sigdelset(&signals, SIGSTOP)
        sigemptyset(&mask)
        try check(posix_spawnattr_setsigdefault(&attributes, &signals))
        try check(posix_spawnattr_setsigmask(&attributes, &mask))
        try check(posix_spawnattr_setflags(&attributes,
            Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)))
        for descriptor in descriptors {
            try check(posix_spawn_file_actions_adddup2(&actions, descriptor.source, descriptor.target))
            try check(posix_spawn_file_actions_addclose(&actions, descriptor.source))
        }
        var argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        var environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for value in argv { free(value) }
            for value in environment { free(value) }
        }
        guard argv.dropLast().allSatisfy({ $0 != nil }), environment.dropLast().allSatisfy({ $0 != nil }) else {
            throw POSIXError(.ENOMEM)
        }
        var child: pid_t = 0
        try argv.withUnsafeMutableBufferPointer { arguments in
            try environment.withUnsafeMutableBufferPointer { environment in
                try check(posix_spawn(&child, executable.path, &actions, &attributes, arguments.baseAddress!, environment.baseAddress!))
            }
        }
        pid = child
        let source = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .main)
        self.source = source
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                var status: Int32 = 0
                var reaped: pid_t
                repeat { reaped = waitpid(self.pid, &status, 0) } while reaped < 0 && errno == EINTR
                // waitpid status macros are not imported into Swift.
                let signal = status & 0x7f
                self.finished(Status(code: reaped < 0 ? -1 : (signal == 0 ? (status >> 8) & 0xff : signal),
                                     signalled: reaped < 0 || signal != 0))
            }
        }
        source.resume()
    }

    private func finished(_ status: Status) {
        guard result == nil else { return }
        result = status
        source?.cancel()
        source = nil
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
        Darwin.kill(pid, SIGTERM)
        killTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: grace) } catch { return }
            guard let self, self.result == nil else { return }
            Darwin.kill(self.pid, SIGKILL)
        }
    }

    func stop(grace: Duration = .seconds(3)) async {
        beginStop(grace: grace)
        _ = await wait()
    }
}

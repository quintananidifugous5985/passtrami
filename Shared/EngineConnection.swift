import Darwin
import Foundation

struct EngineConnectionError: Error {
    let message: String
}

/// A single request to the app-owned engine. Cancellation shuts down the socket;
/// the request thread keeps ownership of closing its descriptor.
final class EngineConnection: @unchecked Sendable {
    static let applicationBundleIdentifier = "io.zats.Aster"
    static var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(applicationBundleIdentifier)/aster.sock").path
    }

    private let path: String
    private let launchApplication: Bool
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var cancelled = false

    init(path: String = EngineConnection.socketPath, launchApplication: Bool = true,
         timeout: TimeInterval = 1_020) {
        self.path = path
        self.launchApplication = launchApplication
        self.timeout = timeout
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if descriptor >= 0 { _ = Darwin.shutdown(descriptor, SHUT_RDWR) }
        }
    }

    func request(_ payload: Data) throws -> Data {
        let socket = try connectToEngine()
        defer {
            lock.withLock {
                Darwin.close(socket)
                descriptor = -1
            }
        }
        var data = payload
        data.append(0x0A)
        let deadline = now + timeout
        try data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                try wait(socket, events: Int16(POLLOUT), deadline: deadline)
                let count = Darwin.write(socket, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
                if count > 0 { sent += count }
                else if count < 0, errno == EINTR || errno == EAGAIN { continue }
                else { throw EngineConnectionError(message: "Could not send the request to Aster.") }
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            try wait(socket, events: Int16(POLLIN), deadline: deadline)
            let count = Darwin.read(socket, &buffer, buffer.count)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else {
                try checkCancellation()
                throw EngineConnectionError(message: "Aster closed the connection before it sent a response.")
            }
            response.append(contentsOf: buffer.prefix(count))
            guard response.count <= 16 * 1_024 * 1_024 else {
                throw EngineConnectionError(message: "Aster's response was too large.")
            }
            if let newline = response.firstIndex(of: 0x0A) {
                try checkCancellation()
                return Data(response.prefix(upTo: newline))
            }
        }
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func checkCancellation() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }

    private func wait(_ socket: Int32, events: Int16, deadline: TimeInterval) throws {
        while true {
            try checkCancellation()
            let remaining = deadline - now
            guard remaining > 0 else { throw EngineConnectionError(message: "Timed out waiting for Aster.") }
            var item = pollfd(fd: socket, events: events, revents: 0)
            let milliseconds = Int32(min(1_000, max(1, remaining * 1_000)))
            let result = Darwin.poll(&item, 1, milliseconds)
            if result > 0 {
                guard item.revents & Int16(POLLNVAL) == 0 else {
                    throw EngineConnectionError(message: "The connection to Aster is no longer valid.")
                }
                return
            }
            if result < 0, errno != EINTR {
                throw EngineConnectionError(message: "Could not wait for Aster: \(String(cString: strerror(errno))).")
            }
        }
    }

    private func connectSocket(deadline: TimeInterval) throws -> Int32? {
        try checkCancellation()
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw EngineConnectionError(message: "Aster's socket path is too long.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw EngineConnectionError(message: "Could not create a connection to Aster.") }
        var connected = false
        defer {
            if !connected {
                lock.withLock {
                    Darwin.close(socket)
                    descriptor = -1
                }
            }
        }
        try lock.withLock {
            if cancelled { throw CancellationError() }
            descriptor = socket
        }
        var noSignal: Int32 = 1
        guard fcntl(socket, F_SETFD, FD_CLOEXEC) != -1,
              fcntl(socket, F_SETFL, O_NONBLOCK) != -1,
              setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw EngineConnectionError(message: "Could not configure the connection to Aster.")
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        var connectionError: Int32 = result == 0 ? 0 : errno
        if connectionError == EINPROGRESS {
            do { try wait(socket, events: Int16(POLLOUT), deadline: min(deadline, now + 1)) }
            catch is CancellationError { throw CancellationError() }
            catch { return nil }
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(socket, SOL_SOCKET, SO_ERROR, &connectionError, &size) == 0 else {
                throw EngineConnectionError(message: "Could not check the connection to Aster.")
            }
        }
        if connectionError == 0 {
            try checkCancellation()
            connected = true
            return socket
        }
        if [ENOENT, ECONNREFUSED, EAGAIN, EINTR].contains(connectionError) { return nil }
        throw EngineConnectionError(message: "Could not connect to Aster: \(String(cString: strerror(connectionError))).")
    }

    private func connectToEngine() throws -> Int32 {
        let deadline = now + 5
        if let socket = try connectSocket(deadline: deadline) { return socket }
        guard launchApplication else { throw EngineConnectionError(message: "Aster is not running.") }
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launcher.arguments = ["-g", "-b", Self.applicationBundleIdentifier]
        launcher.standardOutput = FileHandle.nullDevice
        launcher.standardError = FileHandle.nullDevice
        do { try launcher.run() }
        catch { throw EngineConnectionError(message: "Could not start Aster.") }
        while now < deadline {
            try checkCancellation()
            if let socket = try connectSocket(deadline: deadline) { return socket }
            if !launcher.isRunning, launcher.terminationStatus != 0 {
                throw EngineConnectionError(message: "Could not open Aster.app. Install and open Aster, then try again.")
            }
            usleep(100_000)
        }
        throw EngineConnectionError(message: "Aster did not become ready within 5 seconds.")
    }
}

import Darwin
import Foundation

private let applicationBundleIdentifier = "io.zats.Aster"

private struct CLIError: Error {
    let message: String
    let exitCode: Int32

    init(_ message: String, exitCode: Int32 = 1) {
        self.message = message
        self.exitCode = exitCode
    }
}

private enum Command {
    case help
    case status
    case get(domain: String, username: String)
    case list(domain: String)

    static func parse(_ arguments: [String]) throws -> Command {
        if arguments == ["--help"] || arguments == ["-h"] || arguments == ["get", "--help"] || arguments == ["list", "--help"] {
            return .help
        }
        if arguments == ["status"] { return .status }
        if arguments.first == "list" {
            guard arguments.count == 2,
                  !arguments[1].hasPrefix("-"),
                  !arguments[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw CLIError("Usage: aster list <domain>", exitCode: 64)
            }
            return .list(domain: arguments[1])
        }
        if arguments.first == "get" {
            guard arguments.count == 3,
                  !arguments[1].hasPrefix("-"),
                  !arguments[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !arguments[2].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw CLIError("Usage: aster get <domain> <username>", exitCode: 64)
            }
            return .get(domain: arguments[1], username: arguments[2])
        }
        throw CLIError("Usage: aster get <domain> <username> | list <domain> | status | --help", exitCode: 64)
    }

    var request: [String: Any] {
        switch self {
        case .help: return [:]
        case .status: return ["op": "status"]
        case let .get(domain, username):
            return ["op": "get", "domain": domain, "username": username]
        case let .list(domain):
            return ["op": "list", "domain": domain]
        }
    }
}

private let help = """
Usage:
  aster get <domain> <username>
  aster list <domain>
  aster status
  aster --help

Aster opens when needed and waits for unlock.
get writes only the password, with no trailing newline.
list writes one username per line.

"""

private func now() -> Double { ProcessInfo.processInfo.systemUptime }

private func systemError(_ code: Int32) -> String {
    String(cString: strerror(code))
}

private func waitForSocket(_ descriptor: Int32, events: Int16, deadline: Double) throws {
    while true {
        let remaining = deadline - now()
        guard remaining > 0 else { throw CLIError("Timed out waiting for Aster.") }
        var item = pollfd(fd: descriptor, events: events, revents: 0)
        let milliseconds = Int32(min(1_000, max(1, remaining * 1_000)))
        let result = Darwin.poll(&item, 1, milliseconds)
        if result > 0 {
            guard item.revents & Int16(POLLNVAL) == 0 else {
                throw CLIError("The connection to Aster is no longer valid.")
            }
            return
        }
        if result < 0, errno != EINTR {
            throw CLIError("Could not wait for Aster: \(systemError(errno)).")
        }
    }
}

private func connectSocket(at path: String) throws -> Int32? {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let pathBytes = Array(path.utf8) + [0]
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw CLIError("Aster's socket path is too long.")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.copyBytes(from: pathBytes)
    }

    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw CLIError("Could not create a connection: \(systemError(errno)).")
    }
    var connected = false
    defer { if !connected { Darwin.close(descriptor) } }
    guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) != -1,
          fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else {
        throw CLIError("Could not configure the connection: \(systemError(errno)).")
    }

    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    var connectionError: Int32 = result == 0 ? 0 : errno
    if connectionError == EINPROGRESS {
        do {
            try waitForSocket(descriptor, events: Int16(POLLOUT), deadline: now() + 1)
        } catch {
            return nil
        }
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &connectionError, &size) == 0 else {
            throw CLIError("Could not check the connection: \(systemError(errno)).")
        }
    }
    if connectionError == 0 {
        connected = true
        return descriptor
    }
    if [ENOENT, ECONNREFUSED, EAGAIN, EINTR].contains(connectionError) { return nil }
    throw CLIError("Could not connect to Aster: \(systemError(connectionError)).")
}

private func connectToAster() throws -> Int32 {
    let socketPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/\(applicationBundleIdentifier)/aster.sock").path
    if let descriptor = try connectSocket(at: socketPath) { return descriptor }

    let launcher = Process()
    launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    launcher.arguments = ["-g", "-b", applicationBundleIdentifier]
    launcher.standardOutput = FileHandle.nullDevice
    launcher.standardError = FileHandle.nullDevice
    do {
        try launcher.run()
    } catch {
        throw CLIError("Could not start Aster.")
    }

    let deadline = now() + 30
    while now() < deadline {
        if let descriptor = try connectSocket(at: socketPath) { return descriptor }
        if !launcher.isRunning, launcher.terminationStatus != 0 {
            throw CLIError("Could not open Aster.app. Install and open Aster, then try again.")
        }
        usleep(100_000)
    }
    throw CLIError("Aster did not become ready within 30 seconds.")
}

private func exchange(_ request: [String: Any], on descriptor: Int32) throws -> [String: Any] {
    var data = try JSONSerialization.data(withJSONObject: request)
    data.append(0x0A)
    let deadline = now() + 1_020
    try data.withUnsafeBytes { bytes in
        var sent = 0
        while sent < bytes.count {
            try waitForSocket(descriptor, events: Int16(POLLOUT), deadline: deadline)
            let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
            if count > 0 { sent += count }
            else if count < 0, errno == EINTR || errno == EAGAIN { continue }
            else { throw CLIError("Could not send the request to Aster.") }
        }
    }

    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 8_192)
    while true {
        try waitForSocket(descriptor, events: Int16(POLLIN), deadline: deadline)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count < 0, errno == EINTR || errno == EAGAIN { continue }
        guard count > 0 else { throw CLIError("Aster closed the connection before it sent a response.") }
        response.append(contentsOf: buffer.prefix(count))
        guard response.count <= 16 * 1_024 * 1_024 else {
            throw CLIError("Aster's response was too large.")
        }
        if let newline = response.firstIndex(of: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: response.prefix(upTo: newline)),
                  let result = object as? [String: Any],
                  result["ok"] is Bool
            else { throw CLIError("Aster sent an invalid response.") }
            return result
        }
    }
}

private func writeOutput(_ data: Data, to descriptor: Int32 = STDOUT_FILENO) throws {
    try data.withUnsafeBytes { bytes in
        var sent = 0
        while sent < bytes.count {
            let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
            if count > 0 { sent += count }
            else if count < 0, errno == EINTR { continue }
            else { throw CLIError("Could not write output.") }
        }
    }
}

private func commandOutput(_ command: Command, response: [String: Any]) throws -> Data {
    guard response["ok"] as? Bool == true else {
        throw CLIError(response["message"] as? String ?? "The Aster request failed.")
    }
    switch command {
    case .help: return Data(help.utf8)
    case .status:
        guard let state = response["state"] as? String else {
            throw CLIError("Aster's response has no state.")
        }
        return Data((state + "\n").utf8)
    case .get:
        guard let password = response["password"] as? String else {
            throw CLIError("Aster's response has no password.")
        }
        return Data(password.utf8)
    case .list:
        guard let usernames = response["usernames"] as? [String] else {
            throw CLIError("Aster's response has no account list.")
        }
        guard usernames.allSatisfy({ !$0.contains(where: { $0.isNewline }) }) else {
            throw CLIError("Aster's response has an invalid username.")
        }
        return Data(usernames.map { $0 + "\n" }.joined().utf8)
    }
}

private func run() throws {
    let command = try Command.parse(Array(CommandLine.arguments.dropFirst()))
    if case .help = command {
        try writeOutput(Data(help.utf8))
        return
    }
    let descriptor = try connectToAster()
    defer { Darwin.close(descriptor) }
    let response = try exchange(command.request, on: descriptor)
    try writeOutput(commandOutput(command, response: response))
    if case .status = command, response["state"] as? String == "error" {
        throw CLIError(response["message"] as? String ?? "The password service could not connect.")
    }
}

#if !ASTER_CLI_TEST
signal(SIGPIPE, SIG_IGN)
signal(SIGINT) { _ in Darwin._exit(130) }

do {
    try run()
} catch {
    let failure = error as? CLIError ?? CLIError("The request could not be completed.")
    try? writeOutput(Data(("aster: " + failure.message + "\n").utf8), to: STDERR_FILENO)
    Darwin.exit(failure.exitCode)
}
#endif

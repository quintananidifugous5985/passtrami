import Darwin
import Foundation

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
    let data: Data
    do {
        data = try EngineConnection().request(JSONSerialization.data(withJSONObject: command.request))
    } catch let error as EngineConnectionError {
        throw CLIError(error.message)
    }
    guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          response["ok"] is Bool else {
        throw CLIError("Aster sent an invalid response.")
    }
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


private func expect(_ condition: Bool) throws {
    if !condition { throw CLIError("CLI test assertion failed.") }
}

private func expectError(exitCode: Int32 = 1, _ operation: () throws -> Void) throws {
    do {
        try operation()
    } catch let error as CLIError {
        try expect(error.exitCode == exitCode)
        return
    }
    throw CLIError("Expected a CLI error.")
}

do {
    for arguments in [["--help"], ["-h"], ["get", "--help"], ["list", "--help"]] {
        guard case .help = try Command.parse(arguments) else { throw CLIError("Help was not recognized.") }
    }
    let get = try Command.parse(["get", "example.com", "person@example.com"])
    try expect(NSDictionary(dictionary: get.request).isEqual(to: [
        "op": "get", "domain": "example.com", "username": "person@example.com"
    ]))
    let list = try Command.parse(["list", "example.com"])
    try expect(NSDictionary(dictionary: list.request).isEqual(to: ["op": "list", "domain": "example.com"]))
    try expect(NSDictionary(dictionary: Command.parse(["status"]).request).isEqual(to: ["op": "status"]))

    for arguments in [
        [], ["get"], ["get", "example.com"], ["get", "example.com", "person", "extra"],
        ["get", " ", "person"], ["get", "example.com", " "], ["get", "-domain", "person"],
        ["list"], ["list", "example.com", "extra"], ["list", " "], ["list", "-domain"],
        ["get", "example.com", "person", "--json"], ["list", "example.com", "--json"]
    ] {
        try expectError(exitCode: 64) { _ = try Command.parse(arguments) }
    }

    let password = "sample-value"
    try expect(try commandOutput(get, response: ["ok": true, "password": password]) == Data(password.utf8))
    try expect(try commandOutput(list, response: ["ok": true,
        "usernames": ["first@example.com", "second@example.com"], "password": "must-not-be-output"
    ]) == Data("first@example.com\nsecond@example.com\n".utf8))
    try expect(try commandOutput(list, response: ["ok": true, "usernames": []]) == Data())
    try expect(try commandOutput(.status, response: ["ok": true, "state": "locked"]) == Data("locked\n".utf8))

    for response: [String: Any] in [
        ["ok": true], ["ok": true, "usernames": "invalid"],
        ["ok": true, "usernames": [42]],
        ["ok": true, "usernames": ["first\nsecond"]]
    ] {
        try expectError { _ = try commandOutput(list, response: response) }
    }
    try expectError { _ = try commandOutput(get, response: ["ok": true]) }
    try expectError { _ = try commandOutput(.status, response: ["ok": true]) }
    try expectError { _ = try commandOutput(list, response: ["ok": false, "message": "Request cancelled."]) }
    print("CLI argument and output checks passed.")
} catch {
    fputs("CLI checks failed.\n", stderr)
    Darwin.exit(1)
}

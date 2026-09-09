import Foundation

/// Test-only executable. The production helper has no socket override.
@main
enum MCPHarness {
    static func main() async throws {
        precondition((2...3).contains(CommandLine.arguments.count))
        if CommandLine.arguments.last == "--cancellation-race" {
            try await cancellationRace(path: CommandLine.arguments[1])
            return
        }
        try await CredentialServer.run(backend: EngineBackend(path: CommandLine.arguments[1], launchApplication: false))
    }

    private static func cancellationRace(path: String) async throws {
        let ready = AsyncStream<Void>.makeStream()
        let backend = EngineBackend(path: path, launchApplication: false, exchange: { _, _ in
            ready.continuation.yield(())
            // Model an I/O operation that reports EPIPE instead of CancellationError
            // after its socket is shut down by the cancellation handler.
            do { try await Task.sleep(for: .seconds(5)) } catch {}
            throw EngineConnectionError(message: "Simulated socket shutdown")
        })
        let request = Task { try await backend.request("mcp_prepare", arguments: ["domain": "example.com", "username": "person"]) }
        var iterator = ready.stream.makeAsyncIterator()
        _ = await iterator.next()
        request.cancel()
        do {
            _ = try await request.value
            throw CredentialAccessError.failed
        } catch is CancellationError {
            print("Cancellation race check passed.")
        }
    }
}

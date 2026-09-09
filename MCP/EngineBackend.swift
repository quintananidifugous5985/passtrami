import Foundation

/// Only these engine fields can enter MCP responses. Unknown fields are discarded
/// by Decodable; engine messages and credential values are never decoded.
struct MCPMetadata: Decodable, Sendable {
    let ok: Bool
    let code: String?
    let enabled: Bool?
    let state: String?
    let usernames: [String]?
    let lease_id: String?
    let path: String?
    let expires_at: String?
    let format: String?
    let single_use: Bool?
}

enum CredentialAccessError: Error {
    case disabled, unavailable, invalidResponse, failed

    var message: String {
        switch self {
        case .disabled: "Enable MCP in Aster Settings."
        case .unavailable: "Could not connect to Aster. Open the app and try again."
        case .invalidResponse: "Aster returned an invalid response."
        case .failed: "The credential request failed. Check Aster and try again."
        }
    }
}

actor EngineBackend {
    typealias Exchange = @Sendable (EngineConnection, Data) async throws -> Data
    private let path: String
    private let launchApplication: Bool
    private let exchange: Exchange
    private var session = UUID().uuidString
    private var connections: [UUID: EngineConnection] = [:]
    private var closed = false

    init(path: String = EngineConnection.socketPath, launchApplication: Bool = true,
         exchange: @escaping Exchange = { connection, payload in
             try await Task.detached { try connection.request(payload) }.value
         }) {
        self.path = path
        self.launchApplication = launchApplication
        self.exchange = exchange
    }

    func request(_ operation: String, arguments: [String: String] = [:]) async throws -> MCPMetadata {
        guard !closed else { throw CancellationError() }
        try Task.checkCancellation()
        let requestSession = session
        var request = arguments
        request["op"] = operation
        if operation == "mcp_prepare" || operation == "mcp_revoke" { request["session"] = requestSession }
        let payload = try JSONEncoder().encode(request)
        let id = UUID()
        let connection = EngineConnection(path: path, launchApplication: launchApplication)
        connections[id] = connection
        defer { connections.removeValue(forKey: id) }
        do {
            let data = try await withTaskCancellationHandler {
                try await exchange(connection, payload)
            } onCancel: {
                connection.cancel()
            }
            try Task.checkCancellation()
            guard !closed, session == requestSession else { throw CancellationError() }
            let response: MCPMetadata
            do { response = try JSONDecoder().decode(MCPMetadata.self, from: data) }
            catch { throw CredentialAccessError.invalidResponse }
            guard response.ok else {
                throw response.code == "mcp_disabled" ? CredentialAccessError.disabled : CredentialAccessError.failed
            }
            return response
        } catch {
            // Socket shutdown may produce EPIPE or another I/O error before the
            // transport can observe cancellation. It must still revoke leases.
            if error is CancellationError || Task.isCancelled {
                await cancelSession(requestSession)
                throw CancellationError()
            }
            if let error = error as? CredentialAccessError { throw error }
            throw CredentialAccessError.unavailable
        }
    }

    func close() async {
        guard !closed else { return }
        closed = true
        await cancelSession(session)
    }

    private func cancelSession(_ oldSession: String) async {
        guard session == oldSession else { return }
        session = UUID().uuidString
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        let socketPath = path
        // A disconnected client must not start the app just to release a lease.
        await Task.detached {
            let connection = EngineConnection(path: socketPath, launchApplication: false, timeout: 2)
            guard let payload = try? JSONEncoder().encode(["op": "mcp_close", "session": oldSession]) else { return }
            _ = try? connection.request(payload)
        }.value
    }
}

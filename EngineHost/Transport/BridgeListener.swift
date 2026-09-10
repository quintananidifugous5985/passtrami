import Foundation
import Network

@MainActor
// Carries extension messages over loopback. SessionScript authenticates each connection.
final class BridgeListener {
    private struct Client {
        let connection: NWConnection
        var opened = false
        var authenticationDeadline: Task<Void, Never>?
    }

    private let onOpen: @MainActor (String) -> Void
    private let onText: @MainActor (String, String) -> Void
    private let onClose: @MainActor (String) -> Void
    private let connectionLimit: Int
    private let authenticationTimeout: Duration
    private var listener: NWListener?
    private var startup: CheckedContinuation<UInt16, any Error>?
    private var clients: [String: Client] = [:]
    private var closed = false

    init(connectionLimit: Int = 4, authenticationTimeout: Duration = .seconds(5),
         onOpen: @escaping @MainActor (String) -> Void,
         onText: @escaping @MainActor (String, String) -> Void,
         onClose: @escaping @MainActor (String) -> Void) {
        precondition(connectionLimit > 0 && authenticationTimeout > .zero)
        self.connectionLimit = connectionLimit
        self.authenticationTimeout = authenticationTimeout
        self.onOpen = onOpen
        self.onText = onText
        self.onClose = onClose
    }

    func start() async throws -> UInt16 {
        guard !closed, listener == nil else { throw EngineFailure("bridge", "The extension listener cannot start again.") }
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.maximumMessageSize = 1_048_576
        options.setClientRequestHandler(.main) { _, _ in .init(status: .accept, subprotocol: nil) }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.acceptLocalOnly = true
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                self.accept(connection)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.stateChanged(state) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startup = continuation
                if Task.isCancelled { close() }
                else { listener.start(queue: .main) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.close() }
        }
    }

    func send(id: String, text: String) {
        guard let client = clients[id], client.opened else { return }
        let data = Data(text.utf8)
        guard data.count <= 1_048_576 else { disconnect(id: id); return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "passtrami", metadata: [metadata])
        client.connection.send(content: data, contentContext: context, isComplete: true,
                               completion: .contentProcessed { [weak self] error in
            if error != nil { MainActor.assumeIsolated { self?.disconnect(id: id) } }
        })
    }

    // SessionScript calls this only after validating the current browser token.
    func authenticated(id: String) {
        guard let client = clients[id], client.opened else { return }
        clients[id]?.authenticationDeadline = nil
        client.authenticationDeadline?.cancel()
    }

    func disconnect(id: String) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.authenticationDeadline?.cancel()
        client.connection.cancel()
        if client.opened { onClose(id) }
    }

    func close() {
        guard !closed else { return }
        closed = true
        let continuation = startup
        startup = nil
        continuation?.resume(throwing: EngineFailure("cancelled", "The extension listener closed."))
        listener?.cancel()
        listener = nil
        for id in Array(clients.keys) { disconnect(id: id) }
    }

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue else { close(); return }
            let continuation = startup
            startup = nil
            continuation?.resume(returning: port)
        case .failed:
            let continuation = startup
            startup = nil
            continuation?.resume(throwing: EngineFailure("bridge", "Could not listen for the password extension."))
            close()
        case .cancelled: close()
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !closed, clients.count < connectionLimit else { connection.cancel(); return }
        let id = UUID().uuidString
        // Start before the WebSocket upgrade, so an incomplete HTTP handshake
        // cannot retain a connection without reaching SessionScript's token check.
        let expires = ContinuousClock.now + authenticationTimeout
        let deadline = Task { [weak self] in
            do { try await Task.sleep(until: expires, clock: .continuous) } catch { return }
            guard !Task.isCancelled else { return }
            self?.disconnect(id: id)
        }
        clients[id] = Client(connection: connection, authenticationDeadline: deadline)
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, let client = self.clients[id] else { return }
                switch state {
                case .ready:
                    guard !client.opened else { return }
                    self.clients[id]?.opened = true
                    self.onOpen(id)
                    self.receive(id)
                case .failed, .cancelled: self.disconnect(id: id)
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func receive(_ id: String) {
        guard let client = clients[id], client.opened else { return }
        client.connection.receiveMessage { [weak self] data, context, complete, error in
            MainActor.assumeIsolated {
                guard let self, self.clients[id] != nil else { return }
                guard error == nil, complete,
                      let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata else {
                    self.disconnect(id: id)
                    return
                }
                switch metadata.opcode {
                case .text:
                    let data = data ?? Data()
                    guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else {
                        self.disconnect(id: id)
                        return
                    }
                    self.onText(id, text)
                case .ping, .pong: break
                default: self.disconnect(id: id); return
                }
                self.receive(id)
            }
        }
    }
}

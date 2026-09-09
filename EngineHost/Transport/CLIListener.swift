import Darwin
import Foundation

@MainActor
// One newline-delimited request and response per connection; disconnect cancels pending work.
final class CLIListener {
    private final class Client {
        let descriptor: Int32
        var readSource: DispatchSourceRead?
        var writeSource: DispatchSourceWrite?
        var sourceCount = 0
        var input = Data()
        var output = Data()
        var outputOffset = 0
        var receivedRequest = false
        var replying = false

        init(_ descriptor: Int32) { self.descriptor = descriptor }

        func sourceCancelled() {
            sourceCount -= 1
            if sourceCount == 0 { Darwin.close(descriptor) }
        }
    }

    private let path: String
    private let onRequest: @MainActor (String, String) -> Void
    private let onDisconnect: @MainActor (String) -> Void
    private let onFinish: @MainActor (String, Bool) -> Void
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private var clients: [String: Client] = [:]

    init(path: String, onRequest: @escaping @MainActor (String, String) -> Void,
         onDisconnect: @escaping @MainActor (String) -> Void,
         onFinish: @escaping @MainActor (String, Bool) -> Void = { _, _ in }) throws {
        self.path = path
        self.onRequest = onRequest
        self.onDisconnect = onDisconnect
        self.onFinish = onFinish

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw EngineFailure("socket", "Aster's socket path is too long.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }

        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFSOCK, unlink(path) == 0 else {
                throw EngineFailure("socket", "Could not remove Aster's old socket.")
            }
        } else if errno != ENOENT {
            throw EngineFailure("socket", "Could not inspect Aster's socket.")
        }

        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw EngineFailure("socket", "Could not create Aster's socket.") }
        var ready = false
        defer { if !ready { Darwin.close(socket) } }
        guard Self.configure(socket) else { throw EngineFailure("socket", "Could not configure Aster's socket.") }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw EngineFailure("socket", "Could not bind Aster's socket.") }
        guard chmod(path, 0o600) == 0, Darwin.listen(socket, 128) == 0 else {
            unlink(path)
            throw EngineFailure("socket", "Could not listen on Aster's socket.")
        }
        descriptor = socket
        let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.acceptClients() } }
        source.setCancelHandler { Darwin.close(socket) }
        self.source = source
        ready = true
        source.resume()
    }

    func reply(id: String, json: String) {
        guard let client = clients[id], client.receivedRequest, !client.replying else { return }
        client.replying = true
        client.output = Data((json + "\n").utf8)
        flush(id)
    }

    func disconnect(id: String) {
        finish(id, cancelled: true)
    }

    func close() {
        guard descriptor >= 0 else { return }
        descriptor = -1
        source?.cancel()
        source = nil
        unlink(path)
        for id in Array(clients.keys) { finish(id, cancelled: true) }
    }

    private static func configure(_ descriptor: Int32) -> Bool {
        var noSignal: Int32 = 1
        return fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0
            && fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0
            && setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    private func acceptClients() {
        while descriptor >= 0 {
            let accepted = Darwin.accept(descriptor, nil, nil)
            if accepted < 0 {
                if errno == EINTR || errno == ECONNABORTED || errno == EINVAL { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { close() }
                return
            }
            guard Self.configure(accepted) else { Darwin.close(accepted); continue }
            let id = UUID().uuidString
            let client = Client(accepted)
            clients[id] = client
            let source = DispatchSource.makeReadSource(fileDescriptor: accepted, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.read(id) } }
            source.setCancelHandler { MainActor.assumeIsolated { client.sourceCancelled() } }
            client.readSource = source
            client.sourceCount += 1
            source.resume()
        }
    }

    private func read(_ id: String) {
        guard let client = clients[id] else { return }
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while clients[id] === client {
            let count = Darwin.read(client.descriptor, &buffer, buffer.count)
            if count == 0 { finish(id, cancelled: true); return }
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { finish(id, cancelled: true) }
                return
            }
            guard !client.receivedRequest else { finish(id, cancelled: true); return }
            client.input.append(contentsOf: buffer.prefix(count))
            guard client.input.count <= 65_536 else { finish(id, cancelled: true); return }
            if let newline = client.input.firstIndex(of: 0x0A) {
                guard newline == client.input.index(before: client.input.endIndex),
                      let text = String(data: client.input.prefix(upTo: newline), encoding: .utf8) else {
                    finish(id, cancelled: true)
                    return
                }
                client.receivedRequest = true
                client.input.removeAll(keepingCapacity: false)
                onRequest(id, text)
            }
        }
    }

    private func flush(_ id: String) {
        guard let client = clients[id] else { return }
        while client.outputOffset < client.output.count {
            let count = client.output.withUnsafeBytes { bytes in
                Darwin.write(client.descriptor, bytes.baseAddress!.advanced(by: client.outputOffset), bytes.count - client.outputOffset)
            }
            if count > 0 { client.outputOffset += count; continue }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                if client.writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: client.descriptor, queue: .main)
                    source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.flush(id) } }
                    source.setCancelHandler { MainActor.assumeIsolated { client.sourceCancelled() } }
                    client.writeSource = source
                    client.sourceCount += 1
                    source.resume()
                }
                return
            }
            finish(id, cancelled: true)
            return
        }
        finish(id, cancelled: false)
    }

    private func finish(_ id: String, cancelled: Bool) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.readSource?.cancel()
        client.writeSource?.cancel()
        client.input.removeAll(keepingCapacity: false)
        client.output.removeAll(keepingCapacity: false)
        if cancelled && client.receivedRequest && !client.replying { onDisconnect(id) }
        onFinish(id, !cancelled)
    }
}

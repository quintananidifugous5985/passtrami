import Darwin
import Foundation

@MainActor
// Plaintext stays in engine memory and goes only to a FIFO reader, never to MCP.
final class PasswordPipes {
    private struct Lease {
        let session: String
        let path: String
        let device: dev_t
        let inode: ino_t
        var bytes: Data
        let expires: ContinuousClock.Instant
    }

    private let directory: URL
    private let lifetime: Duration
    private let limit: Int
    private var leases: [String: Lease] = [:]
    private var timer: Task<Void, Never>?

    init(directory: URL, lifetime: Duration = .seconds(60), limit: Int = 16) throws {
        self.directory = directory
        self.lifetime = lifetime
        self.limit = limit
        var info = stat()
        if lstat(directory.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
                throw EngineFailure("pipe_directory", "The password pipe directory is not private.")
            }
            // Engine restarts remove stale FIFOs. Never follow links or remove other files.
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
                let path = directory.appendingPathComponent(name).path
                var stale = stat()
                guard UUID(uuidString: name) != nil,
                      lstat(path, &stale) == 0, stale.st_mode & S_IFMT == S_IFIFO, stale.st_uid == getuid() else { continue }
                _ = unlink(path)
            }
        } else {
            guard errno == ENOENT, mkdir(directory.path, 0o700) == 0 else {
                throw EngineFailure("pipe_directory", "Could not create the password pipe directory.")
            }
        }
    }

    var count: Int { leases.count }

    func create(password: String, session: String) throws -> [String: Any] {
        guard leases.count < limit else {
            throw EngineFailure("pipe_limit", "Too many unused password pipes. Read or revoke a pipe first.")
        }
        var bytes = Data(password.utf8)
        // A single atomic write makes a partial credential impossible for the intended reader.
        guard !bytes.isEmpty, bytes.count <= Int(PIPE_BUF) else {
            bytes.resetBytes(in: 0..<bytes.count)
            throw EngineFailure("password_size", "The password is too large for a single pipe delivery.")
        }
        let id = UUID().uuidString
        let path = directory.appendingPathComponent(id).path
        guard mkfifo(path, 0o600) == 0 else {
            bytes.resetBytes(in: 0..<bytes.count)
            throw EngineFailure("pipe_create", "Could not create the password pipe.")
        }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFIFO,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600 else {
            _ = unlink(path)
            bytes.resetBytes(in: 0..<bytes.count)
            throw EngineFailure("pipe_create", "Could not secure the password pipe.")
        }
        leases[id] = Lease(session: session, path: path, device: info.st_dev, inode: info.st_ino,
                           bytes: bytes, expires: .now + lifetime)
        if timer == nil {
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(25)) } catch { break }
                    guard let self else { break }
                    self.poll()
                }
            }
        }
        let seconds = Double(lifetime.components.seconds) + Double(lifetime.components.attoseconds) / 1e18
        return ["lease_id": id, "path": path, "expires_at": Date().addingTimeInterval(seconds).ISO8601Format(),
                "format": "utf8", "single_use": true]
    }

    func revoke(_ id: String, session: String) {
        guard leases[id]?.session == session else { return }
        remove(id)
    }

    func revoke(session: String) {
        for id in leases.keys.filter({ leases[$0]?.session == session }) { remove(id) }
    }

    func revokeAll() {
        for id in Array(leases.keys) { remove(id) }
    }

    private func poll() {
        for (id, lease) in leases {
            if ContinuousClock.now >= lease.expires { remove(id); continue }
            var pathInfo = stat()
            guard lstat(lease.path, &pathInfo) == 0, matches(pathInfo, lease) else { remove(id); continue }
            // ENXIO means no reader yet. A nonblocking writer never stalls the engine.
            let descriptor = open(lease.path, O_WRONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                if errno != ENXIO && errno != EINTR { remove(id) }
                continue
            }
            var info = stat()
            guard fstat(descriptor, &info) == 0, matches(info, lease) else {
                Darwin.close(descriptor)
                remove(id)
                continue
            }
            // Unlink before writing so another reader cannot open this pipe later.
            _ = unlink(lease.path)
            guard fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else {
                Darwin.close(descriptor)
                remove(id)
                continue
            }
            _ = lease.bytes.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress, buffer.count)
            }
            // A closed reader or write error consumes the lease without retrying.
            Darwin.close(descriptor)
            remove(id)
        }
    }

    private func matches(_ info: stat, _ lease: Lease) -> Bool {
        info.st_mode & S_IFMT == S_IFIFO && info.st_uid == getuid()
            && info.st_mode & 0o777 == 0o600 && info.st_dev == lease.device && info.st_ino == lease.inode
    }

    private func remove(_ id: String) {
        guard var lease = leases.removeValue(forKey: id) else { return }
        var info = stat()
        if lstat(lease.path, &info) == 0, matches(info, lease) {
            // Unlink alone cannot release a reader blocked in open(). Hold a writer
            // while removing the name, then close without bytes so that reader gets EOF.
            let descriptor = open(lease.path, O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            var opened = stat()
            if descriptor >= 0, fstat(descriptor, &opened) == 0, matches(opened, lease) {
                _ = unlink(lease.path)
            } else if descriptor < 0 {
                _ = unlink(lease.path)
            }
            if descriptor >= 0 { Darwin.close(descriptor) }
        }
        lease.bytes.resetBytes(in: 0..<lease.bytes.count)
        if leases.isEmpty { timer?.cancel(); timer = nil }
    }
}

import Darwin
import Foundation

final class EngineInstanceLock {
    private let descriptor: Int32

    init(directory: URL) throws {
        let path = directory.appendingPathComponent("engine.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw EngineFailure("engine_lock", "Could not open the password service lock.")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK {
                throw EngineFailure("already_running", "The password service is already running.")
            }
            throw EngineFailure("engine_lock", "Could not lock the password service.")
        }
        self.descriptor = descriptor
    }

    deinit {
        // Leave the file in place: unlinking it would let another process lock a different inode.
        close(descriptor)
    }
}

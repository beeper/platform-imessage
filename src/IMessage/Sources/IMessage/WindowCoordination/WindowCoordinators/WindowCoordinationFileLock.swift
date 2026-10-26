import Darwin
import Foundation

/// A per-user lock shared by independent hosts. Keep its inode after release so
/// existing waiters and later openers always coordinate through the same file.
final class WindowCoordinationFileLock {
    private let descriptor: Int32

    init(name: String, wait: Bool = true) throws {
        guard !name.isEmpty, name.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        let path = "/private/tmp/beeper-imessage-\(name)-\(getuid()).lock"
        let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw Self.posixError() }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw Self.posixError() }
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
            }
            let operation = wait ? LOCK_EX : LOCK_EX | LOCK_NB
            while flock(descriptor, operation) != 0 {
                if errno == EINTR { continue }
                if !wait && errno == EWOULDBLOCK { throw WindowCoordinatorError.instanceInUse }
                throw Self.posixError()
            }
        } catch {
            close(descriptor)
            throw error
        }
        self.descriptor = descriptor
    }

    deinit {
        while flock(descriptor, LOCK_UN) != 0 && errno == EINTR {}
        close(descriptor)
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

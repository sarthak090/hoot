import Darwin
import Foundation
import Security

/// Files shared between the app and the hook script, all inside a directory only this
/// user can open. The directory's permissions are what stop other local users from
/// impersonating Hoot or reading the token.
enum PrivateFiles {
    static let directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Hoot", isDirectory: true)
    static var socket: URL { directory.appendingPathComponent("hoot.sock") }
    /// `Authorization: Bearer <token>`, read by curl with `-H @file` so the token never
    /// appears in a process's arguments.
    static var authHeader: URL { directory.appendingPathComponent("auth-header") }
    /// `wait=<seconds>` for the permission hook.
    static var hookConfig: URL { directory.appendingPathComponent("hook.conf") }
    static var lock: URL { directory.appendingPathComponent("hoot.lock") }

    enum Failure: LocalizedError {
        case unsafeDirectory(String)
        case io(String)
        case alreadyRunning
        case socketPathTooLong

        var errorDescription: String? {
            switch self {
            case .unsafeDirectory(let why): "Hoot's private folder is not safe to use: \(why)"
            case .io(let why): why
            case .alreadyRunning: "Hoot is already running."
            case .socketPathTooLong: "The socket path is longer than macOS allows (104 bytes)."
            }
        }
    }

    /// Creates the directory with 0700, or verifies an existing one is a real directory we own,
    /// and tightens its mode if needed.
    static func prepareDirectory() throws {
        let path = directory.path
        if mkdir(path, 0o700) != 0 && errno != EEXIST {
            // Parent may be missing on a fresh account.
            try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard mkdir(path, 0o700) == 0 || errno == EEXIST else { throw Failure.io("mkdir failed: \(String(cString: strerror(errno)))") }
        }
        var st = stat()
        guard lstat(path, &st) == 0 else { throw Failure.io("stat failed") }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw Failure.unsafeDirectory("not a directory (symlink?)") }
        guard st.st_uid == getuid() else { throw Failure.unsafeDirectory("owned by another user") }
        if st.st_mode & 0o777 != 0o700, chmod(path, 0o700) != 0 {
            throw Failure.unsafeDirectory("could not set permissions to 0700")
        }
        guard socket.path.utf8.count < 104 else { throw Failure.socketPathTooLong }
    }

    /// Holds an exclusive lock for the app's lifetime so a second copy can't steal the socket.
    /// Written once during startup on the main thread and never read afterwards.
    nonisolated(unsafe) private static var lockFD: Int32 = -1

    static func acquireSingleInstanceLock() throws {
        let fd = open(lock.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.io("could not open lock file") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw Failure.alreadyRunning
        }
        lockFD = fd
    }

    /// A fresh 256-bit token on every launch. Returns the full header line the server expects.
    static func rotateToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw Failure.io("could not generate a random token")
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try writePrivate("Authorization: Bearer \(token)\n", to: authHeader)
        return "Bearer \(token)"
    }

    static func writeHookConfig(waitSeconds: Int) throws {
        try writePrivate("wait=\(waitSeconds)\n", to: hookConfig)
    }

    /// Writes a 0600 file atomically: temp file created exclusively, then renamed into place.
    static func writePrivate(_ text: String, to url: URL) throws {
        let tmp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.io("could not create \(tmp.lastPathComponent)") }
        let data = Array(text.utf8)
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == data.count, rename(tmp.path, url.path) == 0 else {
            unlink(tmp.path)
            throw Failure.io("could not write \(url.lastPathComponent)")
        }
    }

    /// Removes a leftover socket from a previous run (only if it really is a socket).
    static func removeStaleSocket() {
        var st = stat()
        if lstat(socket.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid() {
            unlink(socket.path)
        }
    }
}

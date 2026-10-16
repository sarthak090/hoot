import Darwin
import Foundation
import HootCore

/// Watches one session transcript for the result of a pending tool call, so a request
/// answered in the terminal disappears from the menu bar.
final class TranscriptWatcher: @unchecked Sendable {
    static let backlogBytes: off_t = 512 * 1024
    static let maxLineBytes = 32 * 1024 * 1024

    private let queue = DispatchQueue(label: "hoot.transcript")
    private let onAnswered: @Sendable () -> Void
    // Confined to `queue`.
    private var matcher: TranscriptMatcher
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var offset: off_t = 0
    private var partial = Data()
    private var done = false

    /// Returns nil if the path isn't a transcript under ~/.claude/projects.
    init?(transcriptPath: String, toolName: String, toolInput: JSONValue?, onAnswered: @escaping @Sendable () -> Void) {
        guard Self.isAllowed(transcriptPath) else { return nil }
        matcher = TranscriptMatcher(toolName: toolName, toolInput: toolInput)
        self.onAnswered = onAnswered
        queue.async { self.open(transcriptPath) }
    }

    static func isAllowed(_ path: String) -> Bool {
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true).resolvingSymlinksInPath().path + "/"
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        return resolved.hasPrefix(projects) && resolved.hasSuffix(".jsonl")
    }

    func cancel() {
        queue.async { self.stop() }
    }

    // MARK: - On `queue`

    private func open(_ path: String) {
        fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            Log.attention.debug("transcript not readable")
            return
        }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return stop() }

        let start = max(0, st.st_size - Self.backlogBytes)
        offset = start
        let backlog = readToEnd()
        var lines = backlog.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        // A backlog starting mid-file begins with a partial line.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        matcher.consumeBacklog(lines.map { Substring(decoding: $0, as: UTF8.self) })
        Log.attention.debug("transcript watch started; matched call: \(self.matcher.targetID != nil)")

        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.extend, .write, .delete, .rename, .revoke], queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let events = src.data
            if events.contains(.delete) || events.contains(.rename) || events.contains(.revoke) {
                self.stop()
            } else {
                self.readNewLines()
            }
        }
        let fdToClose = fd
        src.setCancelHandler { Darwin.close(fdToClose) }
        source = src
        src.resume()
        // Catch anything appended between the backlog read and the source starting.
        readNewLines()
    }

    private func readToEnd() -> Data {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = pread(fd, &buf, buf.count, offset)
            guard n > 0 else { break }
            out.append(buf, count: n)
            offset += off_t(n)
        }
        return out
    }

    private func readNewLines() {
        guard !done, fd >= 0 else { return }
        var st = stat()
        if fstat(fd, &st) == 0, st.st_size < offset {
            // Truncated or rewritten: our position is meaningless now.
            return stop()
        }
        partial.append(readToEnd())
        while let nl = partial.firstIndex(of: UInt8(ascii: "\n")) {
            let line = partial[partial.startIndex..<nl]
            partial.removeSubrange(partial.startIndex...nl)
            if matcher.consumeNew(Substring(decoding: line, as: UTF8.self)) {
                stop()
                onAnswered()
                return
            }
        }
        if partial.count > Self.maxLineBytes { partial.removeAll() }
    }

    private func stop() {
        guard !done else { return }
        done = true
        if let source {
            source.cancel()
        } else if fd >= 0 {
            Darwin.close(fd)
        }
        source = nil
        fd = -1
    }
}

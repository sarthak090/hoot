import Darwin
import Foundation

/// Incrementally indexes usage from transcript files. Each scan reads only bytes
/// appended since the previous one; a half-written last line waits for its newline.
/// Not thread-safe: own it from one actor or queue.
public struct UsageIndex: Sendable {
    struct FileState: Sendable {
        var inode: UInt64
        var offset: UInt64
        var partial: Data
    }

    /// A single line longer than this is dropped instead of buffered forever.
    public static let maxLineBytes = 64 * 1024 * 1024
    static let chunkBytes = 4 * 1024 * 1024

    private var files: [String: FileState] = [:]
    public private(set) var records: [String: UsageRecord] = [:]

    public init() {}

    public struct ScanStats: Sendable, Equatable {
        public var filesRead = 0
        public var bytesRead = 0
        public var malformedOrSkippedLines = 0
    }

    /// Reads new data from every `.jsonl` under `root` modified at or after `since`,
    /// and forgets records older than `since`.
    @discardableResult
    public mutating func scan(root: URL, since: Date) -> ScanStats {
        var stats = ScanStats()
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate, modified >= since
                else { continue }
                read(url, fallbackProject: url.deletingLastPathComponent().lastPathComponent, stats: &stats)
            }
        }
        records = records.filter { $0.value.timestamp >= since }
        // Forget files that disappeared.
        files = files.filter { FileManager.default.fileExists(atPath: $0.key) }
        return stats
    }

    private mutating func read(_ url: URL, fallbackProject: String, stats: inout ScanStats) {
        let path = url.path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return }
        let size = UInt64(st.st_size)
        let inode = UInt64(st.st_ino)

        var state = files[path] ?? FileState(inode: inode, offset: 0, partial: Data())
        if state.inode != inode || size < state.offset {
            // Replaced or truncated: start over. Merging is idempotent, so re-reading is safe.
            state = FileState(inode: inode, offset: 0, partial: Data())
        }
        guard size > state.offset else {
            files[path] = state
            return
        }
        stats.filesRead += 1
        var buffer = [UInt8](repeating: 0, count: Self.chunkBytes)
        while state.offset < size {
            let n = pread(fd, &buffer, min(buffer.count, Int(size - state.offset)), off_t(state.offset))
            guard n > 0 else { break }
            state.offset += UInt64(n)
            stats.bytesRead += n
            state.partial.append(buffer, count: n)
            consumeLines(&state.partial, fallbackProject: fallbackProject, stats: &stats)
        }
        if state.partial.count > Self.maxLineBytes {
            state.partial.removeAll()
            stats.malformedOrSkippedLines += 1
        }
        files[path] = state
    }

    private mutating func consumeLines(_ data: inout Data, fallbackProject: String, stats: inout ScanStats) {
        var start = data.startIndex
        while let nl = data[start...].firstIndex(of: UInt8(ascii: "\n")) {
            let line = data[start..<nl]
            start = data.index(after: nl)
            guard !line.isEmpty else { continue }
            let text = String(decoding: line, as: UTF8.self)
            if let r = UsageParser.parse(line: text, fallbackProject: fallbackProject) {
                records[r.key] = records[r.key].map { $0.merged(with: r) } ?? r
            } else if text.contains("\"usage\""), text.contains("\"assistant\"") {
                stats.malformedOrSkippedLines += 1
            }
        }
        data.removeSubrange(data.startIndex..<start)
    }
}

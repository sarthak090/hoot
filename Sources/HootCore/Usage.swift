import Foundation

/// Token usage of one model response, merged across every transcript line that repeats it.
public struct UsageRecord: Sendable, Equatable {
    /// `message.id`, which several transcript lines share while a response streams.
    public var key: String
    public var model: String
    public var timestamp: Date
    public var sessionID: String?
    public var project: String
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite5m: Int
    public var cacheWrite1h: Int
    /// Claude Code fast mode (`usage.speed == "fast"`), billed at a premium.
    public var fast: Bool

    public var cacheWrite: Int { cacheWrite5m + cacheWrite1h }
    public var totalTokens: Int { input + output + cacheRead + cacheWrite }
    /// Everything sent to the model in this request (decides long-context pricing tiers).
    public var promptTokens: Int { input + cacheRead + cacheWrite }

    public init(key: String, model: String, timestamp: Date, sessionID: String?, project: String,
                input: Int, output: Int, cacheRead: Int, cacheWrite5m: Int, cacheWrite1h: Int, fast: Bool = false) {
        self.key = key
        self.model = model
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.project = project
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.fast = fast
    }

    /// Lines of one streamed response repeat its usage while `output_tokens` grows, so
    /// the merged record keeps the largest value of each counter (and the first time).
    public func merged(with other: UsageRecord) -> UsageRecord {
        var r = self
        r.input = max(input, other.input)
        r.output = max(output, other.output)
        r.cacheRead = max(cacheRead, other.cacheRead)
        r.cacheWrite5m = max(cacheWrite5m, other.cacheWrite5m)
        r.cacheWrite1h = max(cacheWrite1h, other.cacheWrite1h)
        r.timestamp = min(timestamp, other.timestamp)
        r.fast = fast || other.fast
        if r.sessionID == nil { r.sessionID = other.sessionID }
        return r
    }
}

/// Reads usage out of Claude Code transcript lines (`~/.claude/projects/**/*.jsonl`).
/// Malformed or irrelevant lines are skipped, never fatal.
public enum UsageParser {
    private struct Line: Decodable {
        var type: String?
        var timestamp: String?
        var sessionId: String?
        var cwd: String?
        var requestId: String?
        var message: Message?
    }

    private struct Message: Decodable {
        var id: String?
        var model: String?
        var usage: Usage?
    }

    private struct Usage: Decodable {
        var input_tokens: Int?
        var output_tokens: Int?
        var cache_read_input_tokens: Int?
        var cache_creation_input_tokens: Int?
        var cache_creation: CacheCreation?
        var speed: String?
    }

    private struct CacheCreation: Decodable {
        var ephemeral_5m_input_tokens: Int?
        var ephemeral_1h_input_tokens: Int?
    }

    /// Placeholder entries Claude Code writes for local errors; they carry no real usage.
    static let ignoredModels: Set<String> = ["<synthetic>"]

    public static func parse(line: some StringProtocol, fallbackProject: String) -> UsageRecord? {
        // Cheap prefilter: only assistant lines carry usage.
        guard line.contains("\"usage\""), line.contains("\"assistant\"") else { return nil }
        guard let entry = try? JSONDecoder().decode(Line.self, from: Data(line.utf8)),
              entry.type == "assistant",
              let message = entry.message, let usage = message.usage,
              let model = message.model, !ignoredModels.contains(model),
              let stamp = entry.timestamp, let date = parseDate(stamp),
              let key = message.id ?? entry.requestId
        else { return nil }

        let creation = usage.cache_creation_input_tokens ?? 0
        let split5m = usage.cache_creation?.ephemeral_5m_input_tokens
        let split1h = usage.cache_creation?.ephemeral_1h_input_tokens
        let (w5, w1) = (split5m != nil || split1h != nil)
            ? (split5m ?? 0, split1h ?? 0)
            : (creation, 0) // older lines: no TTL split; price as 5-minute writes

        let counts = [usage.input_tokens ?? 0, usage.output_tokens ?? 0, usage.cache_read_input_tokens ?? 0, w5, w1]
        guard counts.allSatisfy({ $0 >= 0 }) else { return nil }

        return UsageRecord(
            key: key, model: model, timestamp: date, sessionID: entry.sessionId,
            project: projectName(cwd: entry.cwd) ?? fallbackProject,
            input: counts[0], output: counts[1], cacheRead: counts[2], cacheWrite5m: w5, cacheWrite1h: w1,
            fast: usage.speed == "fast")
    }

    static func projectName(cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty || name == "/" ? cwd : name
    }

    static func parseDate(_ s: String) -> Date? {
        if let d = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s) { return d }
        return try? Date.ISO8601FormatStyle().parse(s)
    }
}

import Foundation
import HootCore

@MainActor
func usageTests() {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let now = try! Date.ISO8601FormatStyle().parse("2026-10-16T12:00:00Z")

    func line(id: String = "msg_1", model: String = "claude-opus-5-5", ts: String = "2026-10-16T08:00:00.123Z",
              session: String = "s1", cwd: String = "/Users/me/hoot-demo", input: Int = 10, output: Int = 100,
              read: Int = 1000, write: Int = 50, split: (Int, Int)? = (50, 0), speed: String = "standard",
              type: String = "assistant") -> String {
        let cc = split.map { #","cache_creation":{"ephemeral_5m_input_tokens":\#($0.0),"ephemeral_1h_input_tokens":\#($0.1)}"# } ?? ""
        return #"{"parentUuid":"x","type":"\#(type)","timestamp":"\#(ts)","sessionId":"\#(session)","cwd":"\#(cwd)","requestId":"req_\#(id)","message":{"id":"\#(id)","model":"\#(model)","role":"assistant","content":[{"type":"text","text":"hi \"usage\""}],"usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(read),"cache_creation_input_tokens":\#(write)\#(cc),"speed":"\#(speed)","server_tool_use":{"web_search_requests":0}}}}"#
    }

    Harness.test("parses a real-shaped assistant line") {
        let r = UsageParser.parse(line: line(), fallbackProject: "dir")
        Harness.expectEqual(r?.key, "msg_1")
        Harness.expectEqual(r?.project, "hoot-demo")
        Harness.expectEqual(r?.totalTokens, 1160)
        Harness.expectEqual(r?.cacheWrite5m, 50)
        Harness.expectEqual(r?.sessionID, "s1")
        Harness.expectEqual(r.map { Int($0.timestamp.timeIntervalSince1970 * 1000) }, 1792137600123)
    }

    Harness.test("skips what isn't billable usage, tolerates junk") {
        Harness.expect(UsageParser.parse(line: line(model: "<synthetic>"), fallbackProject: "d") == nil, "synthetic")
        Harness.expect(UsageParser.parse(line: line(type: "api-request-blob"), fallbackProject: "d") == nil, "blob copies")
        Harness.expect(UsageParser.parse(line: line(input: -5), fallbackProject: "d") == nil, "negative counts")
        for junk in ["", "{", "not json \"usage\" \"assistant\"", #"{"type":"assistant","message":{"usage":"x"}}"#,
                     #"{"type":"assistant","timestamp":"yesterday","message":{"id":"a","model":"m","usage":{}}}"#] {
            Harness.expect(UsageParser.parse(line: junk, fallbackProject: "d") == nil, "junk: \(junk.prefix(30))")
        }
        let noSplit = UsageParser.parse(line: line(write: 70, split: nil), fallbackProject: "d")
        Harness.expectEqual(noSplit?.cacheWrite5m, 70)
        Harness.expectEqual(UsageParser.parse(line: line(cwd: ""), fallbackProject: "fallback")?.project, "fallback")
    }

    Harness.test("pricing: exact and dated ids only, long context, fast mode") {
        let p = PricingTable.builtIn
        Harness.expectEqual(p.model(for: "claude-haiku-4-5-20251001")?.match, "claude-haiku-4-5")
        Harness.expectEqual(p.model(for: "claude-sonnet-5-5")?.match, "claude-sonnet-5-5")
        Harness.expectEqual(p.model(for: "claude-sonnet-5")?.match, "claude-sonnet-5")
        Harness.expect(p.model(for: "claude-sonnet-5-preview") == nil, "no loose prefix match")
        Harness.expect(p.model(for: "gpt-5") == nil, "unknown model")
        func rec(_ model: String, input: Int = 0, output: Int = 0, read: Int = 0, w5: Int = 0, w1: Int = 0, fast: Bool = false) -> UsageRecord {
            UsageRecord(key: "k", model: model, timestamp: now, sessionID: nil, project: "p", input: input, output: output,
                        cacheRead: read, cacheWrite5m: w5, cacheWrite1h: w1, fast: fast)
        }
        func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-9 } ?? false }
        // 1M of each on Opus 5.5: 4 + 20 + 0.2 + 5 + 8
        Harness.expect(near(p.cost(of: rec("claude-opus-5-5", input: 1_000_000, output: 1_000_000, read: 1_000_000, w5: 1_000_000, w1: 1_000_000)), 37.2), "opus 5.5 rates")
        Harness.expect(near(p.cost(of: rec("claude-opus-5-5", output: 1_000_000, fast: true)), 40), "fast mode doubles")
        Harness.expect(near(p.cost(of: rec("claude-sonnet-4-6", output: 1_000_000, fast: true)), 15), "no fast premium without multiplier")
        Harness.expect(near(p.cost(of: rec("claude-haiku-5-5", input: 100_000, output: 1_000_000)), 0.01 + 0.5), "haiku at the threshold: base rates")
        Harness.expect(near(p.cost(of: rec("claude-haiku-5-5", input: 50_000, output: 1_000_000, read: 50_001)), 0.025 + 2.5 + 0.00250005), "above it: long-context rates")
        Harness.expect(p.cost(of: rec("claude-nonexistent")) == nil, "unpriced is nil, not zero")
        Harness.expectEqual(p.pricesAsOf, "2026-10-06")
        Harness.expect((try? PricingTable.decode(Data("{\"models\": [{\"match\": 1}]}".utf8))) == nil, "bad file rejected")
    }

    Harness.test("summary: days, sessions, top project, unpriced") {
        let recs = [
            UsageRecord(key: "a", model: "claude-opus-5-5", timestamp: now.addingTimeInterval(-3600), sessionID: "s1", project: "alpha", input: 1_000_000, output: 0, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0),
            UsageRecord(key: "b", model: "claude-opus-5-5", timestamp: now.addingTimeInterval(-7200), sessionID: "s2", project: "beta", input: 10, output: 0, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0),
            UsageRecord(key: "c", model: "mystery-model", timestamp: now.addingTimeInterval(-86400 * 2), sessionID: "s3", project: "beta", input: 500, output: 0, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0),
            UsageRecord(key: "d", model: "claude-opus-5-5", timestamp: now.addingTimeInterval(-86400 * 7), sessionID: "s4", project: "old", input: 9_999_999, output: 0, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0),
            // Just after local midnight belongs to today; just before belongs to yesterday.
            UsageRecord(key: "e", model: "claude-opus-5-5", timestamp: try! Date.ISO8601FormatStyle().parse("2026-10-16T00:00:00Z"), sessionID: "s1", project: "alpha", input: 1, output: 0, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0),
            UsageRecord(key: "f", model: "claude-opus-5-5", timestamp: try! Date.ISO8601FormatStyle().parse("2026-10-15T23:59:59Z"), sessionID: "s9", project: "alpha", input: 2, output: 0, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0),
        ]
        let s = UsageSummary.compute(recs, pricing: .builtIn, now: now, calendar: utc)
        Harness.expectEqual(s.days.count, 7)
        Harness.expectEqual(s.today.tokens.total, 1_000_011)
        Harness.expectEqual(s.days[5].tokens.total, 2)
        Harness.expectEqual(s.days[4].tokens.total, 500)
        Harness.expectEqual(s.week.total, 1_000_513)
        Harness.expectEqual(s.sessionsToday, 2)
        Harness.expectEqual(s.topProject?.name, "alpha")
        Harness.expectEqual(s.unpricedModels, ["mystery-model"])
        Harness.expect(abs(s.today.cost - 4.000044) < 1e-9, "today's cost")
        let empty = UsageSummary.compute([], pricing: .builtIn, now: now, calendar: utc)
        Harness.expect(empty.topProject == nil && empty.week.total == 0 && empty.days.count == 7, "empty window")
    }

    Harness.test("token formatting") {
        Harness.expectEqual(TokenFormat.compact(950), "950")
        Harness.expectEqual(TokenFormat.compact(12_340), "12.3K")
        Harness.expectEqual(TokenFormat.compact(4_560_000), "4.56M")
        Harness.expectEqual(TokenFormat.compact(1_000_000), "1M")
        Harness.expectEqual(TokenFormat.compact(1_200_000_000), "1.2B")
        Harness.expectEqual(TokenFormat.dollars(0.004), "<$0.01")
        Harness.expectEqual(TokenFormat.dollars(12.345), "$12.35")
    }

    Harness.test("index: streamed duplicates count once, appends read incrementally") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hoot-usage-\(UUID().uuidString)/proj", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let file = dir.appendingPathComponent("s1.jsonl")
        // Three lines of the same streamed response; output grows 2 -> 2 -> 812.
        let body = [line(output: 2), line(output: 2), "{garbage", "", line(output: 812)].joined(separator: "\n") + "\n"
        try body.write(to: file, atomically: true, encoding: .utf8)
        var index = UsageIndex()
        let since = now.addingTimeInterval(-86400 * 30)
        var stats = index.scan(root: dir.deletingLastPathComponent(), since: since)
        Harness.expectEqual(index.records.count, 1)
        Harness.expectEqual(index.records["msg_1"]?.output, 812)
        Harness.expectEqual(stats.malformedOrSkippedLines, 0)

        // Append half a line: nothing new until its newline arrives.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        let next = line(id: "msg_2", output: 7)
        try handle.write(contentsOf: Data(next.prefix(40).utf8))
        stats = index.scan(root: dir.deletingLastPathComponent(), since: since)
        Harness.expectEqual(index.records.count, 1)
        Harness.expectEqual(stats.bytesRead, 40)
        try handle.write(contentsOf: Data((next.dropFirst(40) + "\n").utf8))
        try handle.close()
        index.scan(root: dir.deletingLastPathComponent(), since: since)
        Harness.expectEqual(index.records["msg_2"]?.output, 7)
        stats = index.scan(root: dir.deletingLastPathComponent(), since: since)
        Harness.expectEqual(stats.bytesRead, 0)

        // Rewritten file: re-read from the start without double counting.
        try (line(output: 812) + "\n").write(to: file, atomically: true, encoding: .utf8)
        index.scan(root: dir.deletingLastPathComponent(), since: since)
        Harness.expectEqual(index.records["msg_1"]?.output, 812)

        // Records older than the window are dropped.
        index.scan(root: dir.deletingLastPathComponent(), since: now.addingTimeInterval(86400))
        Harness.expectEqual(index.records.count, 0)
    }
}

/// Read-only: `HOOT_REAL_PROJECTS=~/.claude/projects swift run HootTests`
@MainActor
func realUsageReport() {
    guard let path = ProcessInfo.processInfo.environment["HOOT_REAL_PROJECTS"] else { return }
    Harness.test("real transcripts at \(path) (read-only)") {
        let now = Date()
        let since = UsageSummary.windowStart(now: now, calendar: .current)
        var index = UsageIndex()
        let started = Date()
        let stats = index.scan(root: URL(fileURLWithPath: path), since: since)
        let first = Date().timeIntervalSince(started)
        let again = Date()
        let stats2 = index.scan(root: URL(fileURLWithPath: path), since: since)
        let second = Date().timeIntervalSince(again)
        let s = UsageSummary.compute(index.records.values, pricing: .builtIn, now: now)
        print(String(format: "   first scan %.2fs (%d files, %.1f MB), rescan %.3fs (%d bytes), skipped lines %d",
                     first, stats.filesRead, Double(stats.bytesRead) / 1e6, second, stats2.bytesRead, stats.malformedOrSkippedLines))
        for d in s.days {
            print("   \(d.day.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))) total=\(d.tokens.total) in=\(d.tokens.input) out=\(d.tokens.output) read=\(d.tokens.cacheRead) write=\(d.tokens.cacheWrite) cost=\(String(format: "%.2f", d.cost))")
        }
        print("   sessions today=\(s.sessionsToday) top=\(s.topProject?.name ?? "-") unpriced=\(s.unpricedModels)")
        Harness.expect(second < 0.5, "rescan with no changes is fast")
    }
}

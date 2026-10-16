import Foundation
import HootCore

@MainActor
func statusLineTests() {
    let now = Date(timeIntervalSince1970: 1_792_000_000)
    // Shape from the statusline docs.
    let doc = """
    {"hook_event_name":"Status","session_id":"abc","model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},
     "context_window":{"used_percentage":42.4},
     "rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1792003600},
                    "seven_day":{"used_percentage":41.2,"resets_at":1792400000}}}
    """

    Harness.test("parses rate limits and builds the default line") {
        let input = StatusLine.parse(Data(doc.utf8), now: now)
        Harness.expectEqual(input?.modelName, "Opus 5.5")
        Harness.expectEqual(input?.rateLimits?.fiveHour?.usedPercentage, 23.5)
        Harness.expectEqual(input?.rateLimits?.fiveHour?.leftPercentage, 76.5)
        Harness.expectEqual(input?.rateLimits?.sevenDay?.resetsAt, Date(timeIntervalSince1970: 1_792_400_000))
        Harness.expectEqual(input.map(StatusLine.defaultLine), "Opus 5.5 · ctx 42% · 5h 24% · 7d 41%")
    }

    Harness.test("missing, partial and hostile input") {
        let bare = StatusLine.parse(Data(#"{"model":{"display_name":"Sonnet"}}"#.utf8), now: now)
        Harness.expect(bare != nil && bare?.rateLimits == nil, "no limits is fine")
        Harness.expectEqual(StatusLine.defaultLine(StatusLine.parse(Data("{}".utf8), now: now)!), "Claude Code")
        Harness.expect(StatusLine.parse(Data("nope".utf8), now: now) == nil, "garbage")
        Harness.expect(StatusLine.parse(Data("[1]".utf8), now: now) == nil, "not an object")
        let weird = StatusLine.parse(Data(#"{"rate_limits":{"five_hour":{"used_percentage":250,"resets_at":-5},"seven_day":{"used_percentage":"x"}}}"#.utf8), now: now)
        Harness.expectEqual(weird?.rateLimits?.fiveHour?.usedPercentage, 100)
        Harness.expect(weird?.rateLimits?.fiveHour?.resetsAt == nil, "bad reset time ignored")
        Harness.expect(weird?.rateLimits?.sevenDay == nil, "bad window ignored")
        // Terminal escape injection through the model name must not survive.
        let evil = StatusLine.parse(Data(#"{"model":{"display_name":"Opus\u001b]0;pwned\u0007\nline2"}}"#.utf8), now: now)!
        let line = StatusLine.defaultLine(evil)
        Harness.expect(!line.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }, "no control characters: \(line)")
    }

    Harness.test("expired windows are dropped") {
        let snap = RateLimitSnapshot(fiveHour: RateLimitWindow(usedPercentage: 10, resetsAt: now.addingTimeInterval(-1)),
                                     sevenDay: RateLimitWindow(usedPercentage: 20, resetsAt: now.addingTimeInterval(60)), receivedAt: now)
        Harness.expect(snap.current(now: now)?.fiveHour == nil, "5h expired")
        Harness.expectEqual(snap.current(now: now)?.sevenDay?.usedPercentage, 20)
        Harness.expect(snap.current(now: now.addingTimeInterval(120)) == nil, "both expired")
    }

    let script = "/Users/me/.claude/hooks/hoot-statusline.sh"
    Harness.test("statusline install adds, wraps, and restores exactly") {
        let plain = "{\n  \"theme\": \"dark\"\n}\n"
        let added = try StatusLineInstaller.install(into: plain, scriptPath: script)
        Harness.expect(added.replaced == nil, "nothing replaced")
        let isOn = try StatusLineInstaller.isInstalled(in: added.text)
        Harness.expect(isOn, "installed")
        Harness.expectEqual(try StatusLineInstaller.uninstall(from: added.text, restoring: nil), plain)

        let mine = "{\n  \"statusLine\": {\n    \"type\": \"command\",\n    \"command\": \"~/bin/my-status.sh\",\n    \"padding\": 2\n  },\n  \"theme\": \"dark\"\n}\n"
        let wrapped = try StatusLineInstaller.install(into: mine, scriptPath: script)
        Harness.expectEqual(wrapped.replaced?["command"]?.stringValue, "~/bin/my-status.sh")
        let root = try OrderedJSON.parse(wrapped.text)
        Harness.expectEqual(root["statusLine"]?["padding"], .number("2"))
        Harness.expectEqual(root["statusLine"]?["command"]?.stringValue, "'\(script)'")
        Harness.expectEqual(try StatusLineInstaller.uninstall(from: wrapped.text, restoring: wrapped.replaced), mine)
        // Idempotent; and uninstall leaves someone else's statusline alone.
        Harness.expectEqual(try StatusLineInstaller.install(into: wrapped.text, scriptPath: script).text, wrapped.text)
        Harness.expectEqual(try StatusLineInstaller.uninstall(from: mine, restoring: nil), mine)
        do {
            _ = try StatusLineInstaller.install(into: #"{"statusLine": "text"}"#, scriptPath: script)
            Harness.expect(false, "should refuse non-command statusline")
        } catch let e as StatusLineInstaller.Failure {
            Harness.expectEqual(e, .unsupportedExisting)
        }
    }
}

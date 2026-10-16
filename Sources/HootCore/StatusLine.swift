import Foundation

/// One plan rate-limit window as Claude Code reports it to statusline commands.
public struct RateLimitWindow: Codable, Sendable, Equatable {
    /// 0...100
    public var usedPercentage: Double
    public var resetsAt: Date?

    public init(usedPercentage: Double, resetsAt: Date?) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }

    public var leftPercentage: Double { max(0, 100 - usedPercentage) }
}

/// The latest `rate_limits` seen. Only Pro/Max (or gateway spend-limited) sessions send it,
/// and only after the session's first API response.
public struct RateLimitSnapshot: Codable, Sendable, Equatable {
    public var fiveHour: RateLimitWindow?
    public var sevenDay: RateLimitWindow?
    public var receivedAt: Date

    public init(fiveHour: RateLimitWindow?, sevenDay: RateLimitWindow?, receivedAt: Date) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.receivedAt = receivedAt
    }

    /// Windows whose reset time has passed are dropped, as Claude Code itself does:
    /// their percentage no longer means anything.
    public func current(now: Date) -> RateLimitSnapshot? {
        func live(_ w: RateLimitWindow?) -> RateLimitWindow? {
            guard let w else { return nil }
            if let r = w.resetsAt, r <= now { return nil }
            return w
        }
        let s = RateLimitSnapshot(fiveHour: live(fiveHour), sevenDay: live(sevenDay), receivedAt: receivedAt)
        return s.fiveHour == nil && s.sevenDay == nil ? nil : s
    }
}

public struct StatusLineInput: Sendable, Equatable {
    public var modelName: String?
    public var contextUsedPercentage: Double?
    public var rateLimits: RateLimitSnapshot?
}

public enum StatusLine {
    public static func parse(_ data: Data, now: Date) -> StatusLineInput? {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data), case .object = json else { return nil }
        func percent(_ v: JSONValue?) -> Double? {
            guard case .number(let n)? = v, n.isFinite else { return nil }
            return min(100, max(0, n))
        }
        func window(_ v: JSONValue?) -> RateLimitWindow? {
            guard let v, let used = percent(v["used_percentage"]) else { return nil }
            var resets: Date?
            if case .number(let t)? = v["resets_at"], t.isFinite, t > 0, t < 1e11 { resets = Date(timeIntervalSince1970: t) }
            return RateLimitWindow(usedPercentage: used, resetsAt: resets)
        }
        let limits = json["rate_limits"]
        let five = window(limits?["five_hour"])
        let seven = window(limits?["seven_day"])
        return StatusLineInput(
            modelName: json["model"]?["display_name"]?.stringValue ?? json["model"]?["id"]?.stringValue,
            contextUsedPercentage: percent(json["context_window"]?["used_percentage"]),
            rateLimits: five == nil && seven == nil ? nil : RateLimitSnapshot(fiveHour: five, sevenDay: seven, receivedAt: now))
    }

    /// Hoot's own one-line status, used when it isn't wrapping another statusline.
    /// Everything is sanitized: this text is printed straight into the user's terminal.
    public static func defaultLine(_ input: StatusLineInput) -> String {
        var parts: [String] = []
        if let m = input.modelName, !m.isEmpty {
            // One line only, no control characters: this lands in the terminal.
            let flat = m.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
            parts.append(String(SafeText.visible(flat).text.prefix(40)))
        }
        if let c = input.contextUsedPercentage { parts.append("ctx \(Int(c.rounded()))%") }
        if let f = input.rateLimits?.fiveHour { parts.append("5h \(Int(f.usedPercentage.rounded()))%") }
        if let w = input.rateLimits?.sevenDay { parts.append("7d \(Int(w.usedPercentage.rounded()))%") }
        return parts.isEmpty ? "Claude Code" : parts.joined(separator: " · ")
    }
}

/// Adds/removes Hoot's statusline in settings.json, wrapping (not replacing) an existing one.
public enum StatusLineInstaller {
    static let scriptMarker = "/.claude/hooks/hoot-statusline.sh"
    /// Pre-release builds were called Nudge.
    static let legacyScriptMarkers = ["/.claude/hooks/nudge-statusline.sh"]

    public enum Failure: Error, Equatable, LocalizedError {
        case unsupportedExisting

        public var errorDescription: String? {
            "Your current statusLine isn't a command, so Hoot can't wrap it. Remove it first if you want Hoot's."
        }
    }

    public static func isOurs(_ value: OrderedJSON?) -> Bool {
        guard let command = value?["command"]?.stringValue else { return false }
        return ([scriptMarker] + legacyScriptMarkers).contains { command.contains($0) }
    }

    public static func isInstalled(in text: String?) throws -> Bool {
        isOurs(try HookInstaller.parseRoot(text)["statusLine"])
    }

    /// Ours *and* pointing at the current script (not a pre-release path).
    public static func isCurrent(in text: String?, scriptPath: String) throws -> Bool {
        try HookInstaller.parseRoot(text)["statusLine"]?["command"]?.stringValue == quoted(scriptPath)
    }

    static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Returns the new text, and the statusLine it replaced (to be saved and restored later).
    public static func install(into text: String?, scriptPath: String) throws -> (text: String, replaced: OrderedJSON?) {
        var root = try HookInstaller.parseRoot(text)
        let existing = root["statusLine"]
        let command = OrderedJSON.string(quoted(scriptPath))
        if isOurs(existing), var updated = existing {
            // Already ours: just make sure it points at the current script.
            if updated["command"] == command, let text { return (text, nil) }
            updated.set("command", command)
            root.set("statusLine", updated)
            return (HookInstaller.render(root, like: text), nil)
        }
        var ours: OrderedJSON
        if let existing {
            guard case .object = existing, existing["type"]?.stringValue == "command",
                  existing["command"]?.stringValue != nil
            else { throw Failure.unsupportedExisting }
            ours = existing // keeps padding and any other options the user set
            ours.set("command", command)
        } else {
            ours = .object([("type", .string("command")), ("command", command)])
        }
        root.set("statusLine", ours)
        return (HookInstaller.render(root, like: text), existing)
    }

    /// Restores the saved original statusLine, or removes ours if there was none.
    /// Leaves the file alone if the current statusLine isn't Hoot's.
    public static func uninstall(from text: String?, restoring original: OrderedJSON?) throws -> String? {
        guard let text else { return nil }
        var root = try HookInstaller.parseRoot(text)
        guard isOurs(root["statusLine"]) else { return text }
        root.set("statusLine", original)
        return HookInstaller.render(root, like: text)
    }
}

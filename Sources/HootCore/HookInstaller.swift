import Foundation

/// Adds and removes Hoot's entries in Claude Code's settings.json without touching
/// anything else. Pure text-in/text-out so it can be tested without the file system.
///
/// Hoot's handlers are recognised by their command pointing at `…/.claude/hooks/hoot.sh`,
/// so no custom keys are written into the user's settings.
public enum HookInstaller {
    public struct Config: Sendable, Equatable {
        public var scriptPath: String
        /// Seconds the menu bar waits for an answer; the hook's own timeout must be longer.
        public var answerTimeout: Int

        public init(scriptPath: String, answerTimeout: Int) {
            self.scriptPath = scriptPath
            self.answerTimeout = answerTimeout
        }

        /// Claude Code kills the hook at this point; it must outlast the curl wait
        /// (answer timeout + 5s), so the menu bar's "no decision" always arrives first.
        public var permissionHookTimeout: Int { answerTimeout + 15 }
    }

    public enum Status: Sendable, Equatable {
        case notInstalled
        case installed
        /// Some Hoot entries exist but differ from what this version would write.
        case outdated
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case invalidJSON(String)
        case notAnObject
        case unexpectedType(String)

        public var errorDescription: String? {
            switch self {
            case .invalidJSON(let why): "settings.json isn't valid JSON (\(why)). Hoot won't edit it."
            case .notAnObject: "settings.json doesn't contain a JSON object. Hoot won't edit it."
            case .unexpectedType(let path): "\(path) in settings.json has an unexpected type. Hoot won't edit it."
            }
        }
    }

    static let scriptMarker = "/.claude/hooks/hoot.sh"
    /// Pre-release builds were called Nudge; their entries are recognised so an update replaces them.
    static let legacyScriptMarkers = ["/.claude/hooks/nudge.sh"]
    public static let events = ["PermissionRequest", "Notification", "UserPromptSubmit"]

    // MARK: - Public API

    public static func install(into text: String?, config: Config) throws -> String {
        var root = try parseRoot(text)
        var hooks = try hooksObject(root)
        for event in events {
            var groups = try removingHoot(from: groups(in: hooks, event: event))
            groups.append(group(for: event, config: config))
            hooks.set(event, .array(groups))
        }
        root.set("hooks", hooks)
        return render(root, like: text)
    }

    /// Returns the text unchanged if there is nothing of Hoot's in it.
    public static func uninstall(from text: String?) throws -> String? {
        guard let text else { return nil }
        var root = try parseRoot(text)
        guard root["hooks"] != nil else { return text }
        var hooks = try hooksObject(root)
        guard case .object(let pairs) = hooks else { return text }
        var changed = false
        for pair in pairs {
            guard case .array = pair.value else { continue }
            let before = try groups(in: hooks, event: pair.key)
            let after = try removingHoot(from: before)
            guard after != before else { continue }
            changed = true
            // Drop an event list only if removing Hoot emptied it.
            hooks.set(pair.key, after.isEmpty ? nil : .array(after))
        }
        guard changed else { return text }
        if case .object(let left) = hooks, left.isEmpty {
            root.set("hooks", nil)
        } else {
            root.set("hooks", hooks)
        }
        return render(root, like: text)
    }

    public static func status(of text: String?, config: Config) throws -> Status {
        let root = try parseRoot(text)
        let hooks = try hooksObject(root)
        guard case .object(let pairs) = hooks else { return .notInstalled }
        var found = 0
        var exact = true
        for pair in pairs {
            guard case .array(let groups) = pair.value else { continue }
            for group in groups {
                guard case .array(let handlers)? = group["hooks"] else { continue }
                for handler in handlers where isHoot(handler) {
                    found += 1
                    if !events.contains(pair.key) || group != self.group(for: pair.key, config: config) { exact = false }
                }
            }
        }
        if found == 0 { return .notInstalled }
        return exact && found == events.count ? .installed : .outdated
    }

    /// `"disableAllHooks": true` in user settings stops every hook, including Hoot's.
    public static func hooksDisabled(in text: String?) -> Bool {
        (try? parseRoot(text))?["disableAllHooks"] == .bool(true)
    }

    public static func command(scriptPath: String, mode: String) -> String {
        "'" + scriptPath.replacingOccurrences(of: "'", with: "'\\''") + "' " + mode
    }

    // MARK: - Pieces

    static func group(for event: String, config: Config) -> OrderedJSON {
        let handler: OrderedJSON
        if event == "PermissionRequest" {
            handler = .object([
                ("type", .string("command")),
                ("command", .string(command(scriptPath: config.scriptPath, mode: "permission"))),
                ("timeout", .number(String(config.permissionHookTimeout))),
            ])
        } else {
            handler = .object([
                ("type", .string("command")),
                ("command", .string(command(scriptPath: config.scriptPath, mode: "event"))),
                ("timeout", .number("10")),
                ("async", .bool(true)),
            ])
        }
        return .object([("hooks", .array([handler]))])
    }

    static func isHoot(_ handler: OrderedJSON) -> Bool {
        guard let command = handler["command"]?.stringValue else { return false }
        return ([scriptMarker] + legacyScriptMarkers).contains { command.contains($0) }
    }

    static func parseRoot(_ text: String?) throws -> OrderedJSON {
        guard let text, !text.allSatisfy(\.isWhitespace) else { return .object([]) }
        let root: OrderedJSON
        do { root = try OrderedJSON.parse(text) } catch let e as JSONSyntaxError {
            throw Failure.invalidJSON(e.description)
        }
        guard case .object = root else { throw Failure.notAnObject }
        return root
    }

    private static func hooksObject(_ root: OrderedJSON) throws -> OrderedJSON {
        guard let hooks = root["hooks"] else { return .object([]) }
        guard case .object = hooks else { throw Failure.unexpectedType("\"hooks\"") }
        return hooks
    }

    private static func groups(in hooks: OrderedJSON, event: String) throws -> [OrderedJSON] {
        guard let value = hooks[event] else { return [] }
        guard case .array(let groups) = value else { throw Failure.unexpectedType("\"hooks.\(event)\"") }
        return groups
    }

    /// Removes Hoot's handlers. A group is dropped only if that removal emptied it,
    /// so other tools' (even empty) groups stay exactly as they were.
    private static func removingHoot(from groups: [OrderedJSON]) throws -> [OrderedJSON] {
        var out: [OrderedJSON] = []
        for var group in groups {
            guard case .array(let handlers)? = group["hooks"] else {
                out.append(group)
                continue
            }
            let kept = handlers.filter { !isHoot($0) }
            if kept.count == handlers.count {
                out.append(group)
            } else if !kept.isEmpty {
                group.set("hooks", .array(kept))
                out.append(group)
            }
        }
        return out
    }

    /// Keeps the original file's trailing newline convention (new or blank files get one).
    static func render(_ root: OrderedJSON, like original: String?) -> String {
        guard let original, !original.allSatisfy(\.isWhitespace) else { return root.formatted() + "\n" }
        let trailing = original.hasSuffix("\n")
        return root.formatted() + (trailing ? "\n" : "")
    }
}

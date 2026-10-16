import Foundation

/// An "always allow"-style option offered by Claude Code in `permission_suggestions`.
/// Hoot only ever echoes one of these back verbatim; it never invents rules.
public struct PermissionOption: Sendable, Equatable, Identifiable {
    public let id: Int
    public let label: String
    public let suggestion: JSONValue
}

public enum PermissionOptions {
    /// Turns suggestions into button labels, keeping only ones that grant something
    /// the user can understand. `bypassPermissions` is never offered.
    public static func from(_ suggestions: [JSONValue]?) -> [PermissionOption] {
        guard let suggestions else { return [] }
        var options: [PermissionOption] = []
        for (i, s) in suggestions.enumerated() {
            guard let label = label(for: s) else { continue }
            options.append(PermissionOption(id: i, label: label, suggestion: s))
        }
        return options
    }

    static func label(for s: JSONValue) -> String? {
        let scope = destinationLabel(s["destination"]?.stringValue)
        switch s["type"]?.stringValue {
        case "addRules":
            guard s["behavior"]?.stringValue == "allow",
                  let rules = s["rules"]?.arrayValue, !rules.isEmpty
            else { return nil }
            let names = rules.compactMap { rule -> String? in
                guard let tool = rule["toolName"]?.stringValue else { return nil }
                if let content = rule["ruleContent"]?.stringValue, !content.isEmpty {
                    return "\(tool)(\(content))"
                }
                return tool
            }
            guard names.count == rules.count else { return nil }
            return SafeText.visible("Always allow \(names.joined(separator: ", ")) \(scope)").text
        case "setMode":
            guard let mode = s["mode"]?.stringValue else { return nil }
            switch mode {
            case "acceptEdits": return "Allow all edits \(scope)"
            case "auto": return "Switch to auto mode \(scope)"
            case "dontAsk": return "Switch to don't-ask mode \(scope)"
            case "plan": return "Switch to plan mode \(scope)"
            default: return nil // bypassPermissions and anything unknown
            }
        case "addDirectories":
            guard let dirs = s["directories"]?.arrayValue?.compactMap(\.stringValue), !dirs.isEmpty else { return nil }
            return SafeText.visible("Always allow access to \(dirs.joined(separator: ", ")) \(scope)").text
        default:
            return nil
        }
    }

    static func destinationLabel(_ d: String?) -> String {
        switch d {
        case "session": "for this session"
        case "localSettings": "in this project (local settings)"
        case "projectSettings": "in this project (shared settings)"
        case "userSettings": "in all projects"
        default: "(\(d ?? "unknown scope"))"
        }
    }
}

public enum PermissionDecision: Sendable, Equatable {
    case allow(updatedPermissions: [JSONValue])
    case deny(reason: String?)

    public static let maxReasonLength = 1000

    /// The documented PermissionRequest hook output.
    public func hookOutput() -> Data {
        var decision: [String: JSONValue]
        switch self {
        case .allow(let updates):
            decision = ["behavior": .string("allow")]
            if !updates.isEmpty { decision["updatedPermissions"] = .array(updates) }
        case .deny(let reason):
            let trimmed = String((reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxReasonLength))
            let message = trimmed.isEmpty
                ? "The user denied this from the Hoot menu bar app."
                : "The user denied this from the Hoot menu bar app: \(trimmed)"
            decision = ["behavior": .string("deny"), "message": .string(message)]
        }
        let output: JSONValue = .object([
            "hookSpecificOutput": .object([
                "hookEventName": .string("PermissionRequest"),
                "decision": .object(decision),
            ]),
        ])
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(output)) ?? Data()
    }
}

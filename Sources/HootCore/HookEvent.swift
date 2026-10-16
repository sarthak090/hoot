import Foundation

/// The JSON Claude Code writes to a hook's stdin. Every field is optional: unknown or
/// missing fields must never stop Hoot from handling an event.
public struct HookEvent: Sendable, Equatable, Decodable {
    public var sessionID: String?
    public var transcriptPath: String?
    public var cwd: String?
    public var hookEventName: String?
    public var permissionMode: String?
    // Notification
    public var message: String?
    public var title: String?
    public var notificationType: String?
    // PermissionRequest
    public var toolName: String?
    public var toolInput: JSONValue?
    public var permissionSuggestions: [JSONValue]?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case permissionMode = "permission_mode"
        case message, title
        case notificationType = "notification_type"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case permissionSuggestions = "permission_suggestions"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func str(_ k: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil }
        sessionID = str(.sessionID)
        transcriptPath = str(.transcriptPath)
        cwd = str(.cwd)
        hookEventName = str(.hookEventName)
        permissionMode = str(.permissionMode)
        message = str(.message)
        title = str(.title)
        notificationType = str(.notificationType)
        toolName = str(.toolName)
        toolInput = (try? c.decodeIfPresent(JSONValue.self, forKey: .toolInput)) ?? nil
        permissionSuggestions = (try? c.decodeIfPresent([JSONValue].self, forKey: .permissionSuggestions)) ?? nil
    }

    public static func decode(_ data: Data) -> HookEvent? {
        try? JSONDecoder().decode(HookEvent.self, from: data)
    }

    /// Folder name of the session's working directory, used as the notification title.
    public var projectName: String {
        guard let cwd, !cwd.isEmpty else { return "Claude Code" }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty || name == "/" ? cwd : name
    }
}

/// Notification types that mean "Claude is waiting on you". Others (auth_success,
/// elicitation_complete, quota_*) are informational and don't nudge.
public enum AttentionNotificationTypes {
    public static let all: Set<String> = [
        "permission_prompt", "idle_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input",
    ]

    public static func needsAttention(_ type: String?) -> Bool {
        // An event without a type (older Claude Code) is treated as needing attention.
        guard let type else { return true }
        return all.contains(type)
    }
}

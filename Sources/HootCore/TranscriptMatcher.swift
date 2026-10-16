import Foundation

/// Detects that a pending permission request was answered somewhere else (normally the
/// terminal dialog) by reading the session transcript.
///
/// PermissionRequest payloads carry no tool_use_id, so the request is matched to the most
/// recent `tool_use` with the same tool and identifying input that has no `tool_result` yet.
/// When that result appears, the request is settled. If no match is ever found, it simply
/// never fires; the request then ends by timeout, disconnect or a new prompt instead.
public struct TranscriptMatcher: Sendable {
    public let toolName: String
    let key: JSONValue?
    private(set) public var targetID: String?
    private var unresolvedMatches: [String] = []
    private var finishedIDs: Set<String> = []

    public init(toolName: String, toolInput: JSONValue?) {
        self.toolName = toolName
        key = Self.identifyingKey(toolName: toolName, input: toolInput)
    }

    /// Feed the transcript tail that existed when the request arrived.
    public mutating func consumeBacklog(_ lines: some Sequence<Substring>) {
        for line in lines { scan(line) }
        targetID = unresolvedMatches.last
    }

    /// Feed one newly appended line. Returns true once the request has been answered.
    public mutating func consumeNew(_ line: Substring) -> Bool {
        let tracked = targetID
        scan(line)
        if let tracked, finishedIDs.contains(tracked) { return true }
        // Follow the newest unanswered match: an older one may be an interrupted call
        // that will never get a result.
        targetID = unresolvedMatches.last
        return false
    }

    private mutating func scan(_ line: Substring) {
        // Cheap prefilter: most lines are neither.
        guard line.contains("\"tool_use\"") || line.contains("\"tool_result\"") else { return }
        guard let entry = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
              let content = entry["message"]?["content"]?.arrayValue
        else { return }
        // Only real conversation lines; transcripts also contain request-blob copies.
        switch entry["type"]?.stringValue {
        case "assistant":
            for block in content where block["type"]?.stringValue == "tool_use" {
                guard let id = block["id"]?.stringValue,
                      block["name"]?.stringValue == toolName,
                      Self.identifyingKey(toolName: toolName, input: block["input"]) == key
                else { continue }
                if !finishedIDs.contains(id) { unresolvedMatches.append(id) }
            }
        case "user":
            for block in content where block["type"]?.stringValue == "tool_result" {
                guard let id = block["tool_use_id"]?.stringValue else { continue }
                finishedIDs.insert(id)
                unresolvedMatches.removeAll { $0 == id }
            }
        default:
            break
        }
    }

    /// The part of the input that identifies a call. Whole input as a fallback.
    static func identifyingKey(toolName: String, input: JSONValue?) -> JSONValue? {
        guard let input else { return nil }
        switch toolName {
        case "Bash": return input["command"]
        case "Edit", "MultiEdit", "Write", "Read": return input["file_path"]
        case "NotebookEdit": return input["notebook_path"]
        case "WebFetch": return input["url"]
        default: return input
        }
    }
}

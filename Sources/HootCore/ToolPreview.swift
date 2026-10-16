import Foundation

/// What the user sees before allowing a tool call. All text has gone through `SafeText`.
public struct ToolPreview: Sendable, Equatable {
    public var toolName: String
    /// Claude's own description of the call, if it gave one.
    public var purpose: String?
    /// The full Bash command.
    public var command: String?
    public var filePath: String?
    public var diff: [DiffLine]?
    /// Any other content worth showing (URL, query, raw JSON for unknown tools).
    public var detail: String?
    /// True if hidden or direction-changing characters were made visible anywhere above.
    public var hadHiddenCharacters: Bool
    /// True if anything was cut to keep the preview a sane size.
    public var truncated: Bool
}

public struct DiffLine: Sendable, Equatable {
    public enum Kind: Sendable { case context, added, removed, gap }
    public var kind: Kind
    public var text: String

    public init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }
}

public enum ToolPreviewBuilder {
    public static let maxDiffLines = 400
    public static let maxDetailCharacters = 20_000

    public static func build(toolName: String, input: JSONValue?) -> ToolPreview {
        var hidden = false
        var truncated = false
        func safe(_ s: String?) -> String? {
            guard let s else { return nil }
            let v = SafeText.visible(s)
            hidden = hidden || v.changed
            if v.text.count > maxDetailCharacters {
                truncated = true
                return String(v.text.prefix(maxDetailCharacters)) + "\n… (truncated)"
            }
            return v.text
        }
        func diff(old: String, new: String) -> [DiffLine] {
            let o = SafeText.visible(old), n = SafeText.visible(new)
            hidden = hidden || o.changed || n.changed
            let result = LineDiff.diff(old: o.text, new: n.text, maxOutputLines: maxDiffLines)
            truncated = truncated || result.truncated
            return result.lines
        }

        let input = input ?? .object([:])
        var preview = ToolPreview(toolName: safe(toolName) ?? "Tool", purpose: safe(input["description"]?.stringValue),
                                  hadHiddenCharacters: false, truncated: false)

        switch toolName {
        case "Bash":
            preview.command = safe(input["command"]?.stringValue) ?? ""
        case "Edit":
            preview.filePath = safe(input["file_path"]?.stringValue)
            preview.diff = diff(old: input["old_string"]?.stringValue ?? "", new: input["new_string"]?.stringValue ?? "")
            if input["replace_all"]?.boolValue == true { preview.detail = "Replaces every occurrence." }
        case "MultiEdit":
            preview.filePath = safe(input["file_path"]?.stringValue)
            var lines: [DiffLine] = []
            for (i, edit) in (input["edits"]?.arrayValue ?? []).enumerated() {
                if i > 0 { lines.append(DiffLine(.gap, "")) }
                lines += diff(old: edit["old_string"]?.stringValue ?? "", new: edit["new_string"]?.stringValue ?? "")
            }
            if lines.count > maxDiffLines {
                lines = Array(lines.prefix(maxDiffLines))
                truncated = true
            }
            preview.diff = lines
        case "Write":
            preview.filePath = safe(input["file_path"]?.stringValue)
            preview.diff = diff(old: "", new: input["content"]?.stringValue ?? "")
        case "NotebookEdit":
            preview.filePath = safe(input["notebook_path"]?.stringValue)
            preview.diff = diff(old: "", new: input["new_source"]?.stringValue ?? "")
        case "Read", "Glob", "Grep", "LS":
            preview.filePath = safe(input["file_path"]?.stringValue ?? input["path"]?.stringValue)
            preview.detail = safe(input["pattern"]?.stringValue)
        case "WebFetch":
            preview.detail = safe([input["url"]?.stringValue, input["prompt"]?.stringValue].compactMap { $0 }.joined(separator: "\n\n"))
        case "WebSearch":
            preview.detail = safe(input["query"]?.stringValue)
        default:
            preview.detail = safe(input.prettyPrinted())
        }
        preview.hadHiddenCharacters = hidden
        preview.truncated = truncated
        return preview
    }
}

/// Makes invisible and direction-changing characters visible, so a command can't look
/// different from what will actually run (e.g. U+202E reversing part of a line).
public enum SafeText {
    public static func visible(_ s: String) -> (text: String, changed: Bool) {
        var out = String.UnicodeScalarView()
        var changed = false
        for scalar in s.unicodeScalars {
            if isSuspicious(scalar) {
                changed = true
                out.append(contentsOf: "⟨U+\(String(format: "%04X", scalar.value))⟩".unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        return (String(out), changed)
    }

    static func isSuspicious(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x0A, 0x09: false // newline, tab
        case 0x0D: true // a bare CR can hide the start of a line in some renderers
        case 0x00...0x1F, 0x7F...0x9F: true // C0/C1 controls, including ESC
        case 0x200B...0x200F, 0x2028...0x202E, 0x2060...0x2069, 0xFEFF: true // zero-width, bidi, separators
        case 0xFFF9...0xFFFB: true // interlinear annotation
        case 0xE0000...0xE007F: true // tag characters
        default: false
        }
    }
}

/// Small line diff (LCS) with common prefix/suffix trimming and a hard work limit.
public enum LineDiff {
    public static let maxCells = 400_000

    public static func diff(old: String, new: String, maxOutputLines: Int) -> (lines: [DiffLine], truncated: Bool) {
        let a = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let b = new.isEmpty ? [] : new.components(separatedBy: "\n")

        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }

        let midA = Array(a[prefix..<(a.count - suffix)])
        let midB = Array(b[prefix..<(b.count - suffix)])

        var lines: [DiffLine] = []
        // Up to 3 lines of context on each side, like a unified diff.
        let leading = a[..<prefix].suffix(3)
        if prefix > leading.count { lines.append(DiffLine(.gap, "")) }
        lines += leading.map { DiffLine(.context, $0) }
        lines += middle(midA, midB)
        let trailing = a[(a.count - suffix)...].prefix(3)
        lines += trailing.map { DiffLine(.context, $0) }
        if suffix > trailing.count { lines.append(DiffLine(.gap, "")) }

        if lines.count > maxOutputLines {
            return (Array(lines.prefix(maxOutputLines)), true)
        }
        return (lines, false)
    }

    private static func middle(_ a: [String], _ b: [String]) -> [DiffLine] {
        if a.isEmpty { return b.map { DiffLine(.added, $0) } }
        if b.isEmpty { return a.map { DiffLine(.removed, $0) } }
        // Too big to diff cheaply: show it as a full replacement instead.
        guard a.count * b.count <= maxCells else {
            return a.map { DiffLine(.removed, $0) } + b.map { DiffLine(.added, $0) }
        }
        let n = a.count, m = b.count
        var lcs = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var out: [DiffLine] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                out.append(DiffLine(.context, a[i])); i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                out.append(DiffLine(.removed, a[i])); i += 1
            } else {
                out.append(DiffLine(.added, b[j])); j += 1
            }
        }
        out += a[i...].map { DiffLine(.removed, $0) }
        out += b[j...].map { DiffLine(.added, $0) }
        return out
    }
}

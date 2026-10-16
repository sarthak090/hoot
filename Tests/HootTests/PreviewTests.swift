import Foundation
import HootCore

@MainActor
func previewTests() {
    Harness.test("Bash preview shows the full command") {
        let cmd = "git push --force origin main && rm -rf build"
        let p = ToolPreviewBuilder.build(toolName: "Bash", input: .object(["command": .string(cmd), "description": .string("Push")]))
        Harness.expectEqual(p.command, cmd)
        Harness.expectEqual(p.purpose, "Push")
        Harness.expect(!p.hadHiddenCharacters && !p.truncated, "clean")
    }

    Harness.test("hidden and bidi characters are made visible") {
        let sneaky = "echo safe \u{202E}fr- mr\u{202C} \u{200B}x\u{1B}[2K\r"
        let p = ToolPreviewBuilder.build(toolName: "Bash", input: .object(["command": .string(sneaky)]))
        Harness.expect(p.hadHiddenCharacters, "flagged")
        let shown = p.command ?? ""
        for code in ["202E", "202C", "200B", "001B", "000D"] {
            Harness.expect(shown.contains("⟨U+\(code)⟩"), "U+\(code) visible")
        }
        Harness.expect(!shown.unicodeScalars.contains { $0.value == 0x202E || $0.value == 0x1B }, "raw chars gone")
        Harness.expectEqual(SafeText.visible("tab\tand\nnewline ok").changed, false)
        Harness.expect(SafeText.visible("tag\u{E0041}").changed, "tag characters flagged")
        Harness.expect(ToolPreviewBuilder.build(toolName: "Edit", input: .object(["file_path": .string("/a"), "old_string": .string("x"),
                                                                              "new_string": .string("y\u{2066}")])).hadHiddenCharacters,
                       "hidden chars in diffs flagged")
    }

    Harness.test("Edit preview is a diff with context") {
        let old = "a\nb\nc\nd\ne\nf\ng"
        let new = "a\nb\nc\nD\ne\nf\ng"
        let p = ToolPreviewBuilder.build(toolName: "Edit", input: .object([
            "file_path": .string("/p/x.swift"), "old_string": .string(old), "new_string": .string(new)]))
        Harness.expectEqual(p.filePath, "/p/x.swift")
        Harness.expectEqual(p.diff, [
            DiffLine(.context, "a"), DiffLine(.context, "b"), DiffLine(.context, "c"),
            DiffLine(.removed, "d"), DiffLine(.added, "D"),
            DiffLine(.context, "e"), DiffLine(.context, "f"), DiffLine(.context, "g"),
        ])
    }

    Harness.test("Write preview is all additions, capped") {
        let content = (1...1000).map { "line \($0)" }.joined(separator: "\n")
        let p = ToolPreviewBuilder.build(toolName: "Write", input: .object(["file_path": .string("/f"), "content": .string(content)]))
        Harness.expect(p.truncated, "truncated")
        Harness.expectEqual(p.diff?.count, ToolPreviewBuilder.maxDiffLines)
        Harness.expect(p.diff?.allSatisfy { $0.kind == .added } ?? false, "all added")
    }

    Harness.test("MultiEdit, unknown and MCP tools") {
        let multi = ToolPreviewBuilder.build(toolName: "MultiEdit", input: .object(["file_path": .string("/f"), "edits": .array([
            .object(["old_string": .string("a"), "new_string": .string("b")]),
            .object(["old_string": .string("c"), "new_string": .string("d")]),
        ])]))
        Harness.expectEqual(multi.diff?.filter { $0.kind == .gap }.count, 1)
        let mcp = ToolPreviewBuilder.build(toolName: "mcp__github__create_issue", input: .object(["title": .string("Bug")]))
        Harness.expectEqual(mcp.detail, "title: Bug")
        let none = ToolPreviewBuilder.build(toolName: "Bash", input: nil)
        Harness.expectEqual(none.command, "")
        let huge = ToolPreviewBuilder.build(toolName: "WebSearch", input: .object(["query": .string(String(repeating: "q", count: 50_000))]))
        Harness.expect(huge.truncated && (huge.detail?.count ?? 0) < 21_000, "detail capped")
    }

    Harness.test("line diff edge cases") {
        Harness.expectEqual(LineDiff.diff(old: "same", new: "same", maxOutputLines: 10).lines, [DiffLine(.context, "same")])
        Harness.expectEqual(LineDiff.diff(old: "", new: "", maxOutputLines: 10).lines, [])
        Harness.expectEqual(LineDiff.diff(old: "x", new: "", maxOutputLines: 10).lines, [DiffLine(.removed, "x")])
        let a = (0..<1000).map { "a\($0)" }.joined(separator: "\n")
        let b = (0..<1000).map { "b\($0)" }.joined(separator: "\n")
        let started = Date()
        let big = LineDiff.diff(old: a, new: b, maxOutputLines: 5000)
        Harness.expect(Date().timeIntervalSince(started) < 1, "large diffs stay fast")
        Harness.expectEqual(big.lines.count, 2000)
        let long = (1...10).map(String.init).joined(separator: "\n")
        let changed = long.replacingOccurrences(of: "\n5\n", with: "\nfive\n")
        let d = LineDiff.diff(old: long, new: changed, maxOutputLines: 100).lines
        Harness.expectEqual(d.first, DiffLine(.gap, ""))
        Harness.expectEqual(d.last, DiffLine(.gap, ""))
    }
}

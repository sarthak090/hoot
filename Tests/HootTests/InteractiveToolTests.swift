import Foundation
import HootCore

/// AskUserQuestion and ExitPlanMode need an answer, not a bare "allow". Shapes below are
/// the real ones Claude Code 2.1.301 sent to a PermissionRequest hook.
@MainActor
func interactiveToolTests() {
    let questions: JSONValue = .array([
        .object(["question": .string("Which color?"), "header": .string("Color"), "multiSelect": .bool(false),
                 "options": .array([.object(["label": .string("Red"), "description": .string("Choose red")]),
                                    .object(["label": .string("Blue"), "description": .string("Choose blue")])])]),
        .object(["question": .string("Toppings\u{202E}?"), "header": .string("Food"), "multiSelect": .bool(true),
                 "options": .array([.object(["label": .string("Cheese")]), .object(["label": .string("Olives")])])]),
    ])

    Harness.test("questions become a question card, not JSON") {
        let p = ToolPreviewBuilder.build(toolName: "AskUserQuestion", input: .object(["questions": questions]))
        Harness.expectEqual(p.kind, .question)
        Harness.expect(p.detail == nil, "no raw JSON")
        Harness.expectEqual(p.questions?.count, 2)
        Harness.expectEqual(p.questions?.first?.options.map(\.label), ["Red", "Blue"])
        Harness.expectEqual(p.questions?.first?.options.first?.detail, "Choose red")
        Harness.expectEqual(p.questions?.last?.multiSelect, true)
        // Shown sanitized, answered with the original text.
        Harness.expectEqual(p.questions?.last?.question, "Toppings⟨U+202E⟩?")
        Harness.expectEqual(p.questions?.last?.rawQuestion, "Toppings\u{202E}?")
        Harness.expect(p.hadHiddenCharacters, "hidden characters flagged")
    }

    Harness.test("answers are echoed in the documented shape") {
        let out = try JSONDecoder().decode(JSONValue.self, from: PermissionDecision.answer(
            questions: questions, answers: ["Which color?": "Blue", "Toppings\u{202E}?": "Cheese, Olives"]).hookOutput())
        let d = out["hookSpecificOutput"]?["decision"]
        Harness.expectEqual(d?["behavior"], .string("allow"))
        Harness.expectEqual(d?["updatedInput"]?["questions"], questions)
        Harness.expectEqual(d?["updatedInput"]?["answers"]?["Which color?"], .string("Blue"))
        Harness.expectEqual(d?["updatedInput"]?["answers"]?["Toppings\u{202E}?"], .string("Cheese, Olives"))
    }

    Harness.test("plans become a plan card; approve echoes, feedback denies") {
        let input: JSONValue = .object(["plan": .string("## Plan\n1. Create plan-test.txt"), "planFilePath": .string("/Users/me/.claude/plans/p.md")])
        let p = ToolPreviewBuilder.build(toolName: "ExitPlanMode", input: input)
        Harness.expectEqual(p.kind, .plan)
        Harness.expectEqual(p.plan, "## Plan\n1. Create plan-test.txt")
        let approve = try JSONDecoder().decode(JSONValue.self, from: PermissionDecision.approvePlan(toolInput: input).hookOutput())
        Harness.expectEqual(approve["hookSpecificOutput"]?["decision"]?["updatedInput"], input)
        let keep = try JSONDecoder().decode(JSONValue.self, from: PermissionDecision.planFeedback(" add tests ").hookOutput())
        Harness.expectEqual(keep["hookSpecificOutput"]?["decision"]?["behavior"], .string("deny"))
        Harness.expectEqual(keep["hookSpecificOutput"]?["decision"]?["message"],
                            .string("The user reviewed the plan in Hoot and wants changes: add tests"))
        Harness.expectEqual(ToolPreviewBuilder.build(toolName: "Bash", input: nil).kind, .permission)
    }

    Harness.test("unknown tools read as key: value, not JSON") {
        let p = ToolPreviewBuilder.build(toolName: "mcp__github__create_issue",
                                         input: .object(["title": .string("Bug"), "labels": .array([.string("ui")]), "count": .number(2), "draft": .bool(true)]))
        Harness.expectEqual(p.detail, "count: 2\ndraft: yes\nlabels: [\"ui\"]\ntitle: Bug")
    }

    Harness.test("a plan answered in the terminal is detected") {
        // The transcript's copy of the call has no plan (Claude Code injects it only for hooks).
        var m = TranscriptMatcher(toolName: "ExitPlanMode", toolInput: .object(["plan": .string("## Plan"), "planFilePath": .string("/p.md")]))
        m.consumeBacklog([])
        Harness.expect(!m.consumeNew(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"p1","name":"ExitPlanMode","input":{}}]}}"#), "call seen")
        Harness.expect(m.consumeNew(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"p1","content":"approved"}]}}"#), "settled")
    }
}

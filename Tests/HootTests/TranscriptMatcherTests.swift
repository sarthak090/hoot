import HootCore

@MainActor
func transcriptMatcherTests() {
    func use(_ id: String, _ cmd: String, type: String = "assistant") -> Substring {
        Substring(#"{"type":"\#(type)","message":{"content":[{"type":"tool_use","id":"\#(id)","name":"Bash","input":{"command":"\#(cmd)","description":"d"}}]}}"#)
    }
    func result(_ id: String, type: String = "user") -> Substring {
        Substring(#"{"type":"\#(type)","message":{"content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"ok"}]}}"#)
    }
    let input = JSONValue.object(["command": .string("npm test"), "description": .string("other text is fine")])

    Harness.test("targets the newest unanswered matching call") {
        var m = TranscriptMatcher(toolName: "Bash", toolInput: input)
        m.consumeBacklog([use("t1", "npm test"), result("t1"), use("t2", "ls"), use("t3", "npm test")])
        Harness.expectEqual(m.targetID, "t3")
        Harness.expect(!m.consumeNew(result("t2")), "other call's result ignored")
        Harness.expect(m.consumeNew(result("t3")), "own result settles it")
    }

    Harness.test("ignores request-blob copies and malformed lines") {
        var m = TranscriptMatcher(toolName: "Bash", toolInput: input)
        m.consumeBacklog([use("b1", "npm test", type: "api-request-blob"), "{not json", "", #"{"type":"user","message":"x"}"#])
        Harness.expect(m.targetID == nil, "no target from blobs")
        Harness.expect(!m.consumeNew(result("b1", type: "api-request-blob")), "blob result ignored")
        Harness.expect(!m.consumeNew(use("n1", "npm test")), "call appears after the request")
        Harness.expectEqual(m.targetID, "n1")
        Harness.expect(m.consumeNew(result("n1")), "then its result")
    }

    Harness.test("an interrupted older call doesn't block the real one") {
        var m = TranscriptMatcher(toolName: "Bash", toolInput: input)
        m.consumeBacklog([use("old", "npm test")])
        Harness.expectEqual(m.targetID, "old")
        Harness.expect(!m.consumeNew(use("new", "npm test")), "new call")
        Harness.expectEqual(m.targetID, "new")
        Harness.expect(m.consumeNew(result("new")), "settled by the new call's result")
    }

    Harness.test("different tool or input never matches") {
        var m = TranscriptMatcher(toolName: "Bash", toolInput: input)
        m.consumeBacklog([use("x", "npm test --watch")])
        Harness.expect(m.targetID == nil, "different command")
        var e = TranscriptMatcher(toolName: "Edit", toolInput: .object(["file_path": .string("/a")]))
        e.consumeBacklog([use("y", "npm test")])
        Harness.expect(e.targetID == nil, "different tool")
    }
}

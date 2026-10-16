import Foundation
import HootCore

@MainActor
func hookProtocolTests() {
    let auth = "Bearer " + String(repeating: "ab", count: 32)
    func head(_ raw: String) -> HTTPHeadParse { HTTPParser.parseHead(Data(raw.utf8)) }
    func validHead(_ extra: String = "", method: String = "POST", path: String = "/permission",
                   length: String? = "2", authorization: String? = nil) -> HTTPRequestHead? {
        var raw = "\(method) \(path) HTTP/1.1\r\nHost: nudge\r\n"
        if let a = authorization ?? auth as String? { raw += "Authorization: \(a)\r\n" }
        if let length { raw += "Content-Length: \(length)\r\n" }
        raw += extra + "\r\n{}"
        if case .complete(let h) = head(raw) { return h }
        return nil
    }

    Harness.test("HTTP head parsing") {
        Harness.expectEqual(head("POST /event HTTP/1.1\r\nHost: x\r\n"), .needMore)
        guard case .complete(let h) = head("POST /event HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n{}") else {
            return Harness.expect(false, "complete head")
        }
        Harness.expectEqual(h.method, "POST")
        Harness.expectEqual(h.path, "/event")
        Harness.expectEqual(h.headers["content-length"], "2")
        Harness.expectEqual(h.bodyOffset, 52)
        Harness.expectEqual(head("POST /a HTTP/1.1\r\nA: 1\r\na: 2\r\n\r\n"), .invalid(status: 400))
        Harness.expectEqual(head("POST /a HTTP/1.1\r\nno colon\r\n\r\n"), .invalid(status: 400))
        Harness.expectEqual(head("POST /a HTTP/1.1\r\n folded: x\r\n\r\n"), .invalid(status: 400))
        Harness.expectEqual(head("POST a HTTP/1.1\r\n\r\n"), .invalid(status: 400))
        Harness.expectEqual(head("POST /a HTTP/2\r\n\r\n"), .invalid(status: 400))
        Harness.expectEqual(head("POST /a  HTTP/1.1\r\n\r\n"), .invalid(status: 400))
        Harness.expectEqual(head(String(repeating: "x", count: HTTPParser.maxHeaderBytes + 1)), .invalid(status: 431))
        let big = "POST /a HTTP/1.1\r\nX: " + String(repeating: "y", count: HTTPParser.maxHeaderBytes) + "\r\n\r\n"
        Harness.expectEqual(head(big), .invalid(status: 431))
        Harness.expectEqual(HTTPParser.parseHead(Data([0x50, 0xFF, 0xFE, 0x0D, 0x0A, 0x0D, 0x0A])), .invalid(status: 400))
    }

    Harness.test("request validation: auth first, then browser checks, then shape") {
        func status(_ h: HTTPRequestHead?) -> Int? {
            guard let h else { return -1 }
            if case .failure(let e) = HookRequestValidator.validate(h, expectedAuthorization: auth) { return e.status }
            return nil
        }
        Harness.expect(status(validHead()) == nil, "valid request accepted")
        Harness.expect(status(validHead(path: "/event")) == nil, "event route accepted")
        Harness.expectEqual(status(validHead(authorization: "Bearer wrong")), 401)
        Harness.expectEqual(status(validHead(authorization: auth + "x")), 401)
        Harness.expectEqual(status(validHead(authorization: String(auth.dropLast()))), 401)
        Harness.expectEqual(status(validHead(authorization: "bearer " + String(repeating: "ab", count: 32))), 401)
        // Unauthenticated requests learn nothing else about the server.
        Harness.expectEqual(status(validHead(method: "GET", authorization: "nope")), 401)
        Harness.expectEqual(status(validHead("Origin: https://evil.example\r\n")), 403)
        Harness.expectEqual(status(validHead("Sec-Fetch-Mode: no-cors\r\n")), 403)
        Harness.expectEqual(status(validHead(method: "GET")), 405)
        Harness.expectEqual(status(validHead(path: "/permission/../x")), 404)
        Harness.expectEqual(status(validHead(path: "/permission?x=1")), 404)
        Harness.expectEqual(status(validHead("Transfer-Encoding: chunked\r\n")), 411)
        Harness.expectEqual(status(validHead(length: nil)), 411)
        Harness.expectEqual(status(validHead(length: "+2")), 400)
        Harness.expectEqual(status(validHead(length: "02")), 400)
        Harness.expectEqual(status(validHead(length: "-1")), 400)
        Harness.expectEqual(status(validHead(length: "99999999999999999999999")), 400)
        Harness.expectEqual(status(validHead(length: String(HookRequestValidator.maxBodyBytes + 1))), 413)
        Harness.expect(status(validHead(length: String(HookRequestValidator.maxBodyBytes))) == nil, "max size allowed")
    }

    Harness.test("constant-time compare") {
        Harness.expect(HookRequestValidator.constantTimeEquals("abc", "abc"), "equal")
        Harness.expect(!HookRequestValidator.constantTimeEquals("abd", "abc"), "different")
        Harness.expect(!HookRequestValidator.constantTimeEquals("ab", "abc"), "prefix")
        Harness.expect(!HookRequestValidator.constantTimeEquals("abcd", "abc"), "longer")
        Harness.expect(!HookRequestValidator.constantTimeEquals("", "abc"), "empty")
    }

    Harness.test("decision output matches the documented format") {
        func parse(_ d: PermissionDecision) -> JSONValue? { try? JSONDecoder().decode(JSONValue.self, from: d.hookOutput()) }
        let allow = parse(.allow(updatedPermissions: []))
        Harness.expectEqual(allow?["hookSpecificOutput"]?["hookEventName"], .string("PermissionRequest"))
        Harness.expectEqual(allow?["hookSpecificOutput"]?["decision"]?["behavior"], .string("allow"))
        Harness.expect(allow?["hookSpecificOutput"]?["decision"]?["updatedPermissions"] == nil, "no empty updates")
        Harness.expect(String(decoding: PermissionDecision.allow(updatedPermissions: []).hookOutput(), as: UTF8.self)
            .hasPrefix("{\"hookSpecificOutput\":"), "hook script prefix check matches")

        let rule: JSONValue = .object(["type": .string("addRules"), "behavior": .string("allow"), "destination": .string("session"),
                                       "rules": .array([.object(["toolName": .string("Bash"), "ruleContent": .string("npm test:*")])])])
        let always = parse(.allow(updatedPermissions: [rule]))
        Harness.expectEqual(always?["hookSpecificOutput"]?["decision"]?["updatedPermissions"], .array([rule]))

        let deny = parse(.deny(reason: "  use pnpm  \n"))
        Harness.expectEqual(deny?["hookSpecificOutput"]?["decision"]?["behavior"], .string("deny"))
        Harness.expectEqual(deny?["hookSpecificOutput"]?["decision"]?["message"],
                            .string("The user denied this from the Hoot menu bar app: use pnpm"))
        Harness.expect(deny?["hookSpecificOutput"]?["decision"]?["interrupt"] == nil, "deny does not interrupt")
        let plain = parse(.deny(reason: nil))?["hookSpecificOutput"]?["decision"]?["message"]?.stringValue ?? ""
        Harness.expect(!plain.isEmpty, "deny always explains")
        let long = parse(.deny(reason: String(repeating: "x", count: 5000)))?["hookSpecificOutput"]?["decision"]?["message"]?.stringValue ?? ""
        Harness.expect(long.count < PermissionDecision.maxReasonLength + 100, "reason capped")
        let quoted = parse(.deny(reason: "say \"no\" \\ </script>"))?["hookSpecificOutput"]?["decision"]?["message"]?.stringValue ?? ""
        Harness.expect(quoted.hasSuffix("say \"no\" \\ </script>"), "reason JSON-escaped, round-trips")
    }

    Harness.test("permission options: only grants the user can understand, echoed verbatim") {
        let suggestions: [JSONValue] = [
            .object(["type": .string("addRules"), "behavior": .string("allow"), "destination": .string("localSettings"),
                     "rules": .array([.object(["toolName": .string("Bash"), "ruleContent": .string("npm test:*")])])]),
            .object(["type": .string("addRules"), "behavior": .string("deny"), "destination": .string("session"),
                     "rules": .array([.object(["toolName": .string("Bash")])])]),
            .object(["type": .string("setMode"), "mode": .string("bypassPermissions"), "destination": .string("session")]),
            .object(["type": .string("setMode"), "mode": .string("acceptEdits"), "destination": .string("session")]),
            .object(["type": .string("addDirectories"), "directories": .array([.string("/tmp/x")]), "destination": .string("session")]),
            .object(["type": .string("removeRules")]),
            .string("garbage"),
        ]
        let options = PermissionOptions.from(suggestions)
        Harness.expectEqual(options.map(\.label), [
            "Always allow Bash(npm test:*) in this project (local settings)",
            "Allow all edits for this session",
            "Always allow access to /tmp/x for this session",
        ])
        Harness.expectEqual(options.map(\.id), [0, 3, 4])
        Harness.expectEqual(options.first?.suggestion, suggestions[0])
        Harness.expect(PermissionOptions.from(nil).isEmpty, "nil suggestions")
    }

    Harness.test("hook payload decoding is tolerant") {
        let doc = """
        {"session_id":"abc123","transcript_path":"/Users/x/.claude/projects/p/t.jsonl","cwd":"/Users/x/my-project",
         "permission_mode":"default","hook_event_name":"PermissionRequest","tool_name":"Bash",
         "tool_input":{"command":"rm -rf node_modules","description":"Remove node_modules directory","timeout":120000},
         "permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -rf node_modules"}],
         "behavior":"allow","destination":"localSettings"}], "brand_new_field": {"x": [1,2]}}
        """
        let e = HookEvent.decode(Data(doc.utf8))
        Harness.expectEqual(e?.toolName, "Bash")
        Harness.expectEqual(e?.projectName, "my-project")
        Harness.expectEqual(e?.toolInput?["command"], .string("rm -rf node_modules"))
        Harness.expectEqual(e?.toolInput?["timeout"], .number(120000))
        Harness.expectEqual(e?.permissionSuggestions?.count, 1)
        let odd = HookEvent.decode(Data(#"{"cwd": 5, "message": null, "tool_input": "x"}"#.utf8))
        Harness.expect(odd != nil, "wrong types don't fail the whole event")
        Harness.expectEqual(odd?.projectName, "Claude Code")
        Harness.expect(HookEvent.decode(Data("not json".utf8)) == nil, "garbage rejected")
        Harness.expect(HookEvent.decode(Data("[]".utf8)) == nil, "non-object rejected")
        Harness.expectEqual(HookEvent.decode(Data(#"{"cwd":"/"}"#.utf8))?.projectName, "/")
        Harness.expect(AttentionNotificationTypes.needsAttention("idle_prompt"), "idle needs attention")
        Harness.expect(!AttentionNotificationTypes.needsAttention("auth_success"), "auth_success doesn't")
    }

    Harness.test("JSON numbers round-trip without becoming floats") {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let v = JSONValue.object(["a": .number(3), "b": .number(1.5), "c": .bool(true)])
        Harness.expectEqual(String(decoding: try enc.encode(v), as: UTF8.self), #"{"a":3,"b":1.5,"c":true}"#)
    }
}

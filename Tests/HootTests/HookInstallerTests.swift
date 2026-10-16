import Foundation
import HootCore

@MainActor
func hookInstallerTests() {
    let config = HookInstaller.Config(scriptPath: "/Users/me/.claude/hooks/hoot.sh", answerTimeout: 300)
    // Shaped like a real user file: other settings, an MCP server with a secret, another tool's hooks.
    let original = """
    {
      "enabledPlugins": {
        "swift-lsp@claude-plugins-official": true
      },
      "effortLevel": "high",
      "mcpServers": {
        "x": {
          "command": "npx",
          "env": {
            "KEY": "s3cr\\"et\\\\/é😀"
          }
        }
      },
      "hooks": {
        "PostToolUse": [
          {
            "matcher": "Edit|Write",
            "hooks": [
              {
                "type": "command",
                "command": "/path/to/lint.sh"
              }
            ]
          }
        ],
        "Notification": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "say done",
                "timeout": 5.0
              }
            ]
          }
        ]
      },
      "cleanupPeriodDays": 1e2
    }

    """

    Harness.test("ordered JSON round-trips Claude Code's own format byte for byte") {
        let parsed = try OrderedJSON.parse(original)
        Harness.expectEqual(parsed.formatted() + "\n", original)
        let compact = #"{"b":1,"a":[1,2,{}],"c":[],"d":"\u0001\t","e":"\u00e9\ud83d\ude00"}"#
        Harness.expectEqual(try OrderedJSON.parse(compact).formatted(), """
        {
          "b": 1,
          "a": [
            1,
            2,
            {}
          ],
          "c": [],
          "d": "\\u0001\\t",
          "e": "é😀"
        }
        """)
    }

    Harness.test("ordered JSON rejects invalid input") {
        for bad in ["", "{", "{\"a\":1,}", "[1,]", "{'a':1}", "{\"a\":01}", "{\"a\":1} x", "{\"a\":\"\n\"}",
                    "{\"a\":\"\\x\"}", "{\"a\":\"\\ud800\"}", "{\"a\":-}", "{\"a\":1.}", "NaN", "// c\n{}"] {
            Harness.expect((try? OrderedJSON.parse(bad)) == nil, "rejects \(bad.debugDescription)")
        }
        let deep = String(repeating: "[", count: 10_000) + String(repeating: "]", count: 10_000)
        Harness.expect((try? OrderedJSON.parse(deep)) == nil, "deep nesting rejected, not a stack overflow")
    }

    Harness.test("install adds only Hoot's entries and keeps everything else") {
        let installed = try HookInstaller.install(into: original, config: config)
        let root = try OrderedJSON.parse(installed)
        let before = try OrderedJSON.parse(original)
        // Untouched top-level keys, in their original order.
        guard case .object(let pairs) = root, case .object(let oldPairs) = before else { return Harness.expect(false, "objects") }
        Harness.expectEqual(pairs.map(\.key), oldPairs.map(\.key))
        for key in ["enabledPlugins", "effortLevel", "mcpServers", "cleanupPeriodDays"] {
            Harness.expectEqual(root[key], before[key])
        }
        Harness.expectEqual(root["hooks"]?["PostToolUse"], before["hooks"]?["PostToolUse"])
        // Existing Notification hook kept first; Hoot appended.
        guard case .array(let notif)? = root["hooks"]?["Notification"] else { return Harness.expect(false, "notification array") }
        Harness.expectEqual(notif.count, 2)
        Harness.expectEqual(notif.first, before["hooks"]?["Notification"].flatMap { if case .array(let a) = $0 { a.first } else { nil } })
        Harness.expectEqual(try HookInstaller.status(of: installed, config: config), .installed)
        let perm = root["hooks"]?["PermissionRequest"]
        Harness.expect(installed.contains(#""command": "'/Users/me/.claude/hooks/hoot.sh' permission""#), "permission command")
        Harness.expect(installed.contains(#""timeout": 315"#), "hook timeout outlasts the 300s wait")
        Harness.expect(perm != nil, "permission hook present")
        Harness.expect(installed.contains(#""async": true"#), "event hooks are async")
    }

    Harness.test("install then uninstall restores the file exactly") {
        let installed = try HookInstaller.install(into: original, config: config)
        Harness.expectEqual(try HookInstaller.uninstall(from: installed), original)
        let noHooks = "{\n  \"theme\": \"dark\"\n}\n"
        Harness.expectEqual(try HookInstaller.uninstall(from: HookInstaller.install(into: noHooks, config: config)), noHooks)
        let noNewline = "{\n  \"theme\": \"dark\"\n}"
        Harness.expectEqual(try HookInstaller.uninstall(from: HookInstaller.install(into: noNewline, config: config)), noNewline)
    }

    Harness.test("install is idempotent and updates an outdated entry") {
        let once = try HookInstaller.install(into: original, config: config)
        Harness.expectEqual(try HookInstaller.install(into: once, config: config), once)
        var longer = config
        longer.answerTimeout = 600
        Harness.expectEqual(try HookInstaller.status(of: once, config: longer), .outdated)
        let updated = try HookInstaller.install(into: once, config: longer)
        Harness.expectEqual(try HookInstaller.status(of: updated, config: longer), .installed)
        Harness.expect(updated.contains(#""timeout": 615"#) && !updated.contains(#""timeout": 315"#), "timeout replaced, not duplicated")
    }

    Harness.test("missing, empty and minimal files") {
        for text in [nil, "", "  \n", "{}"] as [String?] {
            let out = try HookInstaller.install(into: text, config: config)
            Harness.expectEqual(try HookInstaller.status(of: out, config: config), .installed)
            Harness.expect(out.hasSuffix(text == "{}" ? "}" : "}\n"), "newline convention for \(String(describing: text))")
        }
        Harness.expectEqual(try HookInstaller.status(of: nil, config: config), .notInstalled)
        let nothing = try HookInstaller.uninstall(from: nil)
        Harness.expect(nothing == nil, "nothing to uninstall")
        Harness.expectEqual(try HookInstaller.uninstall(from: "{\n  \"a\": 1\n}\n"), "{\n  \"a\": 1\n}\n")
    }

    Harness.test("a group shared with another tool keeps the other handler") {
        let shared = """
        {
          "hooks": {
            "Notification": [
              {
                "hooks": [
                  { "type": "command", "command": "say hi" },
                  { "type": "command", "command": "'/old/home/.claude/hooks/hoot.sh' event" }
                ]
              },
              { "hooks": [] }
            ]
          }
        }
        """
        let out = try HookInstaller.uninstall(from: shared) ?? ""
        let groups = try OrderedJSON.parse(out)["hooks"]?["Notification"]
        Harness.expectEqual(groups, .array([
            .object([("hooks", .array([.object([("type", .string("command")), ("command", .string("say hi"))])]))]),
            .object([("hooks", .array([]))]),
        ]))
        Harness.expectEqual(try HookInstaller.status(of: shared, config: config), .outdated)
    }

    Harness.test("refuses files it doesn't understand") {
        let cases: [(String, HookInstaller.Failure)] = [
            ("[]", .notAnObject),
            ("{\"hooks\": []}", .unexpectedType("\"hooks\"")),
            ("{\"hooks\": {\"Notification\": {}}}", .unexpectedType("\"hooks.Notification\"")),
        ]
        for (text, failure) in cases {
            do {
                _ = try HookInstaller.install(into: text, config: config)
                Harness.expect(false, "should refuse \(text)")
            } catch let e as HookInstaller.Failure {
                Harness.expectEqual(e, failure)
            }
        }
        do {
            _ = try HookInstaller.install(into: "{ broken", config: config)
            Harness.expect(false, "should refuse broken JSON")
        } catch HookInstaller.Failure.invalidJSON {
        }
    }

    Harness.test("shell quoting and disableAllHooks") {
        Harness.expectEqual(HookInstaller.command(scriptPath: "/Users/o'neil/.claude/hooks/hoot.sh", mode: "event"),
                            #"'/Users/o'\''neil/.claude/hooks/hoot.sh' event"#)
        Harness.expect(HookInstaller.hooksDisabled(in: "{\"disableAllHooks\": true}"), "detected")
        Harness.expect(!HookInstaller.hooksDisabled(in: "{\"disableAllHooks\": false}"), "false is fine")
        Harness.expect(!HookInstaller.hooksDisabled(in: nil), "missing file")
    }
}

/// Read-only check against a real file: `HOOT_REAL_SETTINGS=~/.claude/settings.json swift run HootTests`
@MainActor
func realSettingsRoundTrip() {
    guard let path = ProcessInfo.processInfo.environment["HOOT_REAL_SETTINGS"] else { return }
    Harness.test("round trip on \(path) (read-only)") {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let config = HookInstaller.Config(scriptPath: NSHomeDirectory() + "/.claude/hooks/hoot.sh", answerTimeout: 300)
        let installed = try HookInstaller.install(into: text, config: config)
        Harness.expectEqual(try HookInstaller.status(of: installed, config: config), .installed)
        Harness.expectEqual(try HookInstaller.uninstall(from: installed), text)
        let diff = LineDiff.diff(old: text, new: installed, maxOutputLines: 10_000).lines
        let removed = diff.filter { $0.kind == .removed }.map(\.text)
        let added = diff.filter { $0.kind == .added }.map(\.text)
        // The only allowed "removal" is a line that comes back with a trailing comma.
        Harness.expect(removed.allSatisfy { added.contains($0 + ",") }, "install only adds lines (plus a comma)")
        print("   install would add \(added.count) lines; changed \(removed.count) existing line(s) only by a trailing comma")
    }
}

/// Upgrading from pre-release builds that were called Nudge.
@MainActor
func migrationTests() {
    let config = HookInstaller.Config(scriptPath: "/Users/me/.claude/hooks/hoot.sh", answerTimeout: 300)
    let legacy = """
    {
      "hooks": {
        "Notification": [
          { "hooks": [ { "type": "command", "command": "say hi" } ] },
          { "hooks": [ { "type": "command", "command": "'/Users/me/.claude/hooks/nudge.sh' event", "timeout": 10, "async": true } ] }
        ],
        "PermissionRequest": [
          { "hooks": [ { "type": "command", "command": "'/Users/me/.claude/hooks/nudge.sh' permission", "timeout": 315 } ] }
        ]
      },
      "statusLine": { "type": "command", "command": "'/Users/me/.claude/hooks/nudge-statusline.sh'", "padding": 1 }
    }
    """
    Harness.test("pre-release hook entries are replaced, not duplicated") {
        Harness.expectEqual(try HookInstaller.status(of: legacy, config: config), .outdated)
        let upgraded = try HookInstaller.install(into: legacy, config: config)
        Harness.expect(!upgraded.contains("hooks/nudge.sh"), "old entries gone")
        Harness.expectEqual(upgraded.components(separatedBy: "hooks/hoot.sh' permission").count - 1, 1)
        Harness.expectEqual(upgraded.components(separatedBy: "hooks/hoot.sh' event").count - 1, 2)
        Harness.expect(upgraded.contains("say hi"), "other tools' hooks kept")
        Harness.expectEqual(try HookInstaller.status(of: upgraded, config: config), .installed)
    }
    Harness.test("pre-release statusline is re-pointed, keeping its options") {
        let script = "/Users/me/.claude/hooks/hoot-statusline.sh"
        Harness.expect(try StatusLineInstaller.isInstalled(in: legacy), "recognised as ours")
        let notCurrent = try StatusLineInstaller.isCurrent(in: legacy, scriptPath: script)
        Harness.expect(!notCurrent, "but not current")
        let (text, replaced) = try StatusLineInstaller.install(into: legacy, scriptPath: script)
        Harness.expect(replaced == nil, "nothing to save: it was already ours")
        let root = try OrderedJSON.parse(text)
        Harness.expectEqual(root["statusLine"]?["command"]?.stringValue, "'\(script)'")
        Harness.expectEqual(root["statusLine"]?["padding"], .number("1"))
        let nowCurrent = try StatusLineInstaller.isCurrent(in: text, scriptPath: script)
        Harness.expect(nowCurrent, "current after update")
    }
}

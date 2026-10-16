import Darwin
import Foundation
import HootCore

@MainActor
func hookFilesTests() {
    let fm = FileManager.default
    func tempClaudeDir() throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("hoot-tests-\(UUID().uuidString)/.claude", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    func mode(_ url: URL) -> mode_t {
        var st = stat()
        return stat(url.path, &st) == 0 ? st.st_mode & 0o777 : 0
    }
    func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    let script = "#!/bin/bash\n# Hoot hook for Claude Code. Installed by Hoot.app (test)\nexit 0\n"
    let config = { (files: HookFiles) in HookInstaller.Config(scriptPath: files.installedScript.path, answerTimeout: 300) }

    Harness.test("install: backup first, then script, then settings; modes preserved") {
        let files = HookFiles(claudeDir: try tempClaudeDir())
        defer { try? fm.removeItem(at: files.claudeDir.deletingLastPathComponent()) }
        let original = "{\n  \"secret\": \"k\"\n}\n"
        try original.write(to: files.settingsFile, atomically: true, encoding: .utf8)
        chmod(files.settingsFile.path, 0o640)
        let newText = try HookInstaller.install(into: original, config: config(files))
        let backup = try files.apply(.install, settingsURL: files.resolvedSettingsURL(), originalText: original,
                                     newText: newText, script: script)
        Harness.expectEqual(read(files.settingsFile), newText)
        Harness.expectEqual(mode(files.settingsFile), 0o640)
        Harness.expectEqual(read(files.installedScript), script)
        Harness.expectEqual(mode(files.installedScript), 0o700)
        Harness.expectEqual(backup.flatMap(read), original)
        Harness.expectEqual(backup.map(mode), 0o600)
        Harness.expectEqual(mode(files.backupsDir), 0o700)
        let leftovers = try fm.contentsOfDirectory(atPath: files.claudeDir.path).filter { $0.contains(".hoot-") }
        Harness.expect(leftovers.isEmpty, "no temp files left behind")
    }

    Harness.test("refuses when settings.json changed after review; nothing written") {
        let files = HookFiles(claudeDir: try tempClaudeDir())
        defer { try? fm.removeItem(at: files.claudeDir.deletingLastPathComponent()) }
        try "{}\n".write(to: files.settingsFile, atomically: true, encoding: .utf8)
        let newText = try HookInstaller.install(into: "{}\n", config: config(files))
        try "{\n  \"edited\": true\n}\n".write(to: files.settingsFile, atomically: true, encoding: .utf8)
        do {
            try files.apply(.install, settingsURL: files.settingsFile, originalText: "{}\n", newText: newText, script: script)
            Harness.expect(false, "should refuse")
        } catch let e as HookFiles.Failure {
            Harness.expectEqual(e, .changedSinceReview)
        }
        Harness.expectEqual(read(files.settingsFile), "{\n  \"edited\": true\n}\n")
        Harness.expect(!fm.fileExists(atPath: files.installedScript.path), "script not installed")
        Harness.expect(!fm.fileExists(atPath: files.backupsDir.path), "no backup made")
    }

    Harness.test("refuses to overwrite someone else's hoot.sh") {
        let files = HookFiles(claudeDir: try tempClaudeDir())
        defer { try? fm.removeItem(at: files.claudeDir.deletingLastPathComponent()) }
        try fm.createDirectory(at: files.hooksDir, withIntermediateDirectories: true)
        try "#!/bin/bash\necho mine\n".write(to: files.installedScript, atomically: true, encoding: .utf8)
        let newText = try HookInstaller.install(into: nil, config: config(files))
        do {
            try files.apply(.install, settingsURL: files.settingsFile, originalText: nil, newText: newText, script: script)
            Harness.expect(false, "should refuse")
        } catch let e as HookFiles.Failure {
            Harness.expectEqual(e, .foreignScript(files.installedScript.path))
        }
        Harness.expectEqual(read(files.installedScript), "#!/bin/bash\necho mine\n")
        Harness.expect(!fm.fileExists(atPath: files.settingsFile.path), "settings not created")
        // And uninstall leaves it alone too.
        try files.apply(.uninstall, settingsURL: files.settingsFile, originalText: nil, newText: "", script: script)
        Harness.expectEqual(read(files.installedScript), "#!/bin/bash\necho mine\n")
    }

    Harness.test("symlinked settings.json: target updated, link kept") {
        let files = HookFiles(claudeDir: try tempClaudeDir())
        defer { try? fm.removeItem(at: files.claudeDir.deletingLastPathComponent()) }
        let dotfiles = files.claudeDir.deletingLastPathComponent().appendingPathComponent("dotfiles-settings.json")
        try "{}\n".write(to: dotfiles, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: files.settingsFile, withDestinationURL: dotfiles)
        let target = files.resolvedSettingsURL()
        Harness.expectEqual(target.lastPathComponent, "dotfiles-settings.json")
        let newText = try HookInstaller.install(into: "{}\n", config: config(files))
        try files.apply(.install, settingsURL: target, originalText: "{}\n", newText: newText, script: script)
        Harness.expect((try? fm.destinationOfSymbolicLink(atPath: files.settingsFile.path)) != nil, "still a symlink")
        Harness.expectEqual(read(dotfiles), newText)
    }

    Harness.test("full install then uninstall leaves the folder as it was (plus a backup)") {
        let files = HookFiles(claudeDir: try tempClaudeDir())
        defer { try? fm.removeItem(at: files.claudeDir.deletingLastPathComponent()) }
        let original = "{\n  \"theme\": \"dark\"\n}\n"
        try original.write(to: files.settingsFile, atomically: true, encoding: .utf8)
        let installed = try HookInstaller.install(into: original, config: config(files))
        try files.apply(.install, settingsURL: files.settingsFile, originalText: original, newText: installed, script: script)
        let removed = try HookInstaller.uninstall(from: installed) ?? ""
        try files.apply(.uninstall, settingsURL: files.settingsFile, originalText: installed, newText: removed, script: script)
        Harness.expectEqual(read(files.settingsFile), original)
        Harness.expect(!fm.fileExists(atPath: files.installedScript.path), "script removed")
        Harness.expectEqual(try fm.contentsOfDirectory(atPath: files.backupsDir.path).count, 2)
    }

    Harness.test("uninstall with no settings file creates nothing") {
        let files = HookFiles(claudeDir: try tempClaudeDir())
        defer { try? fm.removeItem(at: files.claudeDir.deletingLastPathComponent()) }
        try files.apply(.uninstall, settingsURL: files.settingsFile, originalText: nil, newText: "", script: script)
        Harness.expect(!fm.fileExists(atPath: files.settingsFile.path), "no empty settings.json created")
        Harness.expect(!fm.fileExists(atPath: files.backupsDir.path), "no backup folder")
    }

    Harness.test("rejects non-UTF-8 and oversized settings") {
        let files = HookFiles(claudeDir: try tempClaudeDir())
        defer { try? fm.removeItem(at: files.claudeDir.deletingLastPathComponent()) }
        try Data([0x7B, 0xFF, 0xFE, 0x7D]).write(to: files.settingsFile)
        do { _ = try files.readSettings(at: files.settingsFile); Harness.expect(false, "not utf8") } catch let e as HookFiles.Failure {
            Harness.expectEqual(e, .notUTF8)
        }
        try Data(count: HookFiles.maxSettingsBytes + 1).write(to: files.settingsFile)
        do { _ = try files.readSettings(at: files.settingsFile); Harness.expect(false, "too large") } catch let e as HookFiles.Failure {
            Harness.expectEqual(e, .tooLarge)
        }
    }
}

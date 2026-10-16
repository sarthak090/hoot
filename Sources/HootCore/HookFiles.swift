import Darwin
import Foundation

/// File operations for installing the hook, rooted at a Claude config directory
/// (normally ~/.claude) so they can be tested against a temporary one.
public struct HookFiles: Sendable {
    public let claudeDir: URL
    public var settingsFile: URL { claudeDir.appendingPathComponent("settings.json") }
    public var hooksDir: URL { claudeDir.appendingPathComponent("hooks", isDirectory: true) }
    public var installedScript: URL { hooksDir.appendingPathComponent("hoot.sh") }
    public var installedStatusLineScript: URL { hooksDir.appendingPathComponent("hoot-statusline.sh") }
    public var backupsDir: URL { claudeDir.appendingPathComponent("hoot-backups", isDirectory: true) }

    public static let maxSettingsBytes = 5 * 1024 * 1024
    /// Present in every script Hoot installs; anything without it isn't Hoot's to touch.
    public static let scriptHeader = "Installed by Hoot.app"
    /// Header of pre-release builds (then called Nudge).
    public static let legacyScriptHeader = "Installed by Nudge.app"
    public var legacyScripts: [URL] {
        [hooksDir.appendingPathComponent("nudge.sh"), hooksDir.appendingPathComponent("nudge-statusline.sh")]
    }

    public init(claudeDir: URL) {
        self.claudeDir = claudeDir
    }

    public enum Kind: Sendable { case install, uninstall }

    public enum Failure: LocalizedError, Equatable {
        case notUTF8
        case tooLarge
        case foreignScript(String)
        case changedSinceReview
        case writeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notUTF8: "settings.json isn't UTF-8 text. Hoot won't edit it."
            case .tooLarge: "settings.json is unexpectedly large (over 5 MB). Hoot won't edit it."
            case .foreignScript(let path): "\(path) exists but wasn't installed by Hoot. Move it away first."
            case .changedSinceReview: "settings.json changed after you reviewed it. Nothing was written."
            case .writeFailed(let path): "Could not write \(path)."
            }
        }
    }

    /// The real file to edit. Symlinks are followed so a dotfiles setup keeps its link.
    public func resolvedSettingsURL() -> URL {
        settingsFile.resolvingSymlinksInPath()
    }

    public func readSettings(at url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maxSettingsBytes else { throw Failure.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw Failure.notUTF8 }
        return text
    }

    public func installedScriptIsOurs(at url: URL? = nil) -> Bool {
        guard let text = try? String(contentsOf: url ?? installedScript, encoding: .utf8) else { return false }
        return text.contains(Self.scriptHeader) || text.contains(Self.legacyScriptHeader)
    }

    public func scriptMatches(_ bundled: String, at url: URL? = nil) -> Bool {
        (try? String(contentsOf: url ?? installedScript, encoding: .utf8)) == bundled
    }

    /// Applies a reviewed change. Order matters:
    /// 1. refuse if settings.json changed since review, or a foreign hoot.sh is in the way
    /// 2. back up the current settings (0600, in a 0700 folder: it may contain secrets)
    /// 3. install: script, then settings, so settings never point at a missing script;
    ///    uninstall: settings, then script.
    /// Returns the backup's URL, if one was made.
    @discardableResult
    public func apply(_ kind: Kind, settingsURL: URL, originalText: String?, newText: String,
                      script: String, scriptURL: URL? = nil, now: Date = Date()) throws -> URL? {
        let scriptURL = scriptURL ?? installedScript
        guard try readSettings(at: settingsURL) == originalText else { throw Failure.changedSinceReview }
        let ourScriptPresent = installedScriptIsOurs(at: scriptURL)
        if kind == .install, FileManager.default.fileExists(atPath: scriptURL.path), !ourScriptPresent {
            throw Failure.foreignScript(scriptURL.path)
        }
        let settingsChange = newText != (originalText ?? "")
        let backupURL = try originalText.flatMap { settingsChange ? try backup($0, now: now) : nil }
        switch kind {
        case .install:
            try makePrivateDirectory(hooksDir)
            try Self.writeAtomically(script, to: scriptURL, mode: 0o700)
            if settingsChange { try Self.writeAtomically(newText, to: settingsURL) }
        case .uninstall:
            if settingsChange { try Self.writeAtomically(newText, to: settingsURL) }
            if ourScriptPresent { try FileManager.default.removeItem(at: scriptURL) }
        }
        return backupURL
    }

    /// Deletes a pre-release script once settings no longer reference it. Only files that
    /// carry the pre-release header are touched.
    public func removeLegacyScript(_ url: URL, ifUnreferencedIn settingsText: String?) {
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains(Self.legacyScriptHeader),
              !(settingsText ?? "").contains("/.claude/hooks/\(url.lastPathComponent)")
        else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func backup(_ text: String, now: Date) throws -> URL {
        try makePrivateDirectory(backupsDir)
        let stamp = ISO8601DateFormatter.string(from: now, timeZone: .current,
                                                formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime])
            .replacingOccurrences(of: ":", with: "-")
        var url = backupsDir.appendingPathComponent("settings.json.\(stamp)")
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = backupsDir.appendingPathComponent("settings.json.\(stamp)-\(n)")
        }
        try Self.writeAtomically(text, to: url, mode: 0o600)
        return url
    }

    private func makePrivateDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
    }

    /// Temp file in the same directory, fsync, then rename: readers see the old file or
    /// the new one, never half of one. Keeps the existing file's mode (new files: 0600).
    public static func writeAtomically(_ text: String, to url: URL, mode: mode_t? = nil) throws {
        var st = stat()
        let existingMode: mode_t? = stat(url.path, &st) == 0 ? st.st_mode & 0o777 : nil
        let finalMode = mode ?? existingMode ?? 0o600
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).hoot-\(UUID().uuidString)")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.writeFailed(url.path) }
        var ok = fchmod(fd, finalMode) == 0
        let bytes = Array(text.utf8)
        var offset = 0
        while ok, offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { ok = false } else { offset += n }
        }
        ok = ok && fsync(fd) == 0
        close(fd)
        guard ok, rename(tmp.path, url.path) == 0 else {
            unlink(tmp.path)
            throw Failure.writeFailed(url.path)
        }
    }
}

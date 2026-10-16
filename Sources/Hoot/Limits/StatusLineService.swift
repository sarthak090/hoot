import Foundation
import HootCore
import Observation

/// Installs the opt-in statusline that feeds plan limits to Hoot. Wraps an existing
/// statusline instead of replacing it; uninstall restores the original exactly.
@MainActor
@Observable
final class StatusLineService {
    enum State: Equatable {
        case unknown, notInstalled, installed, outdated
        case error(String)
    }

    private(set) var state = State.unknown
    /// The user's own statusline command that Hoot is wrapping, if any.
    private(set) var wrappedCommand: String?
    var plan: HookPlan?
    var message: String?

    private var files: HookFiles { HookInstallService.files }
    static let originalFile = PrivateFiles.directory.appendingPathComponent("statusline-original.json")
    static let commandFile = PrivateFiles.directory.appendingPathComponent("statusline-command")

    func refresh() {
        wrappedCommand = try? String(contentsOf: Self.commandFile, encoding: .utf8)
        do {
            let text = try files.readSettings(at: files.resolvedSettingsURL())
            if try StatusLineInstaller.isInstalled(in: text) {
                let pathIsCurrent = try StatusLineInstaller.isCurrent(in: text, scriptPath: files.installedStatusLineScript.path)
                let bundled = try Self.bundledScript()
                let current = pathIsCurrent && files.scriptMatches(bundled, at: files.installedStatusLineScript)
                state = current ? .installed : .outdated
            } else {
                state = .notInstalled
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func prepare(_ kind: HookFiles.Kind) {
        message = nil
        do {
            let url = files.resolvedSettingsURL()
            let original = try files.readSettings(at: url)
            var notes: [String] = []
            let newText: String
            var replaced: OrderedJSON?
            switch kind {
            case .install:
                _ = try Self.bundledScript()
                (newText, replaced) = try StatusLineInstaller.install(into: original, scriptPath: files.installedStatusLineScript.path)
                if let cmd = replaced?["command"]?.stringValue {
                    notes.append("Wraps your current statusline (\(SafeText.visible(cmd).text)): its output stays exactly the same.")
                } else if try !StatusLineInstaller.isInstalled(in: original) {
                    notes.append("Adds a short statusline: model · context % · 5h % · 7d %. A custom statusline replaces Claude Code's footer hints such as “esc to interrupt”.")
                }
                notes.append("Copies the statusline script to \(files.installedStatusLineScript.path).")
            case .uninstall:
                newText = try StatusLineInstaller.uninstall(from: original, restoring: Self.savedOriginal()) ?? ""
                notes.append(Self.savedOriginal() != nil ? "Restores your previous statusline." : "Removes the statusline.")
            }
            let changes = newText != (original ?? "")
            if changes, original != nil { notes.append("Backs up the current file to \(files.backupsDir.path)/ first.") }
            notes.append("Running Claude Code sessions pick up the change automatically.")
            plan = HookPlan(kind: kind, settingsURL: url, originalText: original, newText: newText,
                            diff: changes ? LineDiff.diff(old: original ?? "", new: newText, maxOutputLines: 2000).lines : [],
                            notes: notes, replacedStatusLine: replaced)
        } catch {
            message = error.localizedDescription
        }
    }

    func apply(_ plan: HookPlan) {
        self.plan = nil
        do {
            let alreadyOurs = try StatusLineInstaller.isInstalled(in: plan.originalText)
            switch plan.kind {
            case .install:
                // Save what we wrap before settings point at the wrapper. If nothing is being
                // wrapped, clear any stale saved command so the wrapper can't run it.
                if !alreadyOurs {
                    if let replaced = plan.replacedStatusLine, let cmd = replaced["command"]?.stringValue {
                        try PrivateFiles.writePrivate(replaced.formatted() + "\n", to: Self.originalFile)
                        try PrivateFiles.writePrivate(cmd, to: Self.commandFile)
                    } else {
                        Self.removeSaved()
                    }
                }
                try files.apply(.install, settingsURL: plan.settingsURL, originalText: plan.originalText, newText: plan.newText,
                                script: try Self.bundledScript(), scriptURL: files.installedStatusLineScript)
                message = "Installed. Limits appear after Claude Code's next reply in a Pro/Max session."
                files.removeLegacyScript(files.legacyScripts[1], ifUnreferencedIn: plan.newText)
            case .uninstall:
                try files.apply(.uninstall, settingsURL: plan.settingsURL, originalText: plan.originalText, newText: plan.newText,
                                script: "", scriptURL: files.installedStatusLineScript)
                Self.removeSaved()
                message = "Uninstalled."
            }
        } catch HookFiles.Failure.changedSinceReview {
            message = "settings.json changed after you reviewed it, so nothing was written. Here is the new diff."
            prepare(plan.kind)
            return
        } catch {
            message = "Failed: \(error.localizedDescription)"
        }
        refresh()
    }

    static func savedOriginal() -> OrderedJSON? {
        guard let text = try? String(contentsOf: originalFile, encoding: .utf8) else { return nil }
        return try? OrderedJSON.parse(text)
    }

    private static func removeSaved() {
        try? FileManager.default.removeItem(at: originalFile)
        try? FileManager.default.removeItem(at: commandFile)
    }

    static func bundledScript() throws -> String {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("hooks/hoot-statusline.sh"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { throw HookInstallService.MissingScript() }
        return text
    }
}

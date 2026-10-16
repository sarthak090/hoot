import AppKit
import HootCore
import Observation

/// A reviewed, not-yet-applied change to ~/.claude/settings.json.
struct HookPlan: Identifiable {
    let id = UUID()
    let kind: HookFiles.Kind
    /// The real file written (symlinks resolved, so dotfile setups keep working).
    let settingsURL: URL
    /// Exact contents when the plan was made; nil if the file doesn't exist yet.
    let originalText: String?
    let newText: String
    let diff: [DiffLine]
    let notes: [String]
    /// Statusline plans only: the user's statusline being wrapped.
    var replacedStatusLine: OrderedJSON? = nil
}

/// Installs Hoot's hook script and settings entries, always via a reviewed diff and a backup.
@MainActor
@Observable
final class HookInstallService {
    enum State: Equatable {
        case unknown
        case notInstalled
        case installed
        /// Entries or script differ from what this version of Hoot would install.
        case outdated
        case error(String)
    }

    private(set) var state = State.unknown
    private(set) var hooksDisabled = false
    private(set) var lastBackup: URL?
    var plan: HookPlan?
    /// Outcome of the last install/uninstall, shown under the buttons.
    var message: String?

    @ObservationIgnored private let settings: SettingsStore
    nonisolated static let files = HookFiles(claudeDir: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude", isDirectory: true))
    private var files: HookFiles { Self.files }

    init(settings: SettingsStore) {
        self.settings = settings
    }

    private var config: HookInstaller.Config {
        HookInstaller.Config(scriptPath: files.installedScript.path, answerTimeout: settings.answerTimeout)
    }

    // MARK: - Status

    func refresh() {
        do {
            let text = try files.readSettings(at: files.resolvedSettingsURL())
            hooksDisabled = HookInstaller.hooksDisabled(in: text)
            switch try HookInstaller.status(of: text, config: config) {
            case .notInstalled: state = .notInstalled
            case .outdated: state = .outdated
            case .installed: state = files.scriptMatches(try Self.bundledScript()) ? .installed : .outdated
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Planning

    func prepare(_ kind: HookFiles.Kind) {
        message = nil
        do {
            let url = files.resolvedSettingsURL()
            let original = try files.readSettings(at: url)
            var notes: [String] = []
            let newText: String
            switch kind {
            case .install:
                _ = try Self.bundledScript()
                newText = try HookInstaller.install(into: original, config: config)
                notes.append("Copies the hook script to \(files.installedScript.path).")
                if HookInstaller.hooksDisabled(in: original) {
                    notes.append("“disableAllHooks” is true in this file, so no hooks run, including Hoot's.")
                }
            case .uninstall:
                newText = try HookInstaller.uninstall(from: original) ?? ""
                if files.installedScriptIsOurs() {
                    notes.append("Deletes \(files.installedScript.path).")
                }
            }
            let changes = newText != (original ?? "")
            if changes {
                notes.append(original == nil ? "Creates \(url.path)." : "Backs up the current file to \(files.backupsDir.path)/ first.")
            }
            notes.append("Running Claude Code sessions pick up the change automatically.")
            plan = HookPlan(kind: kind, settingsURL: url, originalText: original, newText: newText,
                            diff: changes ? LineDiff.diff(old: original ?? "", new: newText, maxOutputLines: 2000).lines : [],
                            notes: notes)
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: - Applying

    func apply(_ plan: HookPlan) {
        self.plan = nil
        do {
            let backup = try files.apply(plan.kind, settingsURL: plan.settingsURL, originalText: plan.originalText,
                                         newText: plan.newText, script: try Self.bundledScript())
            if let backup { lastBackup = backup }
            files.removeLegacyScript(files.legacyScripts[0], ifUnreferencedIn: plan.newText)
            message = plan.kind == .install
                ? "Installed. Claude Code will now check with Hoot before its permission dialogs."
                : "Uninstalled. Claude Code no longer contacts Hoot."
        } catch HookFiles.Failure.changedSinceReview {
            message = "settings.json changed after you reviewed it, so nothing was written. Here is the new diff."
            refresh()
            prepare(plan.kind)
            return
        } catch {
            message = "Failed: \(error.localizedDescription)"
        }
        refresh()
    }

    func revealBackups() {
        if let lastBackup {
            NSWorkspace.shared.activateFileViewerSelecting([lastBackup])
        } else if FileManager.default.fileExists(atPath: files.backupsDir.path) {
            NSWorkspace.shared.open(files.backupsDir)
        }
    }

    struct MissingScript: LocalizedError {
        var errorDescription: String? { "The hook script is missing from Hoot.app. Rebuild with scripts/build-app.sh." }
    }

    static func bundledScript() throws -> String {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("hooks/hoot.sh"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { throw MissingScript() }
        return text
    }
}

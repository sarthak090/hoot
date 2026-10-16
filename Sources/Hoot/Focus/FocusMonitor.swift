import AppKit

/// Tracks whether the user is looking at a terminal/editor from the configured list.
@MainActor
final class FocusMonitor {
    private let settings: SettingsStore
    private var observer: NSObjectProtocol?
    private(set) var lastTerminalBundleID: String?
    /// Called with `true` when a terminal becomes frontmost, `false` for any other app.
    /// Hoot itself becoming active (its dropdown or settings) is ignored.
    var onChange: ((Bool) -> Void)?

    init(settings: SettingsStore) {
        self.settings = settings
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let front, settings.terminalBundleIDs.contains(front) { lastTerminalBundleID = front }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated { self?.activated(bundleID) }
        }
    }

    var isTerminalFrontmost: Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return settings.terminalBundleIDs.contains(id)
    }

    private func activated(_ bundleID: String?) {
        guard bundleID != Bundle.main.bundleIdentifier else { return }
        let isTerminal = bundleID.map(settings.terminalBundleIDs.contains) ?? false
        if isTerminal { lastTerminalBundleID = bundleID }
        onChange?(isTerminal)
    }

    /// Brings the most recently used terminal forward, or the first running one from the list.
    func activateTerminal() {
        let running = NSWorkspace.shared.runningApplications
        let candidates = [lastTerminalBundleID].compactMap { $0 } + settings.terminalBundleIDs
        for id in candidates {
            if let app = running.first(where: { $0.bundleIdentifier == id }) {
                app.activate()
                return
            }
        }
    }
}

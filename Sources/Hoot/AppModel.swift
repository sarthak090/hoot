import AppKit
import HootCore
import Observation

/// Owns every long-lived piece of the app and starts the hook server.
@MainActor
@Observable
final class AppModel {
    enum ServerStatus: Equatable {
        case starting
        case running
        case failed(String)
    }

    let settings: SettingsStore
    let notifications: NotificationManager
    let focus: FocusMonitor
    let attention: AttentionCenter
    let hooks: HookInstallService
    let usage: UsageModel
    let limits: LimitsModel
    let statusLine: StatusLineService
    private(set) var serverStatus = ServerStatus.starting
    /// `--render-preview --demo`: hide anything that reflects this Mac's real setup.
    var demoMode = false
    @ObservationIgnored private var server: HookServer?

    init() {
        settings = SettingsStore()
        notifications = NotificationManager()
        focus = FocusMonitor(settings: settings)
        attention = AttentionCenter(settings: settings, notifications: notifications, focus: focus)
        hooks = HookInstallService(settings: settings)
        usage = UsageModel(settings: settings)
        limits = LimitsModel()
        statusLine = StatusLineService()
        notifications.configure()
    }

    func start() {
        do {
            try PrivateFiles.prepareDirectory()
            try PrivateFiles.acquireSingleInstanceLock()
            let authorization = try PrivateFiles.rotateToken()
            try PrivateFiles.writeHookConfig(waitSeconds: settings.answerTimeout)
            PrivateFiles.removeStaleSocket()
            let server = HookServer(expectedAuthorization: authorization) { [weak self] request, responder in
                Task { @MainActor in
                    guard let self else { return responder.respond(status: 503) }
                    if request.route == .statusline {
                        self.limits.handle(request.body, responder: responder)
                    } else {
                        self.attention.handle(request, responder: responder)
                    }
                }
            }
            try server.start(socketPath: PrivateFiles.socket.path)
            self.server = server
            serverStatus = .running
        } catch PrivateFiles.Failure.alreadyRunning {
            let alert = NSAlert()
            alert.messageText = "Hoot is already running"
            alert.informativeText = "Look for Hoot in the menu bar."
            NSApplication.shared.activate()
            alert.runModal()
            NSApplication.shared.terminate(nil)
        } catch {
            serverStatus = .failed(error.localizedDescription)
        }
        hooks.refresh()
        statusLine.refresh()
        usage.start()
        Task { await notifications.refreshAuthorization() }
    }

    /// Keeps the hook's wait in sync with the setting.
    func answerTimeoutChanged() {
        do {
            try PrivateFiles.writeHookConfig(waitSeconds: settings.answerTimeout)
        } catch {
            serverStatus = .failed("Could not save hook settings: \(error.localizedDescription)")
        }
        // The installed hook's timeout is derived from this, so it may now be out of date.
        hooks.refresh()
    }

    func shutdown() {
        usage.stop()
        attention.releaseAll()
        server?.stop()
        server = nil
        PrivateFiles.removeStaleSocket()
    }
}

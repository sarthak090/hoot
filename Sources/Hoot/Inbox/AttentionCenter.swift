import Foundation
import HootCore
import Observation

struct PendingRequest: Identifiable {
    let id: UUID
    let sessionID: String?
    let project: String
    let preview: ToolPreview
    let options: [PermissionOption]
    let receivedAt: Date
    let deadline: Date
    /// A notification was posted for it.
    var notified = false
    /// The user looked at the terminal since; don't keep badging for it.
    var acknowledged = false
}

struct RecentNotification: Identifiable {
    let id = UUID()
    let date: Date
    let project: String
    let text: String
    /// A permission request (vs. an idle/input alert).
    var isPermission = false
}

/// Decides what needs the user's attention: queues held permission requests, posts
/// notifications, escalates, and settles requests however they end.
@MainActor
@Observable
final class AttentionCenter {
    static let maxPending = 50
    static let maxRecent = 10
    /// Grace period after switching away from the terminal before notifying, so a quick
    /// Cmd-Tab doesn't fire notifications for something about to be answered.
    static let switchAwayGrace: Duration = .milliseconds(750)

    enum Outcome {
        case decided(PermissionDecision)
        case answeredElsewhere
        case timedOut
        case clientGone
    }

    private(set) var pending: [PendingRequest] = []
    private(set) var recent: [RecentNotification] = []
    /// A non-permission notification (idle, input needed) hasn't been looked at yet.
    private(set) var genericAlert = false

    var hasUnansweredAlert: Bool {
        genericAlert || pending.contains { $0.notified && !$0.acknowledged }
    }

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let notifications: NotificationManager
    @ObservationIgnored private let focus: FocusMonitor
    @ObservationIgnored private var responders: [UUID: Responder] = [:]
    @ObservationIgnored private var timeouts: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var watchers: [UUID: TranscriptWatcher] = [:]
    @ObservationIgnored private var escalations: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var switchAwayTask: Task<Void, Never>?

    init(settings: SettingsStore, notifications: NotificationManager, focus: FocusMonitor) {
        self.settings = settings
        self.notifications = notifications
        self.focus = focus
        focus.onChange = { [weak self] isTerminal in self?.focusChanged(terminalFrontmost: isTerminal) }
        notifications.onAction = { [weak self] action in self?.handle(action) }
    }

    // MARK: - Incoming hook requests

    func handle(_ request: HookServer.Request, responder: Responder) {
        guard let event = HookEvent.decode(request.body) else {
            Log.attention.notice("rejected undecodable \(request.route.rawValue, privacy: .public) body")
            responder.respond(status: 400)
            return
        }
        Log.attention.info("\(request.route.rawValue, privacy: .public) \(event.hookEventName ?? "?", privacy: .public)")
        switch request.route {
        case .event:
            responder.respond(status: 204)
            switch event.hookEventName {
            case "Notification": handleNotification(event)
            case "UserPromptSubmit": handlePromptSubmit(sessionID: event.sessionID)
            default: break
            }
        case .permission:
            guard event.hookEventName == "PermissionRequest", let tool = event.toolName,
                  pending.count < Self.maxPending
            else {
                // No decision: Claude Code shows its normal dialog.
                responder.respond(status: 204)
                return
            }
            enqueue(event, toolName: tool, responder: responder)
        case .statusline:
            responder.respond(status: 404) // routed to LimitsModel by AppModel
        }
    }

    private func enqueue(_ event: HookEvent, toolName: String, responder: Responder) {
        let id = UUID()
        let now = Date()
        let timeout = settings.answerTimeout
        pending.append(PendingRequest(
            id: id, sessionID: event.sessionID, project: SafeText.visible(event.projectName).text,
            preview: ToolPreviewBuilder.build(toolName: toolName, input: event.toolInput),
            options: PermissionOptions.from(event.permissionSuggestions),
            receivedAt: now, deadline: now.addingTimeInterval(TimeInterval(timeout))))
        responders[id] = responder

        responder.onClientGone { [weak self] in
            Task { @MainActor in self?.finish(id, .clientGone) }
        }
        timeouts[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.finish(id, .timedOut)
        }
        if let path = event.transcriptPath {
            watchers[id] = TranscriptWatcher(transcriptPath: path, toolName: toolName, toolInput: event.toolInput) { [weak self] in
                Task { @MainActor in self?.finish(id, .answeredElsewhere) }
            }
        }
        // Looking at the terminal: hold quietly. The dialog is right there, and the
        // request is still answerable from the menu bar if the user walks away.
        if !focus.isTerminalFrontmost {
            notifyRequest(id)
        }
    }

    private func handleNotification(_ event: HookEvent) {
        guard AttentionNotificationTypes.needsAttention(event.notificationType) else { return }
        // The PermissionRequest for this session is already in the menu.
        if event.notificationType == "permission_prompt",
           pending.contains(where: { $0.sessionID != nil && $0.sessionID == event.sessionID }) {
            return
        }
        guard !focus.isTerminalFrontmost else { return }
        let project = SafeText.visible(event.projectName).text
        let body = String(SafeText.visible(event.message ?? "Claude needs your attention").text.prefix(500))
        let id = "alert-\(UUID().uuidString)"
        notifications.post(id: id, title: project, subtitle: nil, body: body,
                           category: NotificationManager.alertCategory, requestID: nil, sound: settings.soundEnabled)
        record(project: project, text: body)
        genericAlert = true
        scheduleEscalation(key: id) { [weak self] in
            guard let self, self.genericAlert else { return false }
            self.notifications.post(id: "\(id).followup", title: project, subtitle: "Still waiting", body: body,
                                    category: NotificationManager.alertCategory, requestID: nil,
                                    sound: self.settings.soundEnabled)
            return true
        }
    }

    private func handlePromptSubmit(sessionID: String?) {
        Log.attention.debug("prompt submitted; pending sessions match: \(self.pending.filter { $0.sessionID == sessionID }.count)")
        clearAlerts()
        // The session moved on, so anything still held for it is stale.
        for request in pending where request.sessionID != nil && request.sessionID == sessionID {
            finish(request.id, .answeredElsewhere)
        }
    }

    // MARK: - User answers

    func answer(_ id: UUID, with decision: PermissionDecision) {
        finish(id, .decided(decision))
    }

    private func handle(_ action: NotificationManager.Action) {
        switch action {
        case .allow(let id): answer(id, with: .allow(updatedPermissions: []))
        case .deny(let id, let reason): answer(id, with: .deny(reason: reason))
        case .open: focus.activateTerminal()
        }
    }

    // MARK: - Focus

    private func focusChanged(terminalFrontmost: Bool) {
        switchAwayTask?.cancel()
        if terminalFrontmost {
            clearAlerts()
            return
        }
        guard pending.contains(where: { !$0.notified }) else { return }
        switchAwayTask = Task { [weak self] in
            try? await Task.sleep(for: Self.switchAwayGrace)
            guard let self, !Task.isCancelled, !self.focus.isTerminalFrontmost else { return }
            for request in self.pending where !request.notified {
                self.notifyRequest(request.id)
            }
        }
    }

    /// Clears the badge and stops escalation. Held requests stay answerable.
    private func clearAlerts() {
        genericAlert = false
        for i in pending.indices { pending[i].acknowledged = true }
        escalations.values.forEach { $0.cancel() }
        escalations.removeAll()
    }

    // MARK: - Notifications

    private func notifyRequest(_ id: UUID) {
        guard let i = pending.firstIndex(where: { $0.id == id }), !pending[i].notified else { return }
        pending[i].notified = true
        pending[i].acknowledged = false
        let request = pending[i]
        let waited = Date().timeIntervalSince(request.receivedAt)
        Log.attention.info("notifying for request after \(waited, format: .fixed(precision: 2))s")
        let subtitle = "Claude wants to use \(request.preview.toolName)"
        let body = Self.summary(of: request.preview)
        notifications.post(id: id.uuidString, title: request.project, subtitle: subtitle, body: body,
                           category: NotificationManager.permissionCategory, requestID: id, sound: settings.soundEnabled)
        record(project: request.project, text: "\(subtitle): \(body)", isPermission: true)
        scheduleEscalation(key: id.uuidString) { [weak self] in
            guard let self, let r = self.pending.first(where: { $0.id == id }), !r.acknowledged else { return false }
            self.notifications.post(id: "\(id.uuidString).followup", title: r.project, subtitle: "Still waiting: \(subtitle)",
                                    body: body, category: NotificationManager.permissionCategory, requestID: id,
                                    sound: self.settings.soundEnabled)
            return true
        }
    }

    private func scheduleEscalation(key: String, fire: @escaping @MainActor () -> Bool) {
        guard settings.escalationEnabled else { return }
        let delay = settings.escalationDelay
        escalations[key]?.cancel()
        escalations[key] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            _ = fire()
            self?.escalations[key] = nil
        }
    }

    private func record(project: String, text: String, isPermission: Bool = false) {
        recent.insert(RecentNotification(date: Date(), project: project, text: text, isPermission: isPermission), at: 0)
        if recent.count > Self.maxRecent { recent.removeLast(recent.count - Self.maxRecent) }
    }

    static func summary(of preview: ToolPreview) -> String {
        let text = preview.command ?? preview.filePath ?? preview.detail ?? preview.purpose ?? preview.toolName
        let firstLines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(4).joined(separator: "\n")
        return firstLines.count > 300 ? String(firstLines.prefix(300)) + "…" : firstLines
    }

    // MARK: - Settling

    private func finish(_ id: UUID, _ outcome: Outcome) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        Log.attention.info("request settled: \(String(describing: outcome), privacy: .public)")
        pending.remove(at: index)
        if let responder = responders.removeValue(forKey: id) {
            switch outcome {
            case .decided(let decision): responder.respond(status: 200, body: decision.hookOutput())
            case .answeredElsewhere, .timedOut, .clientGone: responder.respond(status: 204)
            }
        }
        timeouts.removeValue(forKey: id)?.cancel()
        watchers.removeValue(forKey: id)?.cancel()
        escalations.removeValue(forKey: id.uuidString)?.cancel()
        notifications.remove(ids: [id.uuidString, "\(id.uuidString).followup"])
    }

    /// On quit: release every held hook so the terminal dialogs take over immediately.
    func releaseAll() {
        for request in pending { finish(request.id, .clientGone) }
    }

    /// `--render-preview` only: a sample card with no hook behind it.
    func addPreviewSample() {
        let input: JSONValue = .object(["command": .string("git push --force-with-lease origin main"),
                                        "description": .string("Push the rebased branch")])
        let suggestion: JSONValue = .object(["type": .string("addRules"), "behavior": .string("allow"),
                                             "destination": .string("localSettings"),
                                             "rules": .array([.object(["toolName": .string("Bash"), "ruleContent": .string("git push:*")])])])
        let now = Date().addingTimeInterval(-60)
        pending.append(PendingRequest(id: UUID(), sessionID: nil, project: "my-app",
                                      preview: ToolPreviewBuilder.build(toolName: "Bash", input: input),
                                      options: PermissionOptions.from([suggestion]),
                                      receivedAt: now, deadline: now.addingTimeInterval(300), notified: true))
        record(project: "my-app", text: "Claude wants to use Bash: git push --force-with-lease origin main", isPermission: true)
        record(project: "api-server", text: "Claude is waiting for your input")
    }

    /// For the settings "Send test notification" button.
    func sendTestNotification() {
        notifications.post(id: "test-\(UUID().uuidString)", title: "Hoot", subtitle: nil,
                           body: "Test notification: this is what Claude Code alerts look like.",
                           category: NotificationManager.alertCategory, requestID: nil, sound: settings.soundEnabled)
        record(project: "Hoot", text: "Test notification")
    }
}

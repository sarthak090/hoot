import AppKit
import UserNotifications

/// Posts Hoot's notifications and turns notification clicks/actions into app actions.
@MainActor
final class NotificationManager: NSObject {
    enum Action {
        case allow(UUID)
        case deny(UUID, reason: String?)
        /// Clicked the notification body.
        case open
    }

    nonisolated static let permissionCategory = "HOOT_PERMISSION"
    nonisolated static let alertCategory = "HOOT_ALERT"
    nonisolated private static let allowAction = "HOOT_ALLOW"
    nonisolated private static let denyAction = "HOOT_DENY"
    nonisolated private static let requestKey = "requestID"

    private let center = UNUserNotificationCenter.current()
    var onAction: ((Action) -> Void)?
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    func configure() {
        center.delegate = self
        let allow = UNNotificationAction(identifier: Self.allowAction, title: "Allow once",
                                         options: [.authenticationRequired])
        let deny = UNTextInputNotificationAction(identifier: Self.denyAction, title: "Deny…", options: [],
                                                 textInputButtonTitle: "Deny",
                                                 textInputPlaceholder: "Reason for Claude (optional)")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.permissionCategory, actions: [allow, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.alertCategory, actions: [], intentIdentifiers: []),
        ])
    }

    @discardableResult
    func refreshAuthorization() async -> UNAuthorizationStatus {
        authorization = await Self.currentStatus()
        return authorization
    }

    nonisolated private static func currentStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    nonisolated private static func askForAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func requestAuthorization() async -> Bool {
        let granted = await Self.askForAuthorization()
        await refreshAuthorization()
        return granted
    }

    func post(id: String, title: String, subtitle: String?, body: String, category: String,
              requestID: UUID?, sound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle { content.subtitle = subtitle }
        content.body = body
        content.categoryIdentifier = category
        content.threadIdentifier = title
        content.interruptionLevel = .timeSensitive
        if sound { content.sound = .default }
        if let requestID { content.userInfo = [Self.requestKey: requestID.uuidString] }
        Self.deliver(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// Nonisolated on purpose: UserNotifications calls the completion handler on a
    /// background queue, and a closure formed inside this @MainActor class would be
    /// main-actor isolated and trap at runtime.
    nonisolated private static func deliver(_ request: UNNotificationRequest) {
        let posted = Date()
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.attention.error("notification failed: \(error.localizedDescription, privacy: .public)")
            } else {
                Log.attention.info("notification accepted by macOS in \(Date().timeIntervalSince(posted), format: .fixed(precision: 3))s")
            }
        }
    }

    func remove(ids: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let actionID = response.actionIdentifier
        let requestID = (response.notification.request.content.userInfo[Self.requestKey] as? String).flatMap(UUID.init)
        let text = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run {
            switch actionID {
            case Self.allowAction:
                if let requestID { onAction?(.allow(requestID)) }
            case Self.denyAction:
                if let requestID { onAction?(.deny(requestID, reason: text)) }
            case UNNotificationDefaultActionIdentifier:
                onAction?(.open)
            default:
                break // dismissed
            }
        }
    }
}

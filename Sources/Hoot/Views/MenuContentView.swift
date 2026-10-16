import SwiftUI
import UserNotifications

enum MenuTab: String, CaseIterable {
    case activity, usage
}

struct MenuContentView: View {
    @Environment(AppModel.self) private var model
    /// Remembered between openings, like the segment in a system menu.
    @AppStorage("menuTab") private var tab: MenuTab = .activity

    var body: some View {
        let attention = model.attention
        // Like a native menu: never taller than the screen; scroll beyond that.
        ScrollView(.vertical) {
            content(attention)
        }
        .scrollIndicators(.automatic)
        .frame(width: MenuMetrics.width)
        .frame(maxHeight: Self.maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.snappy(duration: 0.2), value: attention.pending.map(\.id))
        .fitWindowToContent()
        .task {
            if !attention.pending.isEmpty { tab = .activity }
            model.hooks.refresh()
            await model.notifications.refreshAuthorization()
        }
        // A new request always comes to the front, even if Usage was showing.
        .onChange(of: attention.pending.count) { old, new in
            if new > old { tab = .activity }
        }
    }

    /// Screen height under the menu bar, less a margin.
    static var maxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) - 24
    }

    private func content(_ attention: AttentionCenter) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Picker("Section", selection: $tab) {
                Text(attention.pending.isEmpty ? "Activity" : "Activity (\(attention.pending.count))").tag(MenuTab.activity)
                Text("Usage").tag(MenuTab.usage)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch tab {
            case .activity:
                activity(attention)
            case .usage:
                if !attention.pending.isEmpty {
                    Banner(kind: .info, text: attention.pending.count == 1 ? "Claude is waiting for an answer." : "Claude is waiting for \(attention.pending.count) answers.",
                           action: "View") { tab = .activity }
                }
                LimitsView()
                UsageSectionView()
            }
            Divider().padding(.horizontal, 4)
            VStack(spacing: 0) {
                SettingsLink { Text("Hoot Settings…") }
                    .buttonStyle(MenuRowStyle(shortcut: "⌘,"))
                Button("Quit Hoot") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(MenuRowStyle(shortcut: "⌘Q"))
                    .keyboardShortcut("q")
            }
        }
        .padding(MenuMetrics.outerPadding)
    }

    @ViewBuilder
    private func activity(_ attention: AttentionCenter) -> some View {
        notices
        if attention.pending.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Nothing waiting").font(.system(size: 13, weight: .medium))
                    Text("Permission requests show up here when you're away from the terminal.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .platter()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "Waiting for You",
                              trailing: attention.pending.count > 1 ? "\(attention.pending.count) requests" : nil)
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(attention.pending) { request in
                            PermissionCardView(request: request)
                        }
                    }
                }
                .frame(maxHeight: 440)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        CompactLimitsView { tab = .usage }
        RecentNotificationsView(items: attention.recent)
    }

    private var header: some View {
        let attention = model.attention
        let waiting = attention.pending.count
        let alert = attention.hasUnansweredAlert || waiting > 0
        return HStack(spacing: 10) {
            MascotView(alert: alert, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text("Hoot").font(.system(size: 13, weight: .semibold))
                Group {
                    if waiting > 0 {
                        Text(waiting == 1 ? "Claude is waiting for your answer" : "Claude is waiting on \(waiting) answers")
                    } else if attention.hasUnansweredAlert {
                        Text("Claude needs you")
                    } else {
                        Text("Watching Claude Code")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer()
            if alert {
                Circle().fill(.orange).frame(width: 8, height: 8)
                    .accessibilityLabel("Needs attention")
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var notices: some View {
        if model.demoMode {
            EmptyView()
        } else {
            setupNotices
        }
    }

    @ViewBuilder
    private var setupNotices: some View {
        if case .failed(let message) = model.serverStatus {
            Banner(kind: .warning, text: "Hoot can't receive hook events: \(message)")
        }
        switch model.hooks.state {
        case .notInstalled:
            Banner(kind: .info, text: "Install the Claude Code hook so Hoot can hear from Claude.")
            SettingsLink { Text("Open Settings…") }.controlSize(.small).padding(.leading, 4)
        case .outdated:
            Banner(kind: .warning, text: "The Claude Code hook needs an update.")
            SettingsLink { Text("Open Settings…") }.controlSize(.small).padding(.leading, 4)
        case .error(let message):
            Banner(kind: .warning, text: message)
        case .installed, .unknown:
            EmptyView()
        }
        switch model.notifications.authorization {
        case .denied:
            Banner(kind: .warning, text: "Notifications are off for Hoot.", action: "Turn On…") {
                model.notifications.openSystemSettings()
            }
        case .notDetermined:
            Banner(kind: .info, text: "Allow notifications so Hoot can reach you.", action: "Allow…") {
                Task { _ = await model.notifications.requestAuthorization() }
            }
        default:
            EmptyView()
        }
    }
}

/// Plain warning line for Settings forms (the menu uses `Banner`).
struct WarningRow: View {
    let text: String

    var body: some View {
        Label {
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .font(.system(size: 12))
    }
}

struct RecentNotificationsView: View {
    let items: [RecentNotification]
    static let collapsedCount = 3
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Recent")
            VStack(alignment: .leading, spacing: 0) {
                if items.isEmpty {
                    Text("No notifications yet").font(.system(size: 12)).foregroundStyle(.tertiary)
                        .padding(.vertical, 2)
                }
                ForEach(showAll ? items : Array(items.prefix(Self.collapsedCount))) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.isPermission ? "hand.raised.fill" : "bell.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: item.project).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(verbatim: item.text).font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        Spacer(minLength: 6)
                        Text(item.date, format: .dateTime.hour().minute())
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 3)
                }
                if items.count > Self.collapsedCount {
                    Button(showAll ? "Show Less" : "Show All \(items.count)") { showAll.toggle() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .padding(.top, 2)
                }
            }
            .platter(padding: 8)
        }
    }
}

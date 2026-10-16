import SwiftUI

/// First-launch explanation shown before macOS asks for notification permission.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    let done: () -> Void
    @State private var asking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                MascotView(alert: false, size: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hi, I'm Hoot.").font(.title2.bold())
                    Text("I'll tell you when Claude Code needs you and you're not looking at the terminal.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Label("Notifications appear only when your terminal isn't in front.", systemImage: "bell.badge")
                Label("You can allow or deny Claude's permission requests from the menu bar or the notification.", systemImage: "checkmark.shield")
                Label("Allowing from a notification requires your Mac to be unlocked.", systemImage: "lock")
            }
            .font(.callout)
            Text("Next, macOS will ask whether Hoot may send notifications. For Allow/Deny buttons that stay on screen, set Hoot's alert style to “Persistent” in System Settings › Notifications.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Not now") { done() }
                Spacer()
                Button("Enable notifications") {
                    asking = true
                    Task {
                        _ = await model.notifications.requestAuthorization()
                        asking = false
                        done()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(asking)
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}

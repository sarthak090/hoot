import ServiceManagement
import SwiftUI

struct GeneralSection: View {
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        Section("General") {
            Toggle("Open Hoot at login", isOn: Binding(
                get: { status == .enabled || status == .requiresApproval },
                set: { setLaunchAtLogin($0) }))
            if status == .requiresApproval {
                HStack {
                    Text("macOS needs your approval in Login Items.").font(.caption).foregroundStyle(.secondary)
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }.controlSize(.small)
                }
            }
            if let error {
                Text(verbatim: error).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { status = SMAppService.mainApp.status }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = "Couldn't change this: \(error.localizedDescription). Keep Hoot.app in a fixed place (e.g. /Applications) and try again."
        }
        status = SMAppService.mainApp.status
    }
}

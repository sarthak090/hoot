import AppKit
import SwiftUI

/// Standard macOS preferences window: toolbar tabs, grouped forms.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            ClaudeCodeTab()
                .tabItem { Label("Claude Code", systemImage: "terminal") }
            UsageTab()
                .tabItem { Label("Usage", systemImage: "chart.bar") }
        }
        .frame(width: 540)
        .onAppear { NSApplication.shared.activate() }
        .onChange(of: model.settings.answerTimeout) { model.answerTimeoutChanged() }
    }
}

private struct GeneralTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            GeneralSection()
            Section {
                Picker("Show next to Hoot", selection: $settings.menuBarUsage) {
                    ForEach(MenuBarUsage.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("How much of your plan limit is used. “Session and week” shows them in that order (e.g. 13% · 38%). Needs the statusline feed (Claude Code tab); without data only Hoot shows.")
            }
            Section {
                Toggle("Play sound", isOn: $settings.soundEnabled)
                Toggle("Remind me once if I don't respond", isOn: $settings.escalationEnabled)
                Picker("Remind after", selection: $settings.escalationDelay) {
                    ForEach([30, 60, 120, 300, 600], id: \.self) { s in
                        Text(s < 60 ? "\(s) seconds" : s == 60 ? "1 minute" : "\(s / 60) minutes").tag(s)
                    }
                    if ![30, 60, 120, 300, 600].contains(settings.escalationDelay) {
                        Text("\(settings.escalationDelay) seconds").tag(settings.escalationDelay)
                    }
                }
                .disabled(!settings.escalationEnabled)
                LabeledContent("Test") {
                    Button("Send Test Notification") { model.attention.sendTestNotification() }
                }
            } header: {
                Text("Notifications")
            }
            WatchedAppsSection()
        }
        .formStyle(.grouped)
        .frame(height: 640)
    }
}

private struct ClaudeCodeTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            HookSection()
            Section {
                Picker("Wait for an answer", selection: $settings.answerTimeout) {
                    ForEach([60, 120, 300, 600, 900, 1800], id: \.self) { s in
                        Text(s < 60 ? "\(s) seconds" : s == 60 ? "1 minute" : "\(s / 60) minutes").tag(s)
                    }
                    if ![60, 120, 300, 600, 900, 1800].contains(settings.answerTimeout) {
                        Text("\(settings.answerTimeout) seconds").tag(settings.answerTimeout)
                    }
                }
            } header: {
                Text("Permission Requests")
            } footer: {
                Text("After this, Hoot steps aside and Claude Code's own terminal dialog decides. Changing it asks you to update the hook.")
            }
            StatusLineSection()
            Section {
                LabeledContent("Socket") {
                    Text(verbatim: PrivateFiles.socket.path)
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .lineLimit(2).truncationMode(.middle)
                }
            } header: {
                Text("Connection")
            } footer: {
                Text("Hooks reach Hoot through a Unix socket in a folder only your account can open, with a token that changes on every launch. Nothing listens on the network.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 620)
    }
}

private struct UsageTab: View {
    var body: some View {
        Form {
            PricingSection()
        }
        .formStyle(.grouped)
        .frame(height: 300)
    }
}

/// Apps that count as "looking at the terminal", shown the way System Settings lists apps.
private struct WatchedAppsSection: View {
    @Environment(AppModel.self) private var model
    @State private var newBundleID = ""

    var body: some View {
        @Bindable var settings = model.settings
        Section {
            ForEach(settings.terminalBundleIDs, id: \.self) { id in
                HStack(spacing: 8) {
                    AppIcon(bundleID: id).frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: Self.appName(for: id) ?? id)
                        if Self.appName(for: id) == nil {
                            Text("Not installed").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        settings.terminalBundleIDs.removeAll { $0 == id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                    .accessibilityLabel("Remove \(Self.appName(for: id) ?? id)")
                }
            }
            HStack {
                Menu {
                    ForEach(Self.runningRegularApps().filter { !settings.terminalBundleIDs.contains($0.bundleID) }, id: \.bundleID) { app in
                        Button(app.name) { add(app.bundleID) }
                    }
                } label: {
                    Label("Add Running App", systemImage: "plus")
                }
                .fixedSize()
                Spacer()
                Button("Restore Defaults") { settings.terminalBundleIDs = SettingsStore.defaultTerminals }
            }
            HStack {
                TextField("Bundle ID", text: $newBundleID, prompt: Text("com.example.Editor"))
                Button("Add") { add(newBundleID) }
                    .disabled(newBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Terminal & Editor Apps")
        } footer: {
            Text("While one of these is in front, Hoot stays quiet: requests wait in the menu without a notification.")
        }
    }

    private func add(_ raw: String) {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !model.settings.terminalBundleIDs.contains(id) else { return }
        model.settings.terminalBundleIDs.append(id)
        newBundleID = ""
    }

    static func appName(for bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func runningRegularApps() -> [(name: String, bundleID: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { (app.localizedName ?? $0, $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

private struct AppIcon: View {
    let bundleID: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app.dashed").resizable().aspectRatio(contentMode: .fit).foregroundStyle(.tertiary)
        }
    }
}

import HootCore
import SwiftUI

/// Install / update / uninstall of Hoot's Claude Code hook.
struct HookSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var hooks = model.hooks
        Section {
            HStack {
                statusLabel
                Spacer()
                switch hooks.state {
                case .notInstalled:
                    Button("Install Hook…") { hooks.prepare(.install) }
                case .outdated:
                    Button("Update Hook…") { hooks.prepare(.install) }
                    Button("Uninstall…") { hooks.prepare(.uninstall) }
                case .installed:
                    Button("Uninstall…") { hooks.prepare(.uninstall) }
                case .unknown, .error:
                    Button("Check Again") { hooks.refresh() }
                }
            }
            if hooks.hooksDisabled {
                WarningRow(text: "“disableAllHooks” is true in ~/.claude/settings.json, so Claude Code runs no hooks at all.")
            }
            if let message = hooks.message {
                Text(verbatim: message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if hooks.lastBackup != nil || FileManager.default.fileExists(atPath: HookInstallService.files.backupsDir.path) {
                Button("Show Backups in Finder") { hooks.revealBackups() }
                    .buttonStyle(.link)
            }
        } header: {
            Text("Claude Code Hook")
        } footer: {
            Text("Adds three entries to ~/.claude/settings.json: PermissionRequest (waits for your answer), Notification and UserPromptSubmit (fire-and-forget). You'll see the exact change before anything is written.")
        }
        .onAppear { hooks.refresh() }
        .sheet(item: $hooks.plan) { plan in
            HookReviewSheet(plan: plan, subject: "Hoot's hook") { model.hooks.apply($0) }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch model.hooks.state {
        case .unknown:
            Label("Checking…", systemImage: "hourglass")
        case .notInstalled:
            Label("Not installed", systemImage: "circle.dashed")
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .outdated:
            Label("Needs update", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
        case .error(let message):
            Label { Text(verbatim: message).fixedSize(horizontal: false, vertical: true) } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }
}

/// Shows exactly what will change before anything is written.
struct HookReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let plan: HookPlan
    let subject: String
    let confirm: (HookPlan) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: plan.kind == .install ? "Install \(subject)" : "Uninstall \(subject)").font(.title3.bold())
            Text(verbatim: plan.settingsURL.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            if plan.diff.isEmpty {
                Text("settings.json is already up to date; no changes to it.").foregroundStyle(.secondary)
            } else {
                Text("Changes to settings.json (green is added, red is removed):").font(.callout)
                DiffBox(lines: plan.diff)
                    .frame(minHeight: 220, maxHeight: 340)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(plan.notes, id: \.self) { note in
                    Label { Text(verbatim: note).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "info.circle") }
                        .font(.callout)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(plan.kind == .install ? "Install" : "Uninstall") {
                    confirm(plan)
                }
            }
        }
        .padding(20)
        .frame(width: 620)
    }
}

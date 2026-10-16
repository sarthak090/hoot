import HootCore
import SwiftUI

/// Opt-in: a statusline that reports Claude Code's plan rate limits to Hoot.
struct StatusLineSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var service = model.statusLine
        Section {
            HStack {
                switch service.state {
                case .unknown: Label("Checking…", systemImage: "hourglass")
                case .notInstalled: Label("Off", systemImage: "circle.dashed")
                case .installed: Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .outdated: Label("Needs update", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                case .error(let m):
                    Label { Text(verbatim: m).fixedSize(horizontal: false, vertical: true) } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                Spacer()
                switch service.state {
                case .notInstalled: Button("Turn On…") { service.prepare(.install) }
                case .outdated:
                    Button("Update…") { service.prepare(.install) }
                    Button("Turn Off…") { service.prepare(.uninstall) }
                case .installed: Button("Turn Off…") { service.prepare(.uninstall) }
                case .unknown, .error: Button("Check Again") { service.refresh() }
                }
            }
            if let wrapped = service.wrappedCommand, service.state == .installed || service.state == .outdated {
                LabeledContent("Wrapping your statusline") {
                    Text(verbatim: SafeText.visible(wrapped).text).font(.caption.monospaced()).lineLimit(2).truncationMode(.middle)
                }
            }
            if let message = service.message {
                Text(verbatim: message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Plan Limits")
        } footer: {
            Text("Claude Code shares your 5-hour and weekly limit usage only with statusline commands (Pro/Max plans, after a session's first reply). This adds a statusline that passes that data to Hoot. If you already have one, Hoot wraps it so its output doesn't change.")
        }
        .onAppear { service.refresh() }
        .sheet(item: $service.plan) { plan in
            HookReviewSheet(plan: plan, subject: "the statusline feed") { model.statusLine.apply($0) }
        }
    }
}

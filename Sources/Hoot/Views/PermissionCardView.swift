import HootCore
import SwiftUI

/// One held permission request with a readable preview and the answer buttons.
struct PermissionCardView: View {
    @Environment(AppModel.self) private var model
    let request: PendingRequest

    /// Buttons stay disabled briefly after a card appears, so a click aimed at a card
    /// that just moved can't land on a different request.
    static let armDelay: TimeInterval = 0.8
    @State private var armed = false
    @State private var denying = false
    @State private var reason = ""
    @FocusState private var reasonFocused: Bool

    var body: some View {
        let preview = request.preview
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: ToolSymbol.name(for: preview.toolName))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(verbatim: request.project).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                countdown
            }
            switch preview.kind {
            case .question:
                QuestionAnswerView(request: request, armed: armed)
            case .plan:
                PlanReviewView(request: request, armed: armed)
            case .permission:
                permissionBody(preview)
            }
        }
        .platter()
        .task {
            let wait = Self.armDelay - Date().timeIntervalSince(request.receivedAt)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            armed = true
        }
    }

    private var title: String {
        switch request.preview.kind {
        case .question: "Question"
        case .plan: "Plan to Review"
        case .permission: request.preview.toolName
        }
    }

    @ViewBuilder
    private func permissionBody(_ preview: ToolPreview) -> some View {
        if let purpose = preview.purpose, !purpose.isEmpty {
            Text(verbatim: purpose).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let path = preview.filePath {
            Label { Text(verbatim: path).textSelection(.enabled).lineLimit(2).truncationMode(.middle) } icon: {
                Image(systemName: "doc")
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        if let command = preview.command { CodeBox(text: command) }
        if let diff = preview.diff { DiffBox(lines: diff) }
        if let detail = preview.detail { CodeBox(text: detail) }
        PreviewWarnings(preview: preview)
        if denying { denyForm } else { buttons }
    }

    private var countdown: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, Int(request.deadline.timeIntervalSince(context.date)))
            Label("\(left / 60):\(String(format: "%02d", left % 60))", systemImage: "timer")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        }
        .help("If you don't answer here, the terminal dialog decides after this.")
        .accessibilityLabel("Time before the terminal takes over")
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button("Deny…") {
                denying = true
                reasonFocused = true
            }
            .accessibilityIdentifier("hoot.permission.deny")
            Spacer(minLength: 0)
            if !request.options.isEmpty {
                Menu("Always Allow") {
                    ForEach(request.options) { option in
                        Button(option.label) {
                            model.attention.answer(request.id, with: .allow(updatedPermissions: [option.suggestion]))
                        }
                    }
                }
                .menuStyle(.button)
                .fixedSize()
            }
            // Deliberately no keyboard shortcut: the dropdown can take key focus while the
            // user is typing elsewhere, and a stray Return must never grant permission.
            Button("Allow Once") {
                model.attention.answer(request.id, with: .allow(updatedPermissions: []))
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("hoot.permission.allowOnce")
        }
        .controlSize(.regular)
        .disabled(!armed)
    }

    private var denyForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Tell Claude why (optional)", text: $reason, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .focused($reasonFocused)
                .onSubmit(deny)
            HStack {
                Spacer()
                Button("Cancel") {
                    denying = false
                    reason = ""
                }
                Button("Deny", role: .destructive, action: deny)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
    }

    private func deny() {
        model.attention.answer(request.id, with: .deny(reason: reason))
    }
}

/// Monospaced, selectable code on a text-background well.
struct CodeBox: View {
    let text: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(verbatim: text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 150)
        .fixedSize(horizontal: false, vertical: true)
        .codeWell()
    }
}

struct DiffBox: View {
    let lines: [DiffLine]

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines.indices, id: \.self) { i in
                    row(lines[i])
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 200)
        .fixedSize(horizontal: false, vertical: true)
        .codeWell()
    }

    @ViewBuilder
    private func row(_ line: DiffLine) -> some View {
        let (marker, color): (String, Color) = switch line.kind {
        case .added: ("+", .green)
        case .removed: ("−", .red)
        case .context: (" ", .primary)
        case .gap: ("⋯", .secondary)
        }
        Text(verbatim: "\(marker) \(line.text)")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(color)
            .textSelection(.enabled)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(line.kind == .added ? Color.green.opacity(0.1) : line.kind == .removed ? Color.red.opacity(0.1) : .clear)
    }
}

extension View {
    /// The sunken text well macOS uses for code and logs.
    func codeWell() -> some View {
        background(Color(nsColor: .textBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
    }
}

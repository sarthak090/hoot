import HootCore
import SwiftUI

/// AskUserQuestion: Claude's multiple-choice questions, answered from the menu.
/// The answer is sent back with Claude's original question and option text, which is
/// what Claude Code matches on.
struct QuestionAnswerView: View {
    @Environment(AppModel.self) private var model
    let request: PendingRequest
    let armed: Bool

    /// Question index → chosen option indexes.
    @State private var picks: [Int: Set<Int>] = [:]
    /// Questions where "Other…" is chosen, and what was typed.
    @State private var otherChosen: Set<Int> = []
    @State private var otherText: [Int: String] = [:]

    private var questions: [QuestionPreview] { request.preview.questions ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(questions.indices, id: \.self) { qi in
                questionView(qi, questions[qi])
            }
            PreviewWarnings(preview: request.preview)
            HStack(spacing: 8) {
                Button("Answer in Terminal") { model.attention.handBack(request.id) }
                    .help("Remove this from Hoot and answer in Claude Code instead.")
                    .accessibilityIdentifier("hoot.question.handBack")
                Spacer(minLength: 0)
                // No keyboard shortcut, like Allow: a stray Return must not answer for you.
                Button("Send Answer", action: send)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("hoot.question.send")
                    .disabled(!armed || !isComplete || request.toolInput?["questions"] == nil)
            }
            .controlSize(.regular)
        }
    }

    private func questionView(_ qi: Int, _ q: QuestionPreview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let header = q.header, !header.isEmpty {
                Text(verbatim: header.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            Text(verbatim: q.question).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            if q.multiSelect {
                Text("Choose any").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            VStack(spacing: 2) {
                ForEach(q.options.indices, id: \.self) { oi in
                    let option = q.options[oi]
                    choiceRow(label: option.label, detail: option.detail, multi: q.multiSelect,
                              selected: picks[qi, default: []].contains(oi), id: "hoot.question.\(qi).option.\(oi)") {
                        toggle(qi, oi, multi: q.multiSelect)
                    }
                }
                choiceRow(label: "Other…", detail: nil, multi: q.multiSelect, selected: otherChosen.contains(qi),
                          id: "hoot.question.\(qi).other") {
                    toggleOther(qi, multi: q.multiSelect)
                }
                if otherChosen.contains(qi) {
                    TextField("Your answer", text: Binding(get: { otherText[qi, default: ""] }, set: { otherText[qi] = $0 }),
                              axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.roundedBorder)
                        .padding(.leading, 26)
                }
            }
        }
    }

    private func choiceRow(label: String, detail: String?, multi: Bool, selected: Bool, id: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: selected ? (multi ? "checkmark.square.fill" : "largecircle.fill.circle") : (multi ? "square" : "circle"))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: label).font(.system(size: 12))
                    if let detail, !detail.isEmpty {
                        Text(verbatim: detail).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5).padding(.horizontal, 6)
            .contentShape(Rectangle())
            .background(selected ? Color.accentColor.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: MenuMetrics.rowRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: [label, detail].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    private func toggle(_ qi: Int, _ oi: Int, multi: Bool) {
        if multi {
            picks[qi, default: []].formSymmetricDifference([oi])
        } else {
            picks[qi] = [oi]
            otherChosen.remove(qi)
        }
    }

    private func toggleOther(_ qi: Int, multi: Bool) {
        if otherChosen.contains(qi) {
            otherChosen.remove(qi)
        } else {
            otherChosen.insert(qi)
            if !multi { picks[qi] = [] }
        }
    }

    /// The answer for one question: chosen labels (original text) plus any typed answer,
    /// joined with ", " for multi-select, as Claude Code expects.
    private func answer(_ qi: Int) -> String {
        let q = questions[qi]
        var parts = picks[qi, default: []].sorted().map { q.options[$0].rawLabel }
        if otherChosen.contains(qi) {
            let typed = otherText[qi, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty { parts.append(typed) }
        }
        return parts.joined(separator: ", ")
    }

    private var isComplete: Bool {
        !questions.isEmpty && questions.indices.allSatisfy { !answer($0).isEmpty }
    }

    private func send() {
        guard let original = request.toolInput?["questions"] else { return }
        var answers: [String: String] = [:]
        for qi in questions.indices { answers[questions[qi].rawQuestion] = answer(qi) }
        model.attention.answer(request.id, with: .answer(questions: original, answers: answers))
    }
}

/// ExitPlanMode: read the plan, approve it, or send it back with feedback.
struct PlanReviewView: View {
    @Environment(AppModel.self) private var model
    let request: PendingRequest
    let armed: Bool

    @State private var givingFeedback = false
    @State private var feedback = ""
    @FocusState private var feedbackFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                PlanText(markdown: request.preview.plan ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
            .codeWell()
            PreviewWarnings(preview: request.preview)
            if givingFeedback {
                TextField("What should change?", text: $feedback, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($feedbackFocused)
                HStack {
                    Spacer()
                    Button("Cancel") {
                        givingFeedback = false
                        feedback = ""
                    }
                    Button("Send Feedback") {
                        model.attention.answer(request.id, with: .planFeedback(feedback))
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text("Approving lets Claude leave plan mode and start working.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                HStack(spacing: 8) {
                    Button("Keep Planning…") {
                        givingFeedback = true
                        feedbackFocused = true
                    }
                    .accessibilityIdentifier("hoot.plan.feedback")
                    Spacer(minLength: 0)
                    Button("Approve Plan") {
                        guard let input = request.toolInput else { return }
                        model.attention.answer(request.id, with: .approvePlan(toolInput: input))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!armed || request.toolInput == nil)
                    .accessibilityIdentifier("hoot.plan.approve")
                }
                .controlSize(.regular)
            }
        }
    }
}

/// Light Markdown for plans: headings as bold lines, inline `code`/**bold**/*italic*.
/// Links are deliberately not clickable: the text comes from the model.
struct PlanText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if let heading = Self.heading(line) {
                    Text(verbatim: heading).font(.system(size: 12, weight: .semibold)).padding(.top, 2)
                } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    Spacer().frame(height: 2)
                } else {
                    Text(Self.inline(line)).font(.system(size: 12))
                }
            }
        }
        .textSelection(.enabled)
    }

    static func heading(_ line: String) -> String? {
        guard let match = line.firstMatch(of: /^\s{0,3}#{1,6}\s+(.*)$/) else { return nil }
        return String(match.1)
    }

    static func inline(_ line: String) -> AttributedString {
        var text = (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(line)
        for run in text.runs where run.link != nil {
            text[run.range].link = nil
        }
        for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true {
            text[run.range].font = .system(size: 11, design: .monospaced)
        }
        return text
    }
}

struct PreviewWarnings: View {
    let preview: ToolPreview

    var body: some View {
        if preview.hadHiddenCharacters {
            WarningRow(text: "Contains hidden or direction-changing characters, shown as ⟨U+…⟩. Check carefully.")
        }
        if preview.truncated {
            WarningRow(text: "Preview shortened. Check the terminal to see everything.")
        }
    }
}

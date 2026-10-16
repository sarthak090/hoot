import AppKit
import Charts
import HootCore
import SwiftUI

/// Today / 7-day token usage with an API-equivalent cost estimate.
struct UsageSectionView: View {
    @Environment(AppModel.self) private var model
    @State private var hoveredDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Tokens", trailing: "Cost is an API-price estimate")
            Group {
                if let summary = model.usage.summary {
                    content(summary)
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reading Claude Code transcripts…").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            .platter()
        }
    }

    @ViewBuilder
    private func content(_ s: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.usage.transcriptsMissing {
                Text("No Claude Code transcripts in ~/.claude/projects yet.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: TokenFormat.compact(s.today.tokens.total))
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text("tokens today").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(verbatim: TokenFormat.dollars(s.today.cost))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text("estimated").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 0) {
                MiniStat(value: String(s.sessionsToday), label: s.sessionsToday == 1 ? "session today" : "sessions today")
                MiniStat(value: TokenFormat.compact(s.week.total), label: "tokens, 7 days")
                MiniStat(value: TokenFormat.dollars(s.weekCost), label: "estimated, 7 days")
            }
            Text(verbatim: "In \(TokenFormat.compact(s.today.tokens.input)) · Out \(TokenFormat.compact(s.today.tokens.output)) · Cache \(TokenFormat.compact(s.today.tokens.cacheRead)) read, \(TokenFormat.compact(s.today.tokens.cacheWrite)) written")
                .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).minimumScaleFactor(0.85)
            chart(s)
            if let top = s.topProject {
                Label {
                    Text(verbatim: "Most active this week: \(SafeText.visible(top.name).text) · \(TokenFormat.compact(top.tokens))")
                        .lineLimit(1).truncationMode(.middle)
                } icon: { Image(systemName: "folder") }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if !s.unpricedModels.isEmpty {
                Text(verbatim: "Not priced (missing from the pricing file): \(s.unpricedModels.joined(separator: ", "))")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let problem = model.usage.pricingProblem {
                WarningRow(text: problem)
            }
        }
    }

    private func chart(_ s: UsageSummary) -> some View {
        let cal = Calendar.current
        let hovered = hoveredDate.flatMap { d in s.days.first { cal.isDate($0.day, inSameDayAs: d) } }
        return VStack(alignment: .leading, spacing: 4) {
            Group {
                if let h = hovered {
                    Text(verbatim: "\(h.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) · \(TokenFormat.compact(h.tokens.total)) tokens · \(TokenFormat.dollars(h.cost))")
                } else {
                    Text("Tokens per day, last 7 days")
                }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            Chart(s.days) { d in
                BarMark(x: .value("Day", d.day, unit: .day), y: .value("Tokens", d.tokens.total), width: .fixed(22))
                    .foregroundStyle(Self.barColor)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                    .opacity(hovered == nil || hovered?.day == d.day ? 1 : 0.45)
                    .accessibilityLabel(d.day.formatted(.dateTime.weekday(.wide).day().month()))
                    .accessibilityValue("\(TokenFormat.compact(d.tokens.total)) tokens, about \(TokenFormat.dollars(d.cost))")
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let n = value.as(Int.self) { Text(TokenFormat.compact(n)) }
                    }
                }
            }
            .chartXSelection(value: $hoveredDate)
            .frame(height: 72)
        }
    }

    /// Reference palette slot 1 (blue), with its own step for dark mode.
    static let barColor = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x39 / 255, green: 0x87 / 255, blue: 0xE5 / 255, alpha: 1)
            : NSColor(srgbRed: 0x2A / 255, green: 0x78 / 255, blue: 0xD6 / 255, alpha: 1)
    })
}

struct MiniStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: value).font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(verbatim: label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

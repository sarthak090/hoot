import HootCore
import SwiftUI

/// Plan usage left for the current 5-hour session and the week, as horizontal bars
/// (filled = what's left, like a battery). Data comes from the opt-in statusline feed.
struct LimitsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Re-evaluated each minute so expired windows disappear and "as of" stays honest.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let snap = model.limits.current(now: context.date)
                SectionHeader(title: "Plan Usage Left",
                              trailing: snap.map { "Updated \($0.receivedAt.formatted(.relative(presentation: .named)))" })
                VStack(alignment: .leading, spacing: 14) {
                    LimitBar(title: "Current session", caption: "5-hour window", window: snap?.fiveHour, now: context.date)
                    LimitBar(title: "This week", caption: "7-day window", window: snap?.sevenDay, now: context.date)
                    if snap == nil { emptyState }
                }
                .platter(padding: 12)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.statusLine.state == .installed {
            Label("Waiting for Claude Code to report limits. This happens after a session's first reply, on Pro/Max.",
                  systemImage: "hourglass")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your limits aren't stored on this Mac. Claude Code shares them with a statusline, so Hoot can show them once that's on.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsLink { Text("Turn On in Settings…") }.controlSize(.small)
            }
        }
    }
}

/// One horizontal "left" bar with its labels.
struct LimitBar: View {
    let title: String
    let caption: String
    /// nil = no data yet: an empty track and dashes, never a made-up number.
    let window: RateLimitWindow?
    let now: Date

    static let barHeight: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(caption).font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Text(window.map { "\(Int($0.leftPercentage.rounded()))% left" } ?? "—")
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(window == nil ? .tertiary : .primary)
            }
            LimitTrack(window: window, height: Self.barHeight)
            HStack {
                Text(window.map { "\(Int($0.usedPercentage.rounded()))% used" } ?? "No data yet")
                Spacer()
                if let reset = window?.resetsAt {
                    Text("Resets \(Self.resetText(reset, now: now))")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(caption)")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        guard let window else { return "No data yet" }
        var s = "\(Int(window.leftPercentage.rounded())) percent left"
        if let r = window.resetsAt { s += ", resets \(Self.resetText(r, now: now))" }
        return s
    }

    static func resetText(_ date: Date, now: Date) -> String {
        if date.timeIntervalSince(now) < 3600 {
            return "in \(max(1, Int(date.timeIntervalSince(now) / 60))) min"
        }
        return Calendar.current.isDate(date, inSameDayAs: now)
            ? "at \(date.formatted(date: .omitted, time: .shortened))"
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// The bar itself: filled = what's left. Shared by the full and compact views.
struct LimitTrack: View {
    let window: RateLimitWindow?
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.fill.tertiary)
                if let window {
                    Capsule()
                        .fill(Self.tint(window))
                        // Keep a visible sliver at 1-2% so "almost gone" doesn't look like "no data".
                        .frame(width: max(window.leftPercentage > 0 ? height : 0, proxy.size.width * window.leftPercentage / 100))
                }
            }
        }
        .frame(height: height)
    }

    /// Blue while there's room; orange at 25% left or less; red at 10% or less.
    static func tint(_ w: RateLimitWindow) -> Color {
        w.leftPercentage <= 10 ? .red : w.leftPercentage <= 25 ? .orange : UsageSectionView.barColor
    }
}

/// One-line-per-window version for the Activity tab.
struct CompactLimitsView: View {
    @Environment(AppModel.self) private var model
    let showDetails: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let snap = model.limits.current(now: context.date)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeader(title: "Plan Usage Left")
                    Spacer()
                    if snap == nil && model.statusLine.state != .installed {
                        SettingsLink { Text("Set Up…") }.buttonStyle(.link).font(.system(size: 11))
                    } else {
                        Button("Details", action: showDetails).buttonStyle(.link).font(.system(size: 11))
                    }
                }
                .padding(.trailing, 4)
                VStack(spacing: 8) {
                    row("Session", snap?.fiveHour, now: context.date)
                    row("Week", snap?.sevenDay, now: context.date)
                }
                .platter()
            }
        }
    }

    private func row(_ label: String, _ window: RateLimitWindow?, now: Date) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12)).frame(width: 52, alignment: .leading)
            LimitTrack(window: window, height: 6)
            Text(window.map { "\(Int($0.leftPercentage.rounded()))% left" } ?? "—")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(window == nil ? .tertiary : .primary)
                .frame(width: 64, alignment: .trailing)
        }
        .help(window?.resetsAt.map { "Resets \(LimitBar.resetText($0, now: now))" } ?? "No data yet")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label == "Session" ? "Current session" : "This week")
        .accessibilityValue(window.map { "\(Int($0.leftPercentage.rounded())) percent left" } ?? "No data yet")
    }
}

import Foundation
import HootCore
import Observation

/// Plan rate limits as last reported by Claude Code's statusline (opt-in feed).
@MainActor
@Observable
final class LimitsModel {
    private(set) var snapshot: RateLimitSnapshot?
    /// Advanced every minute so views that show limits (the menu-bar text especially, which
    /// can't use TimelineView) drop a window as soon as it resets.
    private(set) var clock = Date()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var ticker: Task<Void, Never>?
    private static let key = "rateLimitSnapshot"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.clock = Date()
            }
        }
        if let data = defaults.data(forKey: Self.key) {
            snapshot = try? JSONDecoder().decode(RateLimitSnapshot.self, from: data)
        }
    }

    /// `--render-preview --with-sample` only: example numbers, never saved.
    func setPreviewSample() {
        let now = Date()
        snapshot = RateLimitSnapshot(fiveHour: RateLimitWindow(usedPercentage: 81, resetsAt: now.addingTimeInterval(95 * 60)),
                                     sevenDay: RateLimitWindow(usedPercentage: 38, resetsAt: now.addingTimeInterval(3 * 86400)),
                                     receivedAt: now.addingTimeInterval(-120))
    }

    /// Live windows only; nil if nothing current is known.
    func current(now: Date? = nil) -> RateLimitSnapshot? {
        snapshot?.current(now: now ?? max(clock, Date()))
    }

    /// Text shown next to Hoot in the menu bar (percentage *used*), or nil to show the icon alone.
    func menuBarText(_ mode: MenuBarUsage) -> String? {
        guard mode != .off, let snap = current(now: clock) else { return nil }
        func pct(_ w: RateLimitWindow?) -> String? { w.map { "\(Int($0.usedPercentage.rounded()))%" } }
        switch mode {
        case .off: return nil
        case .session: return pct(snap.fiveHour)
        case .week: return pct(snap.sevenDay)
        case .both:
            switch (pct(snap.fiveHour), pct(snap.sevenDay)) {
            case let (s?, w?): return "\(s) · \(w)"
            case let (s?, nil): return s
            case let (nil, w?): return w
            default: return nil
            }
        }
    }

    /// Spoken version for VoiceOver.
    func menuBarAccessibility(_ mode: MenuBarUsage) -> String? {
        guard mode != .off, let snap = current(now: clock) else { return nil }
        var parts: [String] = []
        if mode != .week, let s = snap.fiveHour { parts.append("\(Int(s.usedPercentage.rounded())) percent of session used") }
        if mode != .session, let w = snap.sevenDay { parts.append("\(Int(w.usedPercentage.rounded())) percent of week used") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    func handle(_ body: Data, responder: Responder) {
        guard let input = StatusLine.parse(body, now: Date()) else {
            responder.respond(status: 400)
            return
        }
        if let fresh = input.rateLimits {
            // A window missing from this report may just not be known yet; keep the last value
            // (expired ones are dropped when read).
            let merged = RateLimitSnapshot(fiveHour: fresh.fiveHour ?? snapshot?.fiveHour,
                                           sevenDay: fresh.sevenDay ?? snapshot?.sevenDay,
                                           receivedAt: fresh.receivedAt)
            if merged != snapshot {
                snapshot = merged
                if let data = try? JSONEncoder().encode(merged) { defaults.set(data, forKey: Self.key) }
            }
        }
        responder.respond(status: 200, body: Data((StatusLine.defaultLine(input) + "\n").utf8),
                          contentType: "text/plain; charset=utf-8")
    }
}

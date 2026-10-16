import Foundation

public struct TokenBreakdown: Sendable, Equatable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0

    public init() {}

    public var total: Int { input + output + cacheRead + cacheWrite }

    mutating func add(_ r: UsageRecord) {
        input += r.input
        output += r.output
        cacheRead += r.cacheRead
        cacheWrite += r.cacheWrite
    }
}

public struct DayUsage: Sendable, Equatable, Identifiable {
    public var day: Date
    public var tokens = TokenBreakdown()
    public var cost = 0.0
    public var id: Date { day }
}

public struct UsageSummary: Sendable, Equatable {
    public static let windowDays = 7

    /// Oldest first; the last entry is today. Always `windowDays` entries.
    public var days: [DayUsage]
    public var week = TokenBreakdown()
    public var weekCost = 0.0
    public var sessionsToday = 0
    public var topProject: (name: String, tokens: Int)?
    /// Models seen in the window with no price; their tokens count, their cost doesn't.
    public var unpricedModels: [String] = []

    public var today: DayUsage { days[days.count - 1] }

    public static func == (a: UsageSummary, b: UsageSummary) -> Bool {
        a.days == b.days && a.week == b.week && a.weekCost == b.weekCost && a.sessionsToday == b.sessionsToday
            && a.topProject?.name == b.topProject?.name && a.topProject?.tokens == b.topProject?.tokens
            && a.unpricedModels == b.unpricedModels
    }

    /// Start of the first day in the window: anything older can't affect the summary.
    public static func windowStart(now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(windowDays - 1), to: today) ?? today
    }

    public static func compute(_ records: some Sequence<UsageRecord>, pricing: PricingTable,
                               now: Date = Date(), calendar: Calendar = .current) -> UsageSummary {
        let todayStart = calendar.startOfDay(for: now)
        let starts = (0..<windowDays).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: todayStart) }
        var days = starts.map { DayUsage(day: $0) }
        var summary = UsageSummary(days: days)
        var sessions = Set<String>()
        var projects: [String: Int] = [:]
        var unpriced = Set<String>()
        let windowStart = starts.first ?? todayStart

        for r in records {
            // Future timestamps (clock skew) count as today rather than vanishing.
            let when = min(r.timestamp, now)
            guard when >= windowStart else { continue }
            let dayStart = calendar.startOfDay(for: when)
            guard let i = starts.firstIndex(of: dayStart) else { continue }
            days[i].tokens.add(r)
            summary.week.add(r)
            if let c = pricing.cost(of: r) {
                days[i].cost += c
                summary.weekCost += c
            } else {
                unpriced.insert(r.model)
            }
            if i == days.count - 1, let s = r.sessionID { sessions.insert(s) }
            projects[r.project, default: 0] += r.totalTokens
        }
        summary.days = days
        summary.sessionsToday = sessions.count
        // Ties broken by name so the answer doesn't flicker between refreshes.
        if let top = projects.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), top.value > 0 {
            summary.topProject = (top.key, top.value)
        }
        summary.unpricedModels = unpriced.sorted()
        return summary
    }
}

public enum TokenFormat {
    /// 950, 12.3K, 4.56M, 1.2B
    public static func compact(_ n: Int) -> String {
        let v = Double(n)
        switch abs(v) {
        case ..<1_000: return String(n)
        case ..<1_000_000: return trim(v / 1_000) + "K"
        case ..<1_000_000_000: return trim(v / 1_000_000) + "M"
        default: return trim(v / 1_000_000_000) + "B"
        }
    }

    private static func trim(_ v: Double) -> String {
        let s = v < 10 ? String(format: "%.2f", v) : v < 100 ? String(format: "%.1f", v) : String(format: "%.0f", v)
        guard s.contains(".") else { return s }
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }

    public static func dollars(_ v: Double) -> String {
        v < 0.01 && v > 0 ? "<$0.01" : String(format: "$%.2f", v)
    }
}

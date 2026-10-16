import Foundation
import HootCore
import Observation

/// Parses transcripts off the main thread. Owns the incremental index.
actor UsageWorker {
    private var index = UsageIndex()

    func refresh(root: URL, pricing: PricingTable, now: Date) -> UsageSummary {
        let since = UsageSummary.windowStart(now: now, calendar: .current)
        index.scan(root: root, since: since)
        return UsageSummary.compute(index.records.values, pricing: pricing, now: now)
    }
}

/// Usage stats for the dropdown. Refreshes on transcript changes (FSEvents), at
/// midnight, and when the pricing file changes. Never polls.
@MainActor
@Observable
final class UsageModel {
    private(set) var summary: UsageSummary?
    private(set) var pricing = PricingTable.builtIn
    /// Set when the pricing file can't be read; the built-in prices are used meanwhile.
    private(set) var pricingProblem: String?
    private(set) var lastUpdated: Date?
    private(set) var transcriptsMissing = false

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let worker = UsageWorker()
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var midnight: Task<Void, Never>?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var rerun = false
    @ObservationIgnored private var watchingProjects = false

    static let projectsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    static let defaultPricingFile = PrivateFiles.directory.appendingPathComponent("pricing.json")

    init(settings: SettingsStore) {
        self.settings = settings
    }

    var pricingFile: URL {
        settings.pricingPath.isEmpty ? Self.defaultPricingFile : URL(fileURLWithPath: (settings.pricingPath as NSString).expandingTildeInPath)
    }

    /// `--render-preview --demo` only: invented usage, so public screenshots show no real data.
    func setDemoSample() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let perDay: [(Int, String)] = [(9, "api-server"), (31, "my-app"), (18, "my-app"), (24, "docs-site"), (12, "api-server"), (6, "my-app"), (21, "my-app")]
        var records: [UsageRecord] = []
        for (i, (millions, project)) in perDay.enumerated() {
            let day = cal.date(byAdding: .day, value: i - 6, to: today)!.addingTimeInterval(3600 * 10)
            for s in 0..<3 {
                records.append(UsageRecord(key: "demo-\(i)-\(s)", model: "claude-opus-5-5", timestamp: day.addingTimeInterval(Double(s) * 600),
                                           sessionID: "demo-session-\(i)-\(s)", project: project,
                                           input: 900, output: millions * 9_000, cacheRead: millions * 320_000, cacheWrite5m: millions * 12_000, cacheWrite1h: 0))
            }
        }
        summary = UsageSummary.compute(records, pricing: .builtIn)
        lastUpdated = Date()
    }

    func start() {
        writeDefaultPricingIfMissing()
        startWatching()
        scheduleMidnight()
        refreshSoon(after: .zero)
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        midnight?.cancel()
        pending?.cancel()
    }

    /// Re-point the watcher (the pricing file's folder may have changed) and refresh.
    func pricingPathChanged() {
        startWatching()
        refreshSoon(after: .zero)
    }

    func resetPricingFile() {
        try? HookFiles.writeAtomically(PricingTable.defaultJSON, to: pricingFile, mode: 0o644)
        refreshSoon(after: .zero)
    }

    private func startWatching() {
        watcher?.stop()
        var paths = [pricingFile.deletingLastPathComponent().path]
        watchingProjects = FileManager.default.fileExists(atPath: Self.projectsDir.path)
        if watchingProjects {
            paths.append(Self.projectsDir.path)
        } else {
            // Watch ~/.claude so the first session ever is noticed.
            paths.append(Self.projectsDir.deletingLastPathComponent().path)
        }
        watcher = FileWatcher(paths: paths, latency: 1.5) { [weak self] in
            Task { @MainActor in self?.refreshSoon(after: .milliseconds(500)) }
        }
    }

    private func writeDefaultPricingIfMissing() {
        guard settings.pricingPath.isEmpty, !FileManager.default.fileExists(atPath: Self.defaultPricingFile.path) else { return }
        try? HookFiles.writeAtomically(PricingTable.defaultJSON, to: Self.defaultPricingFile, mode: 0o644)
    }

    /// Debounced; at most one scan runs at a time, and changes during a scan trigger one more.
    func refreshSoon(after delay: Duration) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func refresh() async {
        if running {
            rerun = true
            return
        }
        running = true
        defer { running = false }
        repeat {
            rerun = false
            loadPricing()
            transcriptsMissing = !FileManager.default.fileExists(atPath: Self.projectsDir.path)
            summary = transcriptsMissing
                ? UsageSummary.compute([], pricing: pricing)
                : await worker.refresh(root: Self.projectsDir, pricing: pricing, now: Date())
            lastUpdated = Date()
            // ~/.claude/projects appeared after launch: watch it directly from now on.
            if !transcriptsMissing, !watchingProjects { startWatching() }
        } while rerun
    }

    private func loadPricing() {
        let url = pricingFile
        do {
            let data = try Data(contentsOf: url)
            guard data.count < 1_000_000 else { throw CocoaError(.fileReadTooLarge) }
            pricing = try PricingTable.decode(data)
            pricingProblem = nil
        } catch {
            pricing = .builtIn
            pricingProblem = "Couldn't read \(url.path) (\(Self.describe(error))). Using built-in prices."
        }
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? DecodingError {
            switch e {
            case .dataCorrupted(let c), .keyNotFound(_, let c), .typeMismatch(_, let c), .valueNotFound(_, let c):
                let path = c.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
                return path.isEmpty ? c.debugDescription : "\(path): \(c.debugDescription)"
            @unknown default: return "invalid JSON"
            }
        }
        return (error as NSError).localizedDescription
    }

    /// Today's bar must move to the left at midnight even if nothing is written.
    private func scheduleMidnight() {
        midnight?.cancel()
        midnight = Task { [weak self] in
            while !Task.isCancelled {
                let cal = Calendar.current
                let next = cal.nextDate(after: Date(), matching: DateComponents(hour: 0, minute: 0, second: 5), matchingPolicy: .nextTime) ?? Date().addingTimeInterval(3600)
                try? await Task.sleep(for: .seconds(max(60, next.timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                self?.refreshSoon(after: .zero)
            }
        }
    }
}

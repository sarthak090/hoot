import Foundation
import Observation

/// User preferences, persisted in UserDefaults.
/// What the menu-bar icon shows next to Hoot.
enum MenuBarUsage: String, CaseIterable, Identifiable {
    case off, session, week, both
    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Icon only"
        case .session: "Session used"
        case .week: "Week used"
        case .both: "Session and week used"
        }
    }
}

@MainActor
@Observable
final class SettingsStore {
    static let defaultTerminals = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", // Cursor
    ]
    static let answerTimeoutRange = 30...1800
    static let escalationDelayRange = 10...1800

    @ObservationIgnored private let defaults: UserDefaults

    var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: "soundEnabled") } }
    var escalationEnabled: Bool { didSet { defaults.set(escalationEnabled, forKey: "escalationEnabled") } }
    var escalationDelay: Int {
        didSet {
            let clamped = escalationDelay.clamped(to: Self.escalationDelayRange)
            if clamped != escalationDelay { escalationDelay = clamped; return }
            defaults.set(escalationDelay, forKey: "escalationDelay")
        }
    }
    /// How long a permission request waits for a menu-bar answer before the terminal takes over.
    var answerTimeout: Int {
        didSet {
            let clamped = answerTimeout.clamped(to: Self.answerTimeoutRange)
            if clamped != answerTimeout { answerTimeout = clamped; return }
            defaults.set(answerTimeout, forKey: "answerTimeout")
        }
    }
    var terminalBundleIDs: [String] { didSet { defaults.set(terminalBundleIDs, forKey: "terminalBundleIDs") } }
    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") } }
    /// Empty means the default file in Application Support.
    var pricingPath: String { didSet { defaults.set(pricingPath, forKey: "pricingPath") } }
    var menuBarUsage: MenuBarUsage { didSet { defaults.set(menuBarUsage.rawValue, forKey: "menuBarUsage") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        soundEnabled = defaults.object(forKey: "soundEnabled") as? Bool ?? true
        escalationEnabled = defaults.object(forKey: "escalationEnabled") as? Bool ?? true
        escalationDelay = (defaults.object(forKey: "escalationDelay") as? Int ?? 60).clamped(to: Self.escalationDelayRange)
        answerTimeout = (defaults.object(forKey: "answerTimeout") as? Int ?? 300).clamped(to: Self.answerTimeoutRange)
        terminalBundleIDs = defaults.stringArray(forKey: "terminalBundleIDs") ?? Self.defaultTerminals
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        pricingPath = defaults.string(forKey: "pricingPath") ?? ""
        menuBarUsage = defaults.string(forKey: "menuBarUsage").flatMap(MenuBarUsage.init(rawValue:)) ?? .session
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

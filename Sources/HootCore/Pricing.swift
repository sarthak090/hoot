import Foundation

/// API-equivalent prices in USD per million tokens, loaded from an editable JSON file.
/// This is an estimate of what the same tokens would cost on the API, not a bill:
/// subscription plans are not charged per token.
public struct PricingTable: Sendable, Decodable, Equatable {
    public struct Rates: Sendable, Decodable, Equatable {
        public var input: Double
        public var output: Double
        public var cacheWrite5m: Double
        public var cacheWrite1h: Double
        public var cacheRead: Double
    }

    public struct LongContext: Sendable, Decodable, Equatable {
        /// Requests whose prompt (input + cache read + cache write) exceeds this use `rates`.
        public var aboveInputTokens: Int
        public var rates: Rates
    }

    public struct Model: Sendable, Decodable, Equatable {
        /// Model id, e.g. "claude-opus-5-5". Also matches dated ids like "claude-haiku-4-5-20251001".
        public var match: String
        public var rates: Rates
        /// Multiplier for fast mode, where the model offers it.
        public var fastMultiplier: Double?
        public var longContext: LongContext?
    }

    public var pricesAsOf: String?
    public var models: [Model]

    public func model(for id: String) -> Model? {
        // Exact id, or id plus a date suffix. Never a looser prefix: "claude-sonnet-5"
        // must not price "claude-sonnet-5-5".
        models.first { m in
            id == m.match || (id.hasPrefix(m.match + "-") && id.dropFirst(m.match.count + 1).allSatisfy(\.isNumber))
        }
    }

    /// Estimated cost in USD, or nil when the model isn't in the table.
    public func cost(of r: UsageRecord) -> Double? {
        guard let m = model(for: r.model) else { return nil }
        var rates = m.rates
        if let lc = m.longContext, r.promptTokens > lc.aboveInputTokens { rates = lc.rates }
        let fresh: Double = Double(r.input) * rates.input + Double(r.output) * rates.output
        let cached: Double = Double(r.cacheRead) * rates.cacheRead
            + Double(r.cacheWrite5m) * rates.cacheWrite5m + Double(r.cacheWrite1h) * rates.cacheWrite1h
        let speed: Double = r.fast ? (m.fastMultiplier ?? 1) : 1
        return (fresh + cached) / 1_000_000 * speed
    }

    public static func decode(_ data: Data) throws -> PricingTable {
        try JSONDecoder().decode(PricingTable.self, from: data)
    }

    public static let builtIn: PricingTable = {
        // The default file is generated from this same text, so they can't disagree.
        try! decode(Data(defaultJSON.utf8))
    }()

    /// Written to Application Support on first launch; edit that copy.
    /// Source: Anthropic API pricing as of 2026-10-06. Cache writes are 1.25x (5 min)
    /// and 2x (1 h) the input price; cache reads 0.1x, except where listed otherwise.
    public static let defaultJSON = """
    {
      "_about": "Hoot cost estimate: USD per million tokens at Anthropic API list prices. Edit freely; Hoot reloads this file on every refresh. A model missing here shows as 'unpriced'.",
      "pricesAsOf": "2026-10-06",
      "models": [
        { "match": "claude-fable-5-1", "rates": { "input": 10, "output": 50, "cacheWrite5m": 12.5, "cacheWrite1h": 20, "cacheRead": 0.25 } },
        { "match": "claude-fable-5", "rates": { "input": 10, "output": 50, "cacheWrite5m": 12.5, "cacheWrite1h": 20, "cacheRead": 1 } },
        { "match": "claude-opus-5-5", "rates": { "input": 4, "output": 20, "cacheWrite5m": 5, "cacheWrite1h": 8, "cacheRead": 0.2 }, "fastMultiplier": 2 },
        { "match": "claude-opus-5", "rates": { "input": 5, "output": 25, "cacheWrite5m": 6.25, "cacheWrite1h": 10, "cacheRead": 0.5 }, "fastMultiplier": 2 },
        { "match": "claude-opus-4-8", "rates": { "input": 5, "output": 25, "cacheWrite5m": 6.25, "cacheWrite1h": 10, "cacheRead": 0.5 }, "fastMultiplier": 2 },
        { "match": "claude-opus-4-7", "rates": { "input": 5, "output": 25, "cacheWrite5m": 6.25, "cacheWrite1h": 10, "cacheRead": 0.5 } },
        { "match": "claude-opus-4-6", "rates": { "input": 5, "output": 25, "cacheWrite5m": 6.25, "cacheWrite1h": 10, "cacheRead": 0.5 } },
        { "match": "claude-sonnet-5-5", "rates": { "input": 2, "output": 10, "cacheWrite5m": 2.5, "cacheWrite1h": 4, "cacheRead": 0.2 } },
        { "match": "claude-sonnet-5", "rates": { "input": 2, "output": 10, "cacheWrite5m": 2.5, "cacheWrite1h": 4, "cacheRead": 0.2 } },
        { "match": "claude-sonnet-4-6", "rates": { "input": 3, "output": 15, "cacheWrite5m": 3.75, "cacheWrite1h": 6, "cacheRead": 0.3 } },
        { "match": "claude-haiku-5-5", "rates": { "input": 0.1, "output": 0.5, "cacheWrite5m": 0.125, "cacheWrite1h": 0.2, "cacheRead": 0.01 },
          "longContext": { "aboveInputTokens": 100000, "rates": { "input": 0.5, "output": 2.5, "cacheWrite5m": 0.625, "cacheWrite1h": 1, "cacheRead": 0.05 } } },
        { "match": "claude-haiku-4-5", "rates": { "input": 1, "output": 5, "cacheWrite5m": 1.25, "cacheWrite1h": 2, "cacheRead": 0.1 } }
      ]
    }

    """
}

import Foundation

/// Per-million-token prices plus the cache multipliers the provider actually applies.
///
/// Anthropic bills cache reads at 0.1x the base input rate, 5-minute cache writes at
/// 1.25x, and 1-hour cache writes at 2x. Charging every input-side token at the full
/// input rate, as the first version of this app did, overstates spend by roughly 2x on
/// a cache-heavy agent workload and by far more on long sessions.
public struct ModelPricing: Codable, Sendable, Equatable, Identifiable {
    public var id: String { model }

    /// Substring matched, case-insensitively, against the model id reported by the CLI.
    public var model: String
    public var inputPerMillion: Double
    public var outputPerMillion: Double
    /// Multiplier on `inputPerMillion` for tokens served from cache.
    public var cacheReadMultiplier: Double
    /// Multiplier on `inputPerMillion` for tokens written to the 5-minute cache.
    public var cacheWrite5mMultiplier: Double
    /// Multiplier on `inputPerMillion` for tokens written to the 1-hour cache.
    public var cacheWrite1hMultiplier: Double

    public init(
        model: String,
        inputPerMillion: Double,
        outputPerMillion: Double,
        cacheReadMultiplier: Double = 0.1,
        cacheWrite5mMultiplier: Double = 1.25,
        cacheWrite1hMultiplier: Double = 2.0
    ) {
        self.model = model
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cacheReadMultiplier = cacheReadMultiplier
        self.cacheWrite5mMultiplier = cacheWrite5mMultiplier
        self.cacheWrite1hMultiplier = cacheWrite1hMultiplier
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(String.self, forKey: .model)
        inputPerMillion = try c.decode(Double.self, forKey: .inputPerMillion)
        outputPerMillion = try c.decode(Double.self, forKey: .outputPerMillion)
        cacheReadMultiplier = try c.decodeIfPresent(Double.self, forKey: .cacheReadMultiplier) ?? 0.1
        cacheWrite5mMultiplier = try c.decodeIfPresent(Double.self, forKey: .cacheWrite5mMultiplier) ?? 1.25
        cacheWrite1hMultiplier = try c.decodeIfPresent(Double.self, forKey: .cacheWrite1hMultiplier) ?? 2.0
    }

    private enum CodingKeys: String, CodingKey {
        case model, inputPerMillion, outputPerMillion
        case cacheReadMultiplier, cacheWrite5mMultiplier, cacheWrite1hMultiplier
    }

    public func estimateCost(usage: TokenUsage) -> Double {
        let perInputToken = inputPerMillion / 1_000_000.0
        let perOutputToken = outputPerMillion / 1_000_000.0
        var total = Double(usage.inputTokens) * perInputToken
        total += Double(usage.cacheReadTokens) * perInputToken * cacheReadMultiplier
        total += Double(usage.cacheWrite5mTokens) * perInputToken * cacheWrite5mMultiplier
        total += Double(usage.cacheWrite1hTokens) * perInputToken * cacheWrite1hMultiplier
        total += Double(usage.outputTokens) * perOutputToken
        return total
    }

    /// Input-token equivalents: what this usage would have cost, expressed in units of
    /// uncached input tokens. This is the number the window bars track, because a raw
    /// token count is dominated by cache reads and therefore says nothing about quota.
    public func billableTokens(usage: TokenUsage) -> Double {
        var total = Double(usage.inputTokens)
        total += Double(usage.cacheReadTokens) * cacheReadMultiplier
        total += Double(usage.cacheWrite5mTokens) * cacheWrite5mMultiplier
        total += Double(usage.cacheWrite1hTokens) * cacheWrite1hMultiplier
        // Output is priced at a different rate entirely, so convert it into input-token
        // equivalents using the model's own output/input ratio rather than counting 1:1.
        let outputWeight = inputPerMillion > 0 ? outputPerMillion / inputPerMillion : 1
        total += Double(usage.outputTokens) * outputWeight
        return total
    }
}

/// The current published list prices. Matching is longest-substring-first, so
/// `claude-opus-4-8` wins over a hypothetical bare `claude` entry.
public enum DefaultPricing {
    public static let table: [ModelPricing] = [
        // Anthropic
        ModelPricing(model: "claude-fable-5", inputPerMillion: 10.0, outputPerMillion: 50.0),
        ModelPricing(model: "claude-mythos-5", inputPerMillion: 10.0, outputPerMillion: 50.0),
        ModelPricing(model: "claude-opus-4-8", inputPerMillion: 5.0, outputPerMillion: 25.0),
        ModelPricing(model: "claude-opus-4-7", inputPerMillion: 5.0, outputPerMillion: 25.0),
        ModelPricing(model: "claude-opus-4-6", inputPerMillion: 5.0, outputPerMillion: 25.0),
        ModelPricing(model: "claude-opus-4-5", inputPerMillion: 5.0, outputPerMillion: 25.0),
        ModelPricing(model: "claude-opus", inputPerMillion: 15.0, outputPerMillion: 75.0),
        ModelPricing(model: "claude-sonnet-5", inputPerMillion: 3.0, outputPerMillion: 15.0),
        ModelPricing(model: "claude-sonnet-4-6", inputPerMillion: 3.0, outputPerMillion: 15.0),
        ModelPricing(model: "claude-sonnet", inputPerMillion: 3.0, outputPerMillion: 15.0),
        ModelPricing(model: "claude-haiku-4-5", inputPerMillion: 1.0, outputPerMillion: 5.0),
        ModelPricing(model: "claude-haiku", inputPerMillion: 0.80, outputPerMillion: 4.0),

        // Moonshot / Kimi
        ModelPricing(model: "kimi-code/k3", inputPerMillion: 0.60, outputPerMillion: 2.50),
        ModelPricing(model: "kimi-for-coding", inputPerMillion: 0.60, outputPerMillion: 2.50),
        ModelPricing(model: "kimi", inputPerMillion: 0.60, outputPerMillion: 2.50),

        // OpenAI
        ModelPricing(model: "gpt-5.6", inputPerMillion: 1.25, outputPerMillion: 10.0, cacheReadMultiplier: 0.1),
        ModelPricing(model: "gpt-5.5", inputPerMillion: 1.25, outputPerMillion: 10.0, cacheReadMultiplier: 0.1),
        ModelPricing(model: "gpt-5", inputPerMillion: 1.25, outputPerMillion: 10.0, cacheReadMultiplier: 0.1),
        ModelPricing(model: "gpt-4o", inputPerMillion: 2.50, outputPerMillion: 10.0, cacheReadMultiplier: 0.5),

        // Google
        ModelPricing(model: "gemini-3", inputPerMillion: 2.0, outputPerMillion: 12.0, cacheReadMultiplier: 0.1),
        ModelPricing(model: "gemini", inputPerMillion: 1.25, outputPerMillion: 10.0, cacheReadMultiplier: 0.1),

        // xAI
        ModelPricing(model: "grok-4", inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadMultiplier: 0.25),

        ModelPricing(model: "default", inputPerMillion: 3.0, outputPerMillion: 15.0),
    ]

    /// Longest match wins, so a specific version beats a family prefix regardless of
    /// the order entries happen to sit in the user's edited pricing JSON.
    public static func match(_ model: String, in table: [ModelPricing]) -> ModelPricing {
        let lower = model.lowercased()
        let candidates = table.filter { $0.model != "default" && lower.contains($0.model.lowercased()) }
        if let best = candidates.max(by: { $0.model.count < $1.model.count }) {
            return best
        }
        return table.first(where: { $0.model == "default" })
            ?? ModelPricing(model: "default", inputPerMillion: 3.0, outputPerMillion: 15.0)
    }
}

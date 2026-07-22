import Foundation

/// Per-source window limits, expressed in input-token-equivalents.
///
/// Zero means "not set by the user". The engine then falls back to a limit measured
/// from an observed limit hit, and only then to a plan-derived estimate. The previous
/// version hardcoded invented numbers here and presented them as if they were real,
/// which is what made the dashboard read `1.3B / 30.0M`.
public struct SourceWindowLimits: Codable, Sendable, Equatable {
    public var sessionBillable: Double
    public var weeklyBillable: Double

    public init(sessionBillable: Double = 0, weeklyBillable: Double = 0) {
        self.sessionBillable = sessionBillable
        self.weeklyBillable = weeklyBillable
    }

    public var isUnset: Bool { sessionBillable <= 0 && weeklyBillable <= 0 }

    public static let unset = SourceWindowLimits()
}

public struct PerSourceLimits: Codable, Sendable, Equatable {
    /// Keyed by `DashboardSource.rawValue` so new sources need no schema change.
    public var overrides: [String: SourceWindowLimits]

    public init(overrides: [String: SourceWindowLimits] = [:]) {
        self.overrides = overrides
    }

    public static let `default` = PerSourceLimits()

    public func limits(for source: DashboardSource) -> SourceWindowLimits {
        overrides[source.rawValue] ?? .unset
    }

    public mutating func setLimits(_ limits: SourceWindowLimits, for source: DashboardSource) {
        if limits.isUnset {
            overrides.removeValue(forKey: source.rawValue)
        } else {
            overrides[source.rawValue] = limits
        }
    }
}

public struct AlertThresholds: Codable, Sendable, Equatable {
    public var burnSpikeMultiplier: Double
    public var dailyCapTokens: Int
    public var cacheMissRatioFloor: Double
    public var cacheMissWindow: Int
    public var loopMessageCount: Int
    public var loopWindowSeconds: Int

    public init(
        burnSpikeMultiplier: Double = 3.0,
        dailyCapTokens: Int = 5_000_000,
        cacheMissRatioFloor: Double = 0.30,
        cacheMissWindow: Int = 20,
        loopMessageCount: Int = 50,
        loopWindowSeconds: Int = 600
    ) {
        self.burnSpikeMultiplier = burnSpikeMultiplier
        self.dailyCapTokens = dailyCapTokens
        self.cacheMissRatioFloor = cacheMissRatioFloor
        self.cacheMissWindow = cacheMissWindow
        self.loopMessageCount = loopMessageCount
        self.loopWindowSeconds = loopWindowSeconds
    }

    public static let `default` = AlertThresholds()
}

public struct SourcePaths: Codable, Sendable, Equatable {
    /// Keyed by `TokenSource.rawValue`. A dictionary rather than one stored property
    /// per CLI, so adding a source does not break decoding of an existing settings file.
    public var roots: [String: String]

    public init(roots: [String: String] = [:]) {
        var merged = SourcePaths.defaultRoots
        for (k, v) in roots where !v.isEmpty { merged[k] = v }
        self.roots = merged
    }

    public static var defaultRoots: [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            TokenSource.claudeWork.rawValue: "\(home)/.claude-work/projects",
            TokenSource.claude.rawValue: "\(home)/.claude/projects",
            TokenSource.claudePersonal.rawValue: "\(home)/.claude-personal/projects",
            TokenSource.kimi.rawValue: "\(home)/.kimi-code/sessions",
            TokenSource.cursor.rawValue: "\(home)/.cursor/ai-tracking/ai-code-tracking.db",
            TokenSource.codex.rawValue: "\(home)/.codex/sessions",
            TokenSource.gemini.rawValue: "\(home)/.gemini/tmp",
            TokenSource.opencode.rawValue: "\(home)/.local/share/opencode/opencode.db",
            TokenSource.crush.rawValue: "\(home)/.crush/crush.db",
            TokenSource.copilot.rawValue: "\(home)/.copilot/session-state",
        ]
    }

    public func root(for source: TokenSource) -> String {
        roots[source.rawValue] ?? SourcePaths.defaultRoots[source.rawValue] ?? ""
    }

    public mutating func setRoot(_ path: String, for source: TokenSource) {
        roots[source.rawValue] = path
    }

    /// Whether this CLI has actually been used on this machine.
    public func exists(_ source: TokenSource) -> Bool {
        let path = root(for: source)
        return !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }

    // Convenience accessors kept for call sites and tests that read a specific source.
    public var claudeWorkProjects: String { root(for: .claudeWork) }
    public var claudeProjects: String { root(for: .claude) }
    public var claudePersonalProjects: String { root(for: .claudePersonal) }
    public var kimiSessions: String { root(for: .kimi) }
    public var cursorTrackingDB: String { root(for: .cursor) }

    public static let `default` = SourcePaths()
}

public struct SourceToggles: Codable, Sendable, Equatable {
    /// Explicit user choices. A source absent from this map follows auto-detection.
    public var explicit: [String: Bool]
    /// When on, any CLI whose data directory exists is monitored without being
    /// enumerated here first.
    public var autoDetect: Bool

    public init(explicit: [String: Bool] = [:], autoDetect: Bool = true) {
        self.explicit = explicit
        self.autoDetect = autoDetect
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        explicit = try c.decodeIfPresent([String: Bool].self, forKey: .explicit) ?? [:]
        autoDetect = try c.decodeIfPresent(Bool.self, forKey: .autoDetect) ?? true
    }

    private enum CodingKeys: String, CodingKey { case explicit, autoDetect }

    public func isEnabled(_ source: TokenSource, paths: SourcePaths) -> Bool {
        if let choice = explicit[source.rawValue] { return choice }
        guard autoDetect else { return false }
        return paths.exists(source)
    }

    public mutating func set(_ enabled: Bool, for source: TokenSource) {
        explicit[source.rawValue] = enabled
    }

    public mutating func clearOverride(for source: TokenSource) {
        explicit.removeValue(forKey: source.rawValue)
    }

    public static let `default` = SourceToggles()
}

public struct AppSettings: Codable, Sendable, Equatable {
    public var paths: SourcePaths
    public var toggles: SourceToggles
    public var pricing: [ModelPricing]
    public var thresholds: AlertThresholds
    public var sourceLimits: PerSourceLimits
    public var pollIntervalSeconds: Int
    public var launchAtLogin: Bool
    public var paused: Bool
    /// Manual plan selection per source, keyed by `TokenSource.rawValue`. Empty by
    /// default: the plan is read out of the CLI's own config instead of guessed.
    public var planOverrides: [String: PlanTier]

    public init(
        paths: SourcePaths = .default,
        toggles: SourceToggles = .default,
        pricing: [ModelPricing] = AppSettings.defaultPricing,
        thresholds: AlertThresholds = .default,
        sourceLimits: PerSourceLimits = .default,
        pollIntervalSeconds: Int = 5,
        launchAtLogin: Bool = false,
        paused: Bool = false,
        planOverrides: [String: PlanTier] = [:]
    ) {
        self.paths = paths
        self.toggles = toggles
        self.pricing = pricing
        self.thresholds = thresholds
        self.sourceLimits = sourceLimits
        self.pollIntervalSeconds = pollIntervalSeconds
        self.launchAtLogin = launchAtLogin
        self.paused = paused
        self.planOverrides = planOverrides
    }

    public static let defaultPricing: [ModelPricing] = DefaultPricing.table

    public static let `default` = AppSettings()

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Every field is optional on read: an older settings file, or one written by a
        // build that predates a field, must still load rather than resetting to defaults.
        paths = try c.decodeIfPresent(SourcePaths.self, forKey: .paths) ?? .default
        toggles = try c.decodeIfPresent(SourceToggles.self, forKey: .toggles) ?? .default
        pricing = try c.decodeIfPresent([ModelPricing].self, forKey: .pricing) ?? AppSettings.defaultPricing
        thresholds = try c.decodeIfPresent(AlertThresholds.self, forKey: .thresholds) ?? .default
        sourceLimits = try c.decodeIfPresent(PerSourceLimits.self, forKey: .sourceLimits) ?? .default
        pollIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? 5
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        planOverrides = try c.decodeIfPresent([String: PlanTier].self, forKey: .planOverrides) ?? [:]
    }

    private enum CodingKeys: String, CodingKey {
        case paths, toggles, pricing, thresholds, sourceLimits, pollIntervalSeconds
        case launchAtLogin, paused, planOverrides
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(paths, forKey: .paths)
        try c.encode(toggles, forKey: .toggles)
        try c.encode(pricing, forKey: .pricing)
        try c.encode(thresholds, forKey: .thresholds)
        try c.encode(sourceLimits, forKey: .sourceLimits)
        try c.encode(pollIntervalSeconds, forKey: .pollIntervalSeconds)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(paused, forKey: .paused)
        try c.encode(planOverrides, forKey: .planOverrides)
    }

    /// Longest-substring match, so `claude-opus-4-8` beats the `claude-opus` family row
    /// regardless of the order the entries sit in.
    public func price(for model: String) -> ModelPricing {
        DefaultPricing.match(model, in: pricing)
    }

    public func estimateCost(usage: TokenUsage, model: String = "default") -> Double {
        price(for: model).estimateCost(usage: usage)
    }

    /// Cost of a per-model breakdown. Aggregating first and pricing once, as the old
    /// code did, charges an Opus rate for Haiku tokens or the reverse.
    public func estimateCost(byModel: [String: TokenUsage]) -> Double {
        byModel.reduce(0) { $0 + price(for: $1.key).estimateCost(usage: $1.value) }
    }

    /// Input-token-equivalents for a per-model breakdown. This is what the window bars
    /// track, because a raw token total is ~95% cache reads and says nothing about quota.
    public func billableTokens(byModel: [String: TokenUsage]) -> Double {
        byModel.reduce(0) { $0 + price(for: $1.key).billableTokens(usage: $1.value) }
    }

    public var pricingJSON: String {
        get {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? enc.encode(pricing),
                  let s = String(data: data, encoding: .utf8) else { return "[]" }
            return s
        }
        set {
            guard let data = newValue.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([ModelPricing].self, from: data) else { return }
            pricing = decoded
        }
    }
}

public enum SettingsStore {
    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Agamemnon", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }

    public static func load() -> AppSettings {
        migrateLegacySettingsIfNeeded()
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    private static func migrateLegacySettingsIfNeeded() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let wardenDir = base.appendingPathComponent("Warden", isDirectory: true)
        let legacy = wardenDir.appendingPathComponent("settings.json")
        let current = url
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: current.path) else { return }
        try? fm.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.copyItem(at: legacy, to: current)
    }

    public static func save(_ settings: AppSettings) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(settings) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

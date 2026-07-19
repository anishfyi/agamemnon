import Foundation

public struct SourceWindowLimits: Codable, Sendable, Equatable {
    public var fiveHourTokens: Int
    public var weeklyTokens: Int

    public init(fiveHourTokens: Int = 5_000_000, weeklyTokens: Int = 25_000_000) {
        self.fiveHourTokens = fiveHourTokens
        self.weeklyTokens = weeklyTokens
    }
}

public struct PerSourceLimits: Codable, Sendable, Equatable {
    public var kimi: SourceWindowLimits
    public var cursor: SourceWindowLimits
    public var claudeWork: SourceWindowLimits

    public init(
        kimi: SourceWindowLimits = SourceWindowLimits(fiveHourTokens: 3_000_000, weeklyTokens: 15_000_000),
        cursor: SourceWindowLimits = SourceWindowLimits(fiveHourTokens: 5_000_000, weeklyTokens: 25_000_000),
        claudeWork: SourceWindowLimits = SourceWindowLimits(fiveHourTokens: 5_000_000, weeklyTokens: 30_000_000)
    ) {
        self.kimi = kimi
        self.cursor = cursor
        self.claudeWork = claudeWork
    }

    public static let `default` = PerSourceLimits()

    public func limits(for source: DashboardSource) -> SourceWindowLimits {
        switch source {
        case .kimi: return kimi
        case .cursor: return cursor
        case .claudeWork: return claudeWork
        }
    }

    public mutating func setLimits(_ limits: SourceWindowLimits, for source: DashboardSource) {
        switch source {
        case .kimi: kimi = limits
        case .cursor: cursor = limits
        case .claudeWork: claudeWork = limits
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
    public var claudeWorkProjects: String
    public var claudeProjects: String
    public var claudePersonalProjects: String
    public var kimiSessions: String
    public var cursorTrackingDB: String
    public var cursorDebugLogs: String
    public var cursorChats: String

    public init(
        claudeWorkProjects: String? = nil,
        claudeProjects: String? = nil,
        claudePersonalProjects: String? = nil,
        kimiSessions: String? = nil,
        cursorTrackingDB: String? = nil,
        cursorDebugLogs: String? = nil,
        cursorChats: String? = nil
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.claudeWorkProjects = claudeWorkProjects ?? "\(home)/.claude-work/projects"
        self.claudeProjects = claudeProjects ?? "\(home)/.claude/projects"
        self.claudePersonalProjects = claudePersonalProjects ?? "\(home)/.claude-personal/projects"
        self.kimiSessions = kimiSessions ?? "\(home)/.kimi-code/sessions"
        self.cursorTrackingDB = cursorTrackingDB ?? "\(home)/.cursor/ai-tracking/ai-code-tracking.db"
        self.cursorDebugLogs = cursorDebugLogs ?? "\(home)/.cursor/debug-logs"
        self.cursorChats = cursorChats ?? "\(home)/.cursor/chats"
    }

    public static let `default` = SourcePaths()
}

public struct SourceToggles: Codable, Sendable, Equatable {
    public var claudeWork: Bool
    public var claude: Bool
    public var claudePersonal: Bool
    public var kimi: Bool
    public var cursor: Bool

    public init(
        claudeWork: Bool = true,
        claude: Bool = false,
        claudePersonal: Bool = false,
        kimi: Bool = true,
        cursor: Bool = true
    ) {
        self.claudeWork = claudeWork
        self.claude = claude
        self.claudePersonal = claudePersonal
        self.kimi = kimi
        self.cursor = cursor
    }

    public func isEnabled(_ source: TokenSource) -> Bool {
        switch source {
        case .claudeWork: return claudeWork
        case .claude: return claude
        case .claudePersonal: return claudePersonal
        case .kimi: return kimi
        case .cursor: return cursor
        }
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

    public init(
        paths: SourcePaths = .default,
        toggles: SourceToggles = .default,
        pricing: [ModelPricing] = AppSettings.defaultPricing,
        thresholds: AlertThresholds = .default,
        sourceLimits: PerSourceLimits = .default,
        pollIntervalSeconds: Int = 5,
        launchAtLogin: Bool = false,
        paused: Bool = false
    ) {
        self.paths = paths
        self.toggles = toggles
        self.pricing = pricing
        self.thresholds = thresholds
        self.sourceLimits = sourceLimits
        self.pollIntervalSeconds = pollIntervalSeconds
        self.launchAtLogin = launchAtLogin
        self.paused = paused
    }

    public static let defaultPricing: [ModelPricing] = [
        ModelPricing(model: "claude-opus", inputPerMillion: 15.0, outputPerMillion: 75.0),
        ModelPricing(model: "claude-sonnet", inputPerMillion: 3.0, outputPerMillion: 15.0),
        ModelPricing(model: "claude-haiku", inputPerMillion: 0.80, outputPerMillion: 4.0),
        ModelPricing(model: "kimi", inputPerMillion: 0.60, outputPerMillion: 2.50),
        ModelPricing(model: "gpt-4o", inputPerMillion: 2.50, outputPerMillion: 10.0),
        ModelPricing(model: "gpt-4.1", inputPerMillion: 2.0, outputPerMillion: 8.0),
        ModelPricing(model: "default", inputPerMillion: 3.0, outputPerMillion: 15.0),
    ]

    public static let `default` = AppSettings()

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paths = try c.decode(SourcePaths.self, forKey: .paths)
        toggles = try c.decode(SourceToggles.self, forKey: .toggles)
        pricing = try c.decodeIfPresent([ModelPricing].self, forKey: .pricing) ?? AppSettings.defaultPricing
        thresholds = try c.decodeIfPresent(AlertThresholds.self, forKey: .thresholds) ?? .default
        sourceLimits = try c.decodeIfPresent(PerSourceLimits.self, forKey: .sourceLimits) ?? .default
        pollIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? 5
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case paths, toggles, pricing, thresholds, sourceLimits, pollIntervalSeconds, launchAtLogin, paused
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
    }

    public func price(for model: String) -> ModelPricing {
        let lower = model.lowercased()
        if let exact = pricing.first(where: { lower.contains($0.model.lowercased()) && $0.model != "default" }) {
            return exact
        }
        return pricing.first(where: { $0.model == "default" })
            ?? ModelPricing(model: "default", inputPerMillion: 3.0, outputPerMillion: 15.0)
    }

    public func estimateCost(usage: TokenUsage, model: String = "default") -> Double {
        price(for: model).estimateCost(usage: usage)
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

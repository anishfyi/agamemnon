import Foundation

public enum DashboardSource: String, Codable, CaseIterable, Sendable, Identifiable {
    case kimi = "kimi"
    case cursor = "cursor"
    case claudeWork = "claude-work"

    public var id: String { rawValue }

    public var tokenSource: TokenSource {
        switch self {
        case .kimi: return .kimi
        case .cursor: return .cursor
        case .claudeWork: return .claudeWork
        }
    }

    public var displayName: String {
        switch self {
        case .kimi: return "Kimi Code CLI"
        case .cursor: return "Cursor CLI"
        case .claudeWork: return "Claude Code (claude-work)"
        }
    }

    public var shortName: String {
        switch self {
        case .kimi: return "kimi"
        case .cursor: return "cursor"
        case .claudeWork: return "claude-work"
        }
    }
}

public enum SpendState: String, Sendable {
    case ok
    case warning
    case critical

    public static func from(ratio: Double) -> SpendState {
        if ratio >= 0.90 { return .critical }
        if ratio >= 0.70 { return .warning }
        return .ok
    }
}

public struct SourceSpendStats: Sendable, Identifiable {
    public var id: String { source.rawValue }
    public var source: DashboardSource
    public var today: TokenUsage
    public var fiveHour: TokenUsage
    public var sevenDay: TokenUsage
    public var burnPerMinute: Double
    public var estimatedCost: Double
    public var fiveHourReset: Date?
    public var weeklyReset: Date?
    public var fiveHourRatio: Double
    public var weeklyRatio: Double
    public var state: SpendState
    public var tokensUnavailable: Bool
    public var activityNote: String
}

public enum TokenSource: String, Codable, CaseIterable, Sendable, Identifiable {
    case claudeWork = "claude-work"
    case claude = "claude"
    case claudePersonal = "claude-personal"
    case kimi = "kimi"
    case cursor = "cursor"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeWork: return "Claude Code (work)"
        case .claude: return "Claude Code"
        case .claudePersonal: return "Claude Code (personal)"
        case .kimi: return "Kimi Code"
        case .cursor: return "Cursor CLI"
        }
    }

    public var isClaudeFamily: Bool {
        switch self {
        case .claudeWork, .claude, .claudePersonal: return true
        default: return false
        }
    }
}

public struct TokenUsage: Codable, Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationTokens: Int
    public var cacheReadTokens: Int

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
    }

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    public var totalInput: Int {
        inputTokens + cacheCreationTokens + cacheReadTokens
    }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheCreationTokens: lhs.cacheCreationTokens + rhs.cacheCreationTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens
        )
    }

    public static let zero = TokenUsage()
}

public struct UsageEvent: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var source: TokenSource
    public var sessionId: String
    public var project: String
    public var model: String
    public var timestamp: Date
    public var usage: TokenUsage
    public var messageId: String?

    public init(
        id: String = UUID().uuidString,
        source: TokenSource,
        sessionId: String,
        project: String,
        model: String,
        timestamp: Date,
        usage: TokenUsage,
        messageId: String? = nil
    ) {
        self.id = id
        self.source = source
        self.sessionId = sessionId
        self.project = project
        self.model = model
        self.timestamp = timestamp
        self.usage = usage
        self.messageId = messageId
    }
}

public struct SessionSummary: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var source: TokenSource
    public var project: String
    public var startTime: Date
    public var endTime: Date
    public var usage: TokenUsage
    public var messageCount: Int
    public var model: String

    public var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }

    public init(
        id: String,
        source: TokenSource,
        project: String,
        startTime: Date,
        endTime: Date,
        usage: TokenUsage,
        messageCount: Int,
        model: String = ""
    ) {
        self.id = id
        self.source = source
        self.project = project
        self.startTime = startTime
        self.endTime = endTime
        self.usage = usage
        self.messageCount = messageCount
        self.model = model
    }
}

public enum AlertKind: String, Codable, CaseIterable, Sendable {
    case burnSpike = "burn_spike"
    case dailyCap = "daily_cap"
    case cacheMissAnomaly = "cache_miss"
    case loopDetection = "loop"

    public var displayName: String {
        switch self {
        case .burnSpike: return "Burn spike"
        case .dailyCap: return "Daily cap"
        case .cacheMissAnomaly: return "Cache-miss anomaly"
        case .loopDetection: return "Loop detection"
        }
    }
}

public struct AbuseAlert: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var kind: AlertKind
    public var source: TokenSource
    public var sessionId: String?
    public var message: String
    public var firedAt: Date
    public var acknowledged: Bool
    public var value: Double
    public var threshold: Double

    public init(
        id: String = UUID().uuidString,
        kind: AlertKind,
        source: TokenSource,
        sessionId: String? = nil,
        message: String,
        firedAt: Date = Date(),
        acknowledged: Bool = false,
        value: Double = 0,
        threshold: Double = 0
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.sessionId = sessionId
        self.message = message
        self.firedAt = firedAt
        self.acknowledged = acknowledged
        self.value = value
        self.threshold = threshold
    }
}

public struct HourlyBucket: Codable, Sendable, Identifiable, Equatable {
    public var id: String { "\(source.rawValue)-\(hour.timeIntervalSince1970)" }
    public var source: TokenSource
    public var hour: Date
    public var usage: TokenUsage

    public init(source: TokenSource, hour: Date, usage: TokenUsage) {
        self.source = source
        self.hour = hour
        self.usage = usage
    }
}

public struct DailyBucket: Codable, Sendable, Identifiable, Equatable {
    public var id: String { "\(source.rawValue)-\(day.timeIntervalSince1970)" }
    public var source: TokenSource
    public var day: Date
    public var usage: TokenUsage

    public init(source: TokenSource, day: Date, usage: TokenUsage) {
        self.source = source
        self.day = day
        self.usage = usage
    }
}

public struct ModelPricing: Codable, Sendable, Equatable, Identifiable {
    public var id: String { model }
    public var model: String
    public var inputPerMillion: Double
    public var outputPerMillion: Double

    public init(model: String, inputPerMillion: Double, outputPerMillion: Double) {
        self.model = model
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
    }

    public func estimateCost(usage: TokenUsage) -> Double {
        let input = Double(usage.totalInput) / 1_000_000.0 * inputPerMillion
        let output = Double(usage.outputTokens) / 1_000_000.0 * outputPerMillion
        return input + output
    }
}

public enum TokenFormat {
    public static func compact(_ n: Int) -> String {
        let v = Double(n)
        if abs(v) >= 1_000_000_000 {
            return String(format: "%.1fB", v / 1_000_000_000)
        }
        if abs(v) >= 1_000_000 {
            return String(format: "%.1fM", v / 1_000_000)
        }
        if abs(v) >= 1_000 {
            return String(format: "%.1fK", v / 1_000)
        }
        return "\(n)"
    }

    public static func currency(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    public static func duration(_ interval: TimeInterval) -> String {
        let s = Int(interval)
        let h = s / 3600
        let m = (s % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }

    public static func resetTime(_ date: Date?) -> String {
        guard let date else { return "n/a" }
        let remaining = date.timeIntervalSinceNow
        if remaining <= 0 { return "now" }
        return "resets in \(duration(remaining))"
    }
}

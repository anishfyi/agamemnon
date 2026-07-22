import Foundation

/// The dashboard shows one card per token source, ordered by `dashboardPriority`.
/// This used to be a separate three-case enum that had to be edited in lockstep with
/// `TokenSource`; folding it in means adding a CLI is a single new case.
public typealias DashboardSource = TokenSource

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

/// Where a window limit came from. Shown in the UI so an invented default is never
/// mistaken for a real quota.
public enum LimitOrigin: String, Codable, Sendable {
    /// Seeded from the detected plan tier. An educated guess, not a published number.
    case planEstimate = "estimate"
    /// Derived from an observed limit-hit event in the CLI's own transcripts.
    case measured = "measured"
    /// Typed in by the user in Settings.
    case userSet = "user-set"
    /// No limit applies (pay-as-you-go) or none is known yet.
    case none = "none"

    public var label: String {
        switch self {
        case .planEstimate: return "estimated"
        case .measured: return "measured"
        case .userSet: return "user-set"
        case .none: return "no limit"
        }
    }
}

public struct WindowStats: Sendable {
    /// Wall-clock start of the window this measures.
    public var start: Date
    /// When the window rolls over. For Claude this is the real reset time reported by
    /// the CLI when a limit was hit, not an extrapolation.
    public var reset: Date?
    public var usage: TokenUsage
    /// Input-token-equivalents consumed, the number the bar actually tracks.
    public var billable: Double
    public var cost: Double
    /// Limit in input-token-equivalents. Zero means unlimited or unknown.
    public var limit: Double
    public var origin: LimitOrigin

    public var ratio: Double {
        limit > 0 ? billable / limit : 0
    }

    public init(
        start: Date,
        reset: Date? = nil,
        usage: TokenUsage = .zero,
        billable: Double = 0,
        cost: Double = 0,
        limit: Double = 0,
        origin: LimitOrigin = .none
    ) {
        self.start = start
        self.reset = reset
        self.usage = usage
        self.billable = billable
        self.cost = cost
        self.limit = limit
        self.origin = origin
    }
}

public struct SourceSpendStats: Sendable, Identifiable {
    public var id: String { source.rawValue }
    public var source: DashboardSource
    public var today: TokenUsage
    public var todayCost: Double
    public var session: WindowStats
    public var weekly: WindowStats
    /// Billable input-token-equivalents per minute over the last 15 minutes.
    public var burnPerMinute: Double
    public var state: SpendState
    public var tokensUnavailable: Bool
    public var activityNote: String
    /// Set when the CLI reported an active limit that has not yet reset.
    public var activeLimitHit: LimitHit?

    public init(
        source: DashboardSource,
        today: TokenUsage = .zero,
        todayCost: Double = 0,
        session: WindowStats,
        weekly: WindowStats,
        burnPerMinute: Double = 0,
        state: SpendState = .ok,
        tokensUnavailable: Bool = false,
        activityNote: String = "",
        activeLimitHit: LimitHit? = nil
    ) {
        self.source = source
        self.today = today
        self.todayCost = todayCost
        self.session = session
        self.weekly = weekly
        self.burnPerMinute = burnPerMinute
        self.state = state
        self.tokensUnavailable = tokensUnavailable
        self.activityNote = activityNote
        self.activeLimitHit = activeLimitHit
    }
}

public enum TokenSource: String, Codable, CaseIterable, Sendable, Identifiable {
    case claudeWork = "claude-work"
    case claude = "claude"
    case claudePersonal = "claude-personal"
    case kimi = "kimi"
    case cursor = "cursor"
    case codex = "codex"
    case gemini = "gemini"
    case opencode = "opencode"
    case crush = "crush"
    case copilot = "copilot"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeWork: return "Claude Code (work)"
        case .claude: return "Claude Code"
        case .claudePersonal: return "Claude Code (personal)"
        case .kimi: return "Kimi Code CLI"
        case .cursor: return "Cursor CLI"
        case .codex: return "Codex CLI"
        case .gemini: return "Gemini CLI"
        case .opencode: return "OpenCode"
        case .crush: return "Crush"
        case .copilot: return "Copilot CLI"
        }
    }

    public var shortName: String { rawValue }

    /// Lower sorts first on the dashboard.
    public var dashboardPriority: Int {
        switch self {
        case .kimi: return 0
        case .cursor: return 1
        case .claudeWork: return 2
        case .claude: return 3
        case .claudePersonal: return 4
        case .codex: return 5
        case .gemini: return 6
        case .opencode: return 7
        case .crush: return 8
        case .copilot: return 9
        }
    }

    public var isClaudeFamily: Bool {
        switch self {
        case .claudeWork, .claude, .claudePersonal: return true
        default: return false
        }
    }

    /// Sources whose provider enforces a session and weekly quota we can track.
    /// Everything else is metered purely by spend.
    public var hasSubscriptionWindows: Bool { isClaudeFamily }

    /// True when the provider keeps all token accounting server-side, so the card must
    /// say so instead of showing a fabricated zero.
    public var tokensAreServerSideOnly: Bool { self == .cursor }

    public static var dashboardOrder: [TokenSource] {
        allCases.sorted { $0.dashboardPriority < $1.dashboardPriority }
    }
}

public struct TokenUsage: Codable, Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    /// Total tokens written to cache, across both TTLs.
    public var cacheCreationTokens: Int
    public var cacheReadTokens: Int
    /// The subset of `cacheCreationTokens` written to the 1-hour cache, which bills at
    /// 2x rather than 1.25x. Sources that do not report the split leave this at zero,
    /// which correctly treats their writes as the cheaper 5-minute kind.
    public var cacheWrite1hTokens: Int

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWrite1hTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWrite1hTokens = min(cacheWrite1hTokens, cacheCreationTokens)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cacheCreationTokens = try c.decodeIfPresent(Int.self, forKey: .cacheCreationTokens) ?? 0
        cacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
        cacheWrite1hTokens = try c.decodeIfPresent(Int.self, forKey: .cacheWrite1hTokens) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, cacheWrite1hTokens
    }

    /// The subset of `cacheCreationTokens` written to the 5-minute cache.
    public var cacheWrite5mTokens: Int {
        max(0, cacheCreationTokens - cacheWrite1hTokens)
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
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            cacheWrite1hTokens: lhs.cacheWrite1hTokens + rhs.cacheWrite1hTokens
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

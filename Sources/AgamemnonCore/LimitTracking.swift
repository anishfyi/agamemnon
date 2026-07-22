import Foundation

/// A limit the CLI actually reported hitting.
///
/// Claude Code writes these into its own transcripts as synthetic assistant lines
/// carrying `isApiErrorMessage: true` and `error: "rate_limit"`. The message text is the
/// only carrier: there is no numeric quota field and no epoch reset field anywhere on
/// disk, so the reset clock time is parsed out of the sentence.
public struct LimitHit: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case session
        case weekly
        /// A per-model cap, e.g. the Fable 5 credit limit, which is separate from the
        /// plan's session and weekly windows.
        case model
        /// Server-side throttling, explicitly not the user's quota.
        case serverThrottle

        public var displayName: String {
            switch self {
            case .session: return "Session limit"
            case .weekly: return "Weekly limit"
            case .model: return "Model limit"
            case .serverThrottle: return "Server throttling"
            }
        }
    }

    public var id: String
    public var kind: Kind
    public var source: TokenSource
    /// When the CLI reported the limit.
    public var hitAt: Date
    /// When the CLI said the limit resets. Nil when the message carried no reset time.
    public var resetAt: Date?
    /// The model named in a `.model` limit, empty otherwise.
    public var model: String
    public var rawText: String

    public init(
        id: String,
        kind: Kind,
        source: TokenSource,
        hitAt: Date,
        resetAt: Date?,
        model: String = "",
        rawText: String
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.hitAt = hitAt
        self.resetAt = resetAt
        self.model = model
        self.rawText = rawText
    }

    public var isActive: Bool {
        guard let resetAt else { return false }
        return resetAt > Date()
    }
}

public enum LimitLogParser {
    private static let resetRegex = try? NSRegularExpression(
        pattern: #"You've (?:hit|reached) your (session|weekly) limit\s*[·\-]\s*resets\s+(\d{1,2}):(\d{2})\s*(am|pm)\s*\(([^)]+)\)"#,
        options: .caseInsensitive
    )

    private static let modelLimitRegex = try? NSRegularExpression(
        pattern: #"You've reached your ([A-Za-z0-9.\- ]+?) limit\."#,
        options: .caseInsensitive
    )

    /// Parse one transcript line. Returns nil for anything that is not a limit report.
    public static func parseLine(_ line: String, source: TokenSource) -> LimitHit? {
        guard line.contains("limit") else { return nil }
        guard let obj = JSONLReader.parseJSONObject(line) else { return nil }
        guard (obj["isApiErrorMessage"] as? Bool) == true else { return nil }

        let errorKind = (obj["error"] as? String) ?? ""
        guard errorKind == "rate_limit" else { return nil }

        guard let message = obj["message"] as? [String: Any],
              let text = firstText(in: message) else { return nil }

        let hitAt = JSONLReader.parseDate(obj["timestamp"]) ?? Date()
        let uuid = (obj["uuid"] as? String) ?? UUID().uuidString

        if text.contains("not your usage limit") {
            return LimitHit(
                id: "\(source.rawValue)-throttle-\(uuid)",
                kind: .serverThrottle,
                source: source,
                hitAt: hitAt,
                resetAt: nil,
                rawText: text
            )
        }

        if let hit = parseWindowLimit(text: text, hitAt: hitAt, source: source) {
            return hit
        }

        if let regex = modelLimitRegex {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let m = regex.firstMatch(in: text, range: range),
               let r = Range(m.range(at: 1), in: text) {
                let model = String(text[r]).trimmingCharacters(in: .whitespaces)
                return LimitHit(
                    id: "\(source.rawValue)-model-\(model.lowercased())-\(dayKey(hitAt))",
                    kind: .model,
                    source: source,
                    hitAt: hitAt,
                    resetAt: nil,
                    model: model,
                    rawText: text
                )
            }
        }
        return nil
    }

    private static func parseWindowLimit(text: String, hitAt: Date, source: TokenSource) -> LimitHit? {
        guard let regex = resetRegex else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = regex.firstMatch(in: text, range: range) else { return nil }

        func group(_ i: Int) -> String {
            guard let r = Range(m.range(at: i), in: text) else { return "" }
            return String(text[r])
        }

        let kind: LimitHit.Kind = group(1).lowercased() == "weekly" ? .weekly : .session
        guard var hour = Int(group(2)), let minute = Int(group(3)) else { return nil }
        let meridiem = group(4).lowercased()
        let zoneName = group(5)

        if meridiem == "pm" && hour != 12 { hour += 12 }
        if meridiem == "am" && hour == 12 { hour = 0 }

        let zone = TimeZone(identifier: zoneName) ?? TimeZone(abbreviation: zoneName) ?? .current
        guard let resetAt = nextOccurrence(hour: hour, minute: minute, after: hitAt, in: zone) else {
            return nil
        }

        // Claude Code repeats the same limit message on every retry, so the transcript
        // holds hundreds of copies of one event. Keying on the reset instant collapses
        // them into the single limit hit they represent.
        return LimitHit(
            id: "\(source.rawValue)-\(kind.rawValue)-\(Int(resetAt.timeIntervalSince1970))",
            kind: kind,
            source: source,
            hitAt: hitAt,
            resetAt: resetAt,
            rawText: text
        )
    }

    /// The first datetime at `hour:minute` in `zone` that is at or after `date`.
    static func nextOccurrence(hour: Int, minute: Int, after date: Date, in zone: TimeZone) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        var comps = cal.dateComponents([.year, .month, .day], from: date)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        guard let sameDay = cal.date(from: comps) else { return nil }
        if sameDay >= date { return sameDay }
        return cal.date(byAdding: .day, value: 1, to: sameDay)
    }

    private static func firstText(in message: [String: Any]) -> String? {
        if let s = message["content"] as? String { return s }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        for block in blocks {
            if let t = block["text"] as? String, !t.isEmpty { return t }
        }
        return nil
    }

    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f.string(from: date)
    }
}

/// The subscription tier a CLI is running under, and the window shape that implies.
public enum PlanTier: String, Codable, Sendable, CaseIterable {
    case claudeMax20x
    case claudeMax5x
    case claudePro
    case claudeTeam
    case payAsYouGo
    case unknown

    public var displayName: String {
        switch self {
        case .claudeMax20x: return "Claude Max 20x"
        case .claudeMax5x: return "Claude Max 5x"
        case .claudePro: return "Claude Pro"
        case .claudeTeam: return "Claude Team"
        case .payAsYouGo: return "API / pay-as-you-go"
        case .unknown: return "Unknown plan"
        }
    }

    /// Length of the rolling usage session. Claude subscriptions use a 5-hour block
    /// that starts at the first message and resets at a fixed clock time.
    public var sessionWindow: TimeInterval { 5 * 3600 }

    public var weeklyWindow: TimeInterval { 7 * 24 * 3600 }

    /// Whether a session and weekly cap apply at all.
    public var hasWindowLimits: Bool {
        switch self {
        case .payAsYouGo, .unknown: return false
        default: return true
        }
    }

    /// Seed limits in input-token-equivalents, used only until a real limit hit is
    /// observed. Anthropic does not publish these as token counts, so the Max 5x figures
    /// are the median consumption measured across 13 real session-limit blocks and one
    /// weekly block on this machine; the other tiers scale from there by their nominal
    /// multiplier. They are surfaced in the UI as `estimated`, never as fact.
    public var seedSessionLimit: Double {
        switch self {
        case .claudeMax20x: return 43_000_000
        case .claudeMax5x: return 10_800_000
        case .claudeTeam: return 10_800_000
        case .claudePro: return 2_200_000
        case .payAsYouGo, .unknown: return 0
        }
    }

    public var seedWeeklyLimit: Double {
        switch self {
        case .claudeMax20x: return 870_000_000
        case .claudeMax5x: return 218_000_000
        case .claudeTeam: return 218_000_000
        case .claudePro: return 44_000_000
        case .payAsYouGo, .unknown: return 0
        }
    }
}

/// Reads the plan out of the CLI's own config rather than making the user pick it.
public enum PlanDetector {
    /// Claude Code stores the tier at `.oauthAccount.organizationRateLimitTier` in the
    /// `.claude.json` that sits inside its config root.
    public static func detectClaudePlan(configRoot: String) -> PlanTier {
        let candidates = [
            (configRoot as NSString).appendingPathComponent(".claude.json"),
            // The default root keeps its config next to the home directory instead.
            ((configRoot as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent(".claude.json"),
        ]
        for path in candidates {
            guard let data = FileManager.default.contents(atPath: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let account = obj["oauthAccount"] as? [String: Any] else { continue }

            let tier = ((account["userRateLimitTier"] as? String)
                ?? (account["organizationRateLimitTier"] as? String) ?? "").lowercased()
            let orgType = ((account["organizationType"] as? String) ?? "").lowercased()

            if tier.contains("max_20x") { return .claudeMax20x }
            if tier.contains("max_5x") { return .claudeMax5x }
            if tier.contains("team") || orgType.contains("team") { return .claudeTeam }
            if orgType.contains("max") { return .claudeMax5x }
            if orgType.contains("pro") || tier.contains("claude_ai") { return .claudePro }
            if !tier.isEmpty || !orgType.isEmpty { return .unknown }
        }
        return .unknown
    }

    /// Maps a Claude config root onto its token source.
    public static func configRoot(for source: TokenSource, paths: SourcePaths) -> String? {
        switch source {
        case .claudeWork: return (paths.claudeWorkProjects as NSString).deletingLastPathComponent
        case .claude: return (paths.claudeProjects as NSString).deletingLastPathComponent
        case .claudePersonal: return (paths.claudePersonalProjects as NSString).deletingLastPathComponent
        default: return nil
        }
    }
}

/// One-time recovery of limit history from transcripts already read past.
///
/// Usage events are ingested incrementally from a stored byte offset, so on an existing
/// install every transcript is already at EOF and a newly added parser sees nothing but
/// future lines. Limit hits are rare and historical: without a backfill the calibrator
/// would start from a single sample and take weeks to converge. This walks the archive
/// once, extracting only limit reports.
public enum LimitBackfill {
    /// Scans in fixed-size chunks rather than reading whole files. Transcripts reach
    /// hundreds of megabytes, and the previous whole-file read would spike memory for
    /// what is a rare-line grep.
    public static func scan(path: String, source: TokenSource) -> [LimitHit] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }

        var hits: [LimitHit] = []
        var seen = Set<String>()
        var carry = Data()
        let chunkSize = 1 << 20

        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            carry.append(chunk)
            while let nl = carry.firstIndex(of: 0x0A) {
                let lineData = carry[carry.startIndex..<nl]
                carry = carry[carry.index(after: nl)...]
                // Cheap byte-level prefilter: JSON-decoding all 40k+ lines per file just
                // to find a handful of limit reports would dominate the scan.
                guard lineData.count > 2,
                      let line = String(data: lineData, encoding: .utf8),
                      line.contains("rate_limit") else { continue }
                if let hit = LimitLogParser.parseLine(line, source: source), seen.insert(hit.id).inserted {
                    hits.append(hit)
                }
            }
            // Guard against a pathological line with no newline growing without bound.
            if carry.count > 8 << 20 { carry.removeAll(keepingCapacity: false) }
        }
        if let line = String(data: carry, encoding: .utf8), line.contains("rate_limit"),
           let hit = LimitLogParser.parseLine(line, source: source), seen.insert(hit.id).inserted {
            hits.append(hit)
        }
        return hits
    }
}

/// Turns observed limit hits into empirical limits.
///
/// When the CLI reports hitting the session limit at reset time R, the block that just
/// filled up is `[R - 5h, R]`. Summing billable tokens over that block gives a lower
/// bound on the real limit. Taking the maximum across observed hits converges on it.
public struct LimitCalibrator: Sendable {
    public struct Result: Sendable {
        public var limit: Double
        public var origin: LimitOrigin
        public var sampleCount: Int
    }

    public static func calibrate(
        hits: [LimitHit],
        kind: LimitHit.Kind,
        window: TimeInterval,
        seed: Double,
        billableIn: (Date, Date) -> Double
    ) -> Result {
        let relevant = hits.filter { $0.kind == kind && $0.resetAt != nil }
        var samples: [Double] = []
        for hit in relevant {
            guard let reset = hit.resetAt else { continue }
            let start = reset.addingTimeInterval(-window)
            let consumed = billableIn(start, min(reset, Date()))
            // A block we only partially observed, because the app was not yet
            // collecting data, would drag the estimate down. Ignore anything that
            // landed implausibly low against what we already believe the limit is.
            if consumed > seed * 0.25 {
                samples.append(consumed)
            }
        }
        guard !samples.isEmpty else {
            return Result(limit: seed, origin: seed > 0 ? .planEstimate : .none, sampleCount: 0)
        }
        // Median, not maximum. Measured blocks vary by roughly 3x because this app's
        // billable weighting only approximates the provider's internal accounting, and
        // an occasional block is contaminated by a misattributed boundary. Taking the
        // maximum would latch onto the worst outlier and permanently understate how
        // full the window is; the median is the robust central estimate.
        samples.sort()
        let median = samples.count % 2 == 1
            ? samples[samples.count / 2]
            : (samples[samples.count / 2 - 1] + samples[samples.count / 2]) / 2
        return Result(limit: median, origin: .measured, sampleCount: samples.count)
    }
}

import Foundation

public struct Suggestion: Sendable, Identifiable, Equatable {
    public enum Severity: Int, Sendable, Comparable {
        case info = 0
        case moderate = 1
        case high = 2

        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

        public var label: String {
            switch self {
            case .info: return "info"
            case .moderate: return "worth fixing"
            case .high: return "costing real money"
            }
        }
    }

    public var id: String
    public var title: String
    /// What was observed, with the numbers it was derived from.
    public var finding: String
    /// What to do.
    public var action: String
    /// Estimated USD per week that the fix would avoid. Zero when not quantifiable.
    public var weeklySaving: Double
    public var severity: Severity
    /// Id into `KnowledgeBase`, explaining the mechanism behind the finding.
    public var mechanism: String?
    public var source: TokenSource?

    public init(
        id: String,
        title: String,
        finding: String,
        action: String,
        weeklySaving: Double = 0,
        severity: Severity = .info,
        mechanism: String? = nil,
        source: TokenSource? = nil
    ) {
        self.id = id
        self.title = title
        self.finding = finding
        self.action = action
        self.weeklySaving = weeklySaving
        self.severity = severity
        self.mechanism = mechanism
        self.source = source
    }
}

/// Deterministic, local-only analysis over the collected usage history.
///
/// No network access and no model calls: every finding is arithmetic over the SQLite
/// cache, so the app's privacy claim holds and the same input always yields the same
/// advice.
public enum SuggestionEngine {
    public static func analyze(
        db: AgamemnonDatabase,
        settings: AppSettings,
        snapshot: MonitorSnapshot,
        now: Date = Date()
    ) -> [Suggestion] {
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        let sessions = db.sessions(limit: 500).filter { $0.endTime >= weekAgo }
        var out: [Suggestion] = []

        out.append(contentsOf: cacheThrash(sessions: sessions, settings: settings))
        out.append(contentsOf: cacheTTLWaste(sessions: sessions, settings: settings))
        out.append(contentsOf: modelMix(db: db, settings: settings, since: weekAgo, now: now))
        out.append(contentsOf: longSessions(sessions: sessions, settings: settings))
        out.append(contentsOf: limitPacing(snapshot: snapshot, now: now))
        out.append(contentsOf: expensiveProjects(sessions: sessions, settings: settings))
        out.append(contentsOf: windowHeadroom(snapshot: snapshot))

        return out.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            return $0.weeklySaving > $1.weeklySaving
        }
    }

    // MARK: - Rules

    /// A session that keeps re-reading a small cache, or none at all, is paying full
    /// input price for context it already sent.
    private static func cacheThrash(sessions: [SessionSummary], settings: AppSettings) -> [Suggestion] {
        let candidates = sessions.filter {
            $0.usage.totalInput > 200_000 && $0.messageCount >= 10
        }
        guard !candidates.isEmpty else { return [] }

        let thrashing = candidates.filter {
            Double($0.usage.cacheReadTokens) / Double(max(1, $0.usage.totalInput)) < 0.5
        }
        guard thrashing.count >= 2 else { return [] }

        // What those sessions would have cost had the re-sent context been cached.
        var wasted = 0.0
        for s in thrashing {
            let price = settings.price(for: s.model)
            let cacheable = Double(s.usage.inputTokens)
            let atFullRate = cacheable * price.inputPerMillion / 1_000_000
            let atCacheRate = atFullRate * price.cacheReadMultiplier
            wasted += atFullRate - atCacheRate
        }
        guard wasted > 0.05 else { return [] }

        let worst = thrashing.max { a, b in a.usage.inputTokens < b.usage.inputTokens }
        let ratio = worst.map {
            Int(100 * Double($0.usage.cacheReadTokens) / Double(max(1, $0.usage.totalInput)))
        } ?? 0

        return [Suggestion(
            id: "cache-thrash",
            title: "Prompt cache is missing on long sessions",
            finding: """
            \(thrashing.count) sessions in the last week sent over 200K input tokens with \
            under half of it served from cache. The worst was \(worst?.project ?? "unknown") \
            at \(ratio)% cache hits across \(worst?.messageCount ?? 0) messages.
            """,
            action: """
            Something in the prompt prefix is changing between turns. Check for a timestamp, \
            a per-run id, or a tool list that varies. Keeping the prefix byte-stable would \
            have moved those tokens from the full input rate to a tenth of it.
            """,
            weeklySaving: wasted,
            severity: wasted > 2 ? .high : .moderate,
            mechanism: "cache-prefix",
            source: worst?.source
        )]
    }

    /// The 1-hour cache costs 2x to write against the 5-minute cache's 1.25x. It only
    /// pays back across idle gaps longer than five minutes.
    private static func cacheTTLWaste(sessions: [SessionSummary], settings: AppSettings) -> [Suggestion] {
        let withLongTTL = sessions.filter { $0.usage.cacheWrite1hTokens > 50_000 }
        guard !withLongTTL.isEmpty else { return [] }

        // A dense session, many messages over a short span, never idles long enough for
        // the 1-hour TTL to earn its premium.
        let dense = withLongTTL.filter {
            $0.messageCount >= 20 && $0.duration > 0 && $0.duration / Double($0.messageCount) < 300
        }
        guard dense.count >= 2 else { return [] }

        var premium = 0.0
        for s in dense {
            let price = settings.price(for: s.model)
            let perToken = price.inputPerMillion / 1_000_000
            let asOneHour = Double(s.usage.cacheWrite1hTokens) * perToken * price.cacheWrite1hMultiplier
            let asFiveMin = Double(s.usage.cacheWrite1hTokens) * perToken * price.cacheWrite5mMultiplier
            premium += asOneHour - asFiveMin
        }
        guard premium > 0.05 else { return [] }

        return [Suggestion(
            id: "cache-ttl",
            title: "Paying the 1-hour cache premium on sessions that never idle",
            finding: """
            \(dense.count) dense sessions wrote to the 1-hour cache while averaging under \
            five minutes between messages. The 1-hour TTL bills writes at 2x versus 1.25x \
            for the 5-minute cache, and the extra durability was never used.
            """,
            action: """
            Use the 5-minute TTL for continuous work and reserve the 1-hour TTL for flows \
            with real gaps between requests, such as a bot that answers sporadically.
            """,
            weeklySaving: premium,
            severity: premium > 1 ? .moderate : .info,
            mechanism: "cache-economics",
            source: dense.first?.source
        )]
    }

    /// Work that produces very little output does not need the most expensive model.
    private static func modelMix(
        db: AgamemnonDatabase,
        settings: AppSettings,
        since: Date,
        now: Date
    ) -> [Suggestion] {
        let byModel = db.usageByModel(from: since, to: now)
        guard byModel.count >= 1 else { return [] }

        var findings: [Suggestion] = []
        for (model, usage) in byModel {
            let price = settings.price(for: model)
            // Only worth flagging on a genuinely premium model.
            guard price.inputPerMillion >= 5.0, usage.totalInput > 5_000_000 else { continue }
            let outputRatio = Double(usage.outputTokens) / Double(max(1, usage.totalInput))
            guard outputRatio < 0.01 else { continue }

            let currentCost = price.estimateCost(usage: usage)
            let cheaper = settings.price(for: "claude-haiku-4-5")
            let cheaperCost = cheaper.estimateCost(usage: usage)
            let saving = currentCost - cheaperCost
            guard saving > 0.5 else { continue }

            findings.append(Suggestion(
                id: "model-mix-\(model)",
                title: "Premium model doing low-output work",
                finding: """
                \(model) consumed \(TokenFormat.compact(usage.totalInput)) input tokens this \
                week but produced only \(TokenFormat.compact(usage.outputTokens)) output, a \
                ratio under 1%. That shape is reading and searching, not generating.
                """,
                action: """
                Route the read-heavy portion, file search, grep, summarisation, to a cheaper \
                model or a subagent at low effort. Keep the premium model for the reasoning \
                and writing turns.
                """,
                weeklySaving: saving,
                severity: saving > 5 ? .high : .moderate,
                mechanism: "effort"
            ))
        }
        return findings
    }

    /// Cost per turn grows with history because the whole conversation is resent.
    private static func longSessions(sessions: [SessionSummary], settings: AppSettings) -> [Suggestion] {
        let long = sessions.filter { $0.messageCount >= 150 }
        guard long.count >= 1 else { return [] }

        let totalCost = long.reduce(0.0) { $0 + settings.estimateCost(usage: $1.usage, model: $1.model) }
        guard totalCost > 1.0 else { return [] }

        let worst = long.max { a, b in a.messageCount < b.messageCount }
        return [Suggestion(
            id: "long-sessions",
            title: "A few very long sessions dominate spend",
            finding: """
            \(long.count) sessions ran past 150 messages this week, costing \
            \(TokenFormat.currency(totalCost)) between them. The longest was \
            \(worst?.messageCount ?? 0) messages in \(worst?.project ?? "unknown"). Because \
            the full history is resent every turn, the last messages in a session cost far \
            more than the first.
            """,
            action: """
            Split unrelated work into fresh sessions rather than continuing one. Where a long \
            run is genuinely needed, enable compaction or context editing so completed tool \
            results stop being resent.
            """,
            weeklySaving: totalCost * 0.25,
            severity: totalCost > 10 ? .high : .moderate,
            mechanism: "context-growth",
            source: worst?.source
        )]
    }

    /// Repeatedly running into the session cap is a scheduling problem, not a usage one.
    private static func limitPacing(snapshot: MonitorSnapshot, now: Date) -> [Suggestion] {
        let recent = snapshot.limitHits.filter {
            $0.kind == .session && $0.hitAt > now.addingTimeInterval(-7 * 24 * 3600)
        }
        guard recent.count >= 2 else { return [] }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let hours = recent.compactMap { cal.dateComponents([.hour], from: $0.hitAt).hour }
        let histogram = Dictionary(grouping: hours, by: { $0 }).mapValues(\.count)
        let peak = histogram.max { $0.value < $1.value }

        var detail = "You hit the session cap \(recent.count) times in the last week."
        if let peak, peak.value >= 2 {
            detail += " Most often around \(peak.key):00."
        }

        return [Suggestion(
            id: "limit-pacing",
            title: "Hitting the session cap repeatedly",
            finding: """
            \(detail) A session block is a fixed five-hour window anchored to its first \
            message, so filling one early leaves the rest of the block unusable.
            """,
            action: """
            Check the reset time before starting a long run, and begin heavy work just after \
            a block turns over rather than near its end. Dropping effort for routine turns \
            stretches the same block considerably further.
            """,
            weeklySaving: 0,
            severity: recent.count >= 4 ? .high : .moderate,
            mechanism: "windows",
            source: recent.first?.source
        )]
    }

    private static func expensiveProjects(sessions: [SessionSummary], settings: AppSettings) -> [Suggestion] {
        var byProject: [String: Double] = [:]
        for s in sessions {
            byProject[s.project, default: 0] += settings.estimateCost(usage: s.usage, model: s.model)
        }
        let total = byProject.values.reduce(0, +)
        guard total > 1.0, let top = byProject.max(by: { $0.value < $1.value }) else { return [] }
        let share = top.value / total
        guard share > 0.5, byProject.count >= 3 else { return [] }

        return [Suggestion(
            id: "project-concentration",
            title: "One project accounts for most of the spend",
            finding: """
            \(top.key) cost \(TokenFormat.currency(top.value)) this week, \
            \(Int(share * 100))% of \(TokenFormat.currency(total)) across \(byProject.count) \
            projects.
            """,
            action: """
            Worth a look at that repo's setup: a large CLAUDE.md, a wide tool surface, or an \
            unstable prompt prefix all inflate every turn taken inside it.
            """,
            weeklySaving: 0,
            severity: .info,
            mechanism: "cache-prefix"
        )]
    }

    private static func windowHeadroom(snapshot: MonitorSnapshot) -> [Suggestion] {
        var out: [Suggestion] = []
        for stats in snapshot.sourceStats where stats.session.origin == .planEstimate && stats.session.limit > 0 {
            out.append(Suggestion(
                id: "uncalibrated-\(stats.source.rawValue)",
                title: "Window limits for \(stats.source.displayName) are still estimated",
                finding: """
                No limit-hit event has been observed for this source yet, so the session and \
                weekly bars are drawn against a plan-derived estimate rather than a measured \
                value. The percentages are indicative only.
                """,
                action: """
                The estimate replaces itself automatically the first time the CLI reports \
                hitting its cap. Until then, set an override in Settings if you know the real \
                figure.
                """,
                weeklySaving: 0,
                severity: .info,
                mechanism: "windows",
                source: stats.source
            ))
        }
        return out
    }
}

import Foundation

public struct MonitorSnapshot: Sendable {
    public var todayTotal: TokenUsage
    public var todayBySource: [TokenSource: TokenUsage]
    public var todayCost: Double
    public var weekCost: Double
    public var allTimeCost: Double
    /// Billable input-token-equivalents per minute over the last 15 minutes. The old
    /// build reported raw tokens per minute, which was ~95% cache reads and therefore
    /// tracked cache size rather than spend.
    public var burnPerMinute: Double
    public var activeAlerts: Int
    public var sessions: [SessionSummary]
    public var alerts: [AbuseAlert]
    public var limitHits: [LimitHit]
    public var allTime: TokenUsage
    public var week: TokenUsage
    public var sourceStats: [SourceSpendStats]
    public var cursorActivity: CursorActivity
    public var detectedPlans: [TokenSource: PlanTier]
    public var lastPoll: Date

    public static let empty = MonitorSnapshot(
        todayTotal: .zero,
        todayBySource: [:],
        todayCost: 0,
        weekCost: 0,
        allTimeCost: 0,
        burnPerMinute: 0,
        activeAlerts: 0,
        sessions: [],
        alerts: [],
        limitHits: [],
        allTime: .zero,
        week: .zero,
        sourceStats: [],
        cursorActivity: .empty,
        detectedPlans: [:],
        lastPoll: .distantPast
    )
}

public final class MonitorEngine: @unchecked Sendable {
    public let db: AgamemnonDatabase
    private let lock = NSLock()
    private let workQueue = DispatchQueue(label: "com.anishfyi.agamemnon.poll", qos: .utility)
    private var settings: AppSettings
    private var timer: Timer?
    private var isPolling = false
    private var lastAbuseCheck = Date.distantPast
    private var cachedClaudePaths: (fetched: Date, paths: [(TokenSource, String)])?
    private var cachedKimiPaths: (fetched: Date, paths: [String])?
    private var cachedCodexPaths: (fetched: Date, paths: [String])?
    private var cachedGeminiPaths: (fetched: Date, paths: [String])?
    private var cachedCopilotPaths: (fetched: Date, paths: [String])?
    private var cursorActivity: CursorActivity = .empty
    private var detectedPlans: [TokenSource: PlanTier] = [:]
    private var lastPlanDetection = Date.distantPast
    private let discoveryTTL: TimeInterval = 60
    private let planDetectionTTL: TimeInterval = 300
    private let abuseInterval: TimeInterval = 60
    public var onUpdate: ((MonitorSnapshot) -> Void)?
    public var onNewAlerts: (([AbuseAlert]) -> Void)?

    public init(db: AgamemnonDatabase, settings: AppSettings = SettingsStore.load()) {
        self.db = db
        self.settings = settings
    }

    public func currentSettings() -> AppSettings {
        lock.lock(); defer { lock.unlock() }
        return settings
    }

    public func updateSettings(_ new: AppSettings) {
        lock.lock()
        settings = new
        lock.unlock()
        SettingsStore.save(new)
        restartTimer()
    }

    public func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.poll()
            self?.restartTimer()
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func restartTimer() {
        timer?.invalidate()
        let interval = TimeInterval(max(5, currentSettings().pollIntervalSeconds))
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.poll()
            }
        }
    }

    public func poll() {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.isPolling {
                self.lock.unlock()
                return
            }
            self.isPolling = true
            self.lock.unlock()
            defer {
                self.lock.lock()
                self.isPolling = false
                self.lock.unlock()
            }

            let s = self.currentSettings()
            if !s.paused {
                self.pollSync(settings: s)
            }
            let snap = self.snapshot(settings: s)
            DispatchQueue.main.async {
                self.onUpdate?(snap)
            }
        }
    }

    // MARK: - Ingest

    /// Recovers limit history from transcripts that were already read past before limit
    /// parsing existed. Runs once, on the poll queue, and is keyed in `meta` so a
    /// restart does not repeat it.
    private func backfillLimitsIfNeeded(settings: AppSettings) {
        let key = "backfill.v1.limit-hits"
        guard !db.metaFlag(key) else { return }

        var total = 0
        for source in TokenSource.allCases where source.isClaudeFamily {
            guard settings.toggles.isEnabled(source, paths: settings.paths) else { continue }
            for path in ClaudeParser.discoverTranscripts(in: settings.paths.root(for: source)) {
                let hits = LimitBackfill.scan(path: path, source: source)
                if !hits.isEmpty {
                    total += db.insertLimitHits(hits)
                }
            }
        }
        db.setMetaFlag(key)
        if total > 0 {
            // Limits are recalculated from the hit history on the next snapshot.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onUpdate?(self.snapshot())
            }
        }
    }

    private func pollSync(settings: AppSettings) {
        let now = Date()
        detectPlansIfStale(settings: settings, now: now)
        backfillLimitsIfNeeded(settings: settings)

        let claudeSources: [TokenSource] = [.claudeWork, .claude, .claudePersonal]
        let enabledClaude = claudeSources.filter {
            settings.toggles.isEnabled($0, paths: settings.paths)
        }

        let claudePaths = cachedPaths(
            cache: &cachedClaudePaths,
            now: now,
            discover: {
                enabledClaude.flatMap { source -> [(TokenSource, String)] in
                    ClaudeParser.discoverTranscripts(in: settings.paths.root(for: source))
                        .map { (source, $0) }
                }
            }
        )
        for (source, path) in claudePaths {
            ingestClaude(path: path, source: source)
        }

        if settings.toggles.isEnabled(.kimi, paths: settings.paths) {
            let kimiPaths = cachedPaths(
                cache: &cachedKimiPaths,
                now: now,
                discover: { KimiParser.discoverWireLogs(in: settings.paths.root(for: .kimi)) }
            )
            for path in kimiPaths {
                ingestKimi(path: path)
            }
        }

        if settings.toggles.isEnabled(.cursor, paths: settings.paths) {
            // Cursor exposes no token counts on disk at all, so this reads the activity
            // stats it does keep instead of scanning chat blobs for fields that do not
            // exist. Crucially these are not written into usage_events, which would
            // otherwise pollute session counts with zero-token rows.
            let activity = CursorParser.parseActivity(trackingDB: settings.paths.root(for: .cursor))
            lock.lock()
            cursorActivity = activity
            lock.unlock()
        }

        if settings.toggles.isEnabled(.codex, paths: settings.paths) {
            let paths = cachedPaths(
                cache: &cachedCodexPaths,
                now: now,
                discover: { CodexParser.discoverRollouts(in: settings.paths.root(for: .codex)) }
            )
            for path in paths {
                let offset = db.fileState(path: path)?.offset ?? 0
                let (events, newOffset, size, mtime) = CodexParser.parseFile(path: path, offset: offset)
                _ = db.insertEvents(events)
                db.setFileState(path: path, offset: newOffset, mtime: mtime, size: size)
            }
        }

        if settings.toggles.isEnabled(.copilot, paths: settings.paths) {
            let paths = cachedPaths(
                cache: &cachedCopilotPaths,
                now: now,
                discover: { CopilotParser.discoverEventLogs(in: settings.paths.root(for: .copilot)) }
            )
            for path in paths {
                let offset = db.fileState(path: path)?.offset ?? 0
                let (events, newOffset, size, mtime) = CopilotParser.parseFile(path: path, offset: offset)
                _ = db.insertEvents(events)
                db.setFileState(path: path, offset: newOffset, mtime: mtime, size: size)
            }
        }

        // Gemini chats and the OpenCode/Crush databases are whole-file reads rather than
        // append-only logs, so there is no offset to resume from. Skipping unchanged
        // files keeps the poll cheap.
        if settings.toggles.isEnabled(.gemini, paths: settings.paths) {
            let paths = cachedPaths(
                cache: &cachedGeminiPaths,
                now: now,
                discover: { GeminiParser.discoverChats(in: settings.paths.root(for: .gemini)) }
            )
            for path in paths where hasChanged(path: path) {
                _ = db.insertEvents(GeminiParser.parseFile(path: path))
                markScanned(path: path)
            }
        }

        if settings.toggles.isEnabled(.opencode, paths: settings.paths) {
            let path = settings.paths.root(for: .opencode)
            if hasChanged(path: path) {
                _ = db.insertEvents(OpenCodeParser.parse(dbPath: path))
                markScanned(path: path)
            }
        }

        if settings.toggles.isEnabled(.crush, paths: settings.paths) {
            let path = settings.paths.root(for: .crush)
            if hasChanged(path: path) {
                _ = db.insertEvents(CrushParser.parse(dbPath: path))
                markScanned(path: path)
            }
        }

        if now.timeIntervalSince(lastAbuseCheck) >= abuseInterval {
            lastAbuseCheck = now
            let newAlerts = AbuseEngine.evaluate(db: db, thresholds: settings.thresholds)
            if !newAlerts.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.onNewAlerts?(newAlerts)
                }
            }
        }
    }

    private func detectPlansIfStale(settings: AppSettings, now: Date) {
        guard now.timeIntervalSince(lastPlanDetection) >= planDetectionTTL else { return }
        lastPlanDetection = now
        var plans: [TokenSource: PlanTier] = [:]
        for source in TokenSource.allCases where source.isClaudeFamily {
            if let override = settings.planOverrides[source.rawValue] {
                plans[source] = override
                continue
            }
            guard let root = PlanDetector.configRoot(for: source, paths: settings.paths) else { continue }
            plans[source] = PlanDetector.detectClaudePlan(configRoot: root)
        }
        lock.lock()
        detectedPlans = plans
        lock.unlock()
    }

    private func cachedPaths<T>(
        cache: inout (fetched: Date, paths: T)?,
        now: Date,
        discover: () -> T
    ) -> T {
        if let cached = cache, now.timeIntervalSince(cached.fetched) < discoveryTTL {
            return cached.paths
        }
        let paths = discover()
        cache = (now, paths)
        return paths
    }

    /// True when a whole-file source has been touched since it was last scanned.
    /// Sources without an append-only log are re-read in full, so this is what keeps a
    /// 5-second poll from repeatedly parsing an unchanged multi-megabyte database.
    private func hasChanged(path: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return false }
        guard let state = db.fileState(path: path) else { return true }
        return state.mtime != mtime || state.size != size
    }

    private func markScanned(path: String) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return }
        db.setFileState(path: path, offset: 0, mtime: mtime, size: size)
    }

    private func ingestClaude(path: String, source: TokenSource) {
        let offset = db.fileState(path: path)?.offset ?? 0
        let scan = ClaudeParser.parseFile(path: path, source: source, offset: offset)
        _ = db.insertEvents(scan.events)
        _ = db.insertLimitHits(scan.limits)
        db.setFileState(path: path, offset: scan.newOffset, mtime: scan.mtime, size: scan.size)
    }

    private func ingestKimi(path: String) {
        let offset = db.fileState(path: path)?.offset ?? 0
        let (events, newOffset, size, mtime) = KimiParser.parseFile(path: path, offset: offset)
        _ = db.insertEvents(events)
        db.setFileState(path: path, offset: newOffset, mtime: mtime, size: size)
    }

    // MARK: - Windows

    /// Start of the usage block currently in progress.
    ///
    /// A Claude session window is a fixed 5-hour block anchored to the first message
    /// after the previous block expired, not a window that slides with the clock. The
    /// old build measured `now - 5h`, which meant the bar drifted continuously and
    /// never lined up with the reset time the CLI actually reports.
    func sessionWindowStart(source: TokenSource, window: TimeInterval, now: Date) -> Date {
        // An unexpired limit hit is authoritative: the CLI told us exactly when this
        // block ends, so the block began one window earlier.
        let recentHits = db.limitHits(source: source, since: now.addingTimeInterval(-window * 2))
        if let active = recentHits.first(where: { $0.kind == .session && ($0.resetAt ?? .distantPast) > now }),
           let reset = active.resetAt {
            return reset.addingTimeInterval(-window)
        }

        // Otherwise walk blocks forward from the earliest activity in the last week.
        let searchFloor = now.addingTimeInterval(-7 * 24 * 3600)
        guard var blockStart = db.firstEventTimestamp(atOrAfter: searchFloor, source: source) else {
            return now
        }
        // Bounded by construction: each step advances at least one window, so a
        // seven-day search floor allows at most ~34 iterations for a 5-hour window.
        while blockStart.addingTimeInterval(window) <= now {
            let nextFloor = blockStart.addingTimeInterval(window)
            guard let next = db.firstEventTimestamp(atOrAfter: nextFloor, source: source) else {
                return nextFloor
            }
            blockStart = next
        }
        return blockStart
    }

    private func windowStats(
        source: TokenSource,
        start: Date,
        reset: Date?,
        now: Date,
        settings: AppSettings,
        limit: Double,
        origin: LimitOrigin
    ) -> WindowStats {
        let byModel = db.usageByModel(from: start, to: now, source: source)
        let usage = byModel.values.reduce(TokenUsage.zero, +)
        return WindowStats(
            start: start,
            reset: reset,
            usage: usage,
            billable: settings.billableTokens(byModel: byModel),
            cost: settings.estimateCost(byModel: byModel),
            limit: limit,
            origin: origin
        )
    }

    private func billable(from: Date, to: Date, source: TokenSource, settings: AppSettings) -> Double {
        settings.billableTokens(byModel: db.usageByModel(from: from, to: to, source: source))
    }

    // MARK: - Snapshot

    public func snapshot(settings: AppSettings? = nil) -> MonitorSnapshot {
        let s = settings ?? currentSettings()
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) ?? todayStart
        let last15 = now.addingTimeInterval(-15 * 60)

        lock.lock()
        let activity = cursorActivity
        let plans = detectedPlans
        lock.unlock()

        var bySource: [TokenSource: TokenUsage] = [:]
        for source in TokenSource.allCases {
            let usage = db.totalUsage(from: todayStart, to: now, source: source)
            if usage.totalTokens > 0 || source.tokensAreServerSideOnly {
                bySource[source] = usage
            }
        }

        let allLimitHits = db.limitHits(since: now.addingTimeInterval(-30 * 24 * 3600))
        var sourceStats: [SourceSpendStats] = []

        for source in TokenSource.dashboardOrder {
            guard s.toggles.isEnabled(source, paths: s.paths) else { continue }

            let plan = plans[source] ?? (source.hasSubscriptionWindows ? .unknown : .payAsYouGo)
            let sessionWindow = plan.sessionWindow
            let weeklyWindow = plan.weeklyWindow
            let hits = allLimitHits.filter { $0.source == source }
            let override = s.sourceLimits.limits(for: source)

            let sessionLimit: (limit: Double, origin: LimitOrigin)
            let weeklyLimit: (limit: Double, origin: LimitOrigin)

            if !plan.hasWindowLimits {
                sessionLimit = (0, .none)
                weeklyLimit = (0, .none)
            } else {
                if override.sessionBillable > 0 {
                    sessionLimit = (override.sessionBillable, .userSet)
                } else {
                    let c = LimitCalibrator.calibrate(
                        hits: hits, kind: .session, window: sessionWindow,
                        seed: plan.seedSessionLimit,
                        billableIn: { self.billable(from: $0, to: $1, source: source, settings: s) }
                    )
                    sessionLimit = (c.limit, c.origin)
                }
                if override.weeklyBillable > 0 {
                    weeklyLimit = (override.weeklyBillable, .userSet)
                } else {
                    let c = LimitCalibrator.calibrate(
                        hits: hits, kind: .weekly, window: weeklyWindow,
                        seed: plan.seedWeeklyLimit,
                        billableIn: { self.billable(from: $0, to: $1, source: source, settings: s) }
                    )
                    weeklyLimit = (c.limit, c.origin)
                }
            }

            let sessionStart = source.hasSubscriptionWindows
                ? sessionWindowStart(source: source, window: sessionWindow, now: now)
                : now.addingTimeInterval(-sessionWindow)
            let activeSessionHit = hits.first {
                $0.kind == .session && ($0.resetAt ?? .distantPast) > now
            }
            let activeWeeklyHit = hits.first {
                $0.kind == .weekly && ($0.resetAt ?? .distantPast) > now
            }

            let session = windowStats(
                source: source,
                start: sessionStart,
                reset: activeSessionHit?.resetAt ?? sessionStart.addingTimeInterval(sessionWindow),
                now: now, settings: s,
                limit: sessionLimit.limit, origin: sessionLimit.origin
            )
            let weekly = windowStats(
                source: source,
                start: now.addingTimeInterval(-weeklyWindow),
                reset: activeWeeklyHit?.resetAt,
                now: now, settings: s,
                limit: weeklyLimit.limit, origin: weeklyLimit.origin
            )

            let todayByModel = db.usageByModel(from: todayStart, to: now, source: source)
            let recentByModel = db.usageByModel(from: last15, to: now, source: source)
            let sourceBurn = s.billableTokens(byModel: recentByModel) / 15.0

            // An active limit hit means the source is blocked right now, which is the
            // one case where `critical` is a fact rather than a ratio.
            let activeHit = activeSessionHit ?? activeWeeklyHit
            let state: SpendState = activeHit != nil
                ? .critical
                : SpendState.from(ratio: max(session.ratio, weekly.ratio))

            sourceStats.append(SourceSpendStats(
                source: source,
                today: todayByModel.values.reduce(TokenUsage.zero, +),
                todayCost: s.estimateCost(byModel: todayByModel),
                session: session,
                weekly: weekly,
                burnPerMinute: sourceBurn,
                state: state,
                tokensUnavailable: source.tokensAreServerSideOnly,
                activityNote: source.tokensAreServerSideOnly ? CursorParser.unavailableNote : "",
                activeLimitHit: activeHit
            ))
        }

        let todayByModel = db.usageByModel(from: todayStart, to: now)
        let weekByModel = db.usageByModel(from: weekStart, to: now)
        let allByModel = db.usageByModel()
        let recentAll = db.usageByModel(from: last15, to: now)

        return MonitorSnapshot(
            todayTotal: todayByModel.values.reduce(TokenUsage.zero, +),
            todayBySource: bySource,
            todayCost: s.estimateCost(byModel: todayByModel),
            weekCost: s.estimateCost(byModel: weekByModel),
            allTimeCost: s.estimateCost(byModel: allByModel),
            burnPerMinute: s.billableTokens(byModel: recentAll) / 15.0,
            activeAlerts: db.activeAlertCount(),
            sessions: db.sessions(limit: 200),
            alerts: db.alerts(includeAcknowledged: true, limit: 200),
            limitHits: allLimitHits,
            allTime: allByModel.values.reduce(TokenUsage.zero, +),
            week: weekByModel.values.reduce(TokenUsage.zero, +),
            sourceStats: sourceStats,
            cursorActivity: activity,
            detectedPlans: plans,
            lastPoll: now
        )
    }

    public func togglePause() {
        var s = currentSettings()
        s.paused.toggle()
        updateSettings(s)
        poll()
    }

    public func acknowledge(alertId: String) {
        db.acknowledgeAlert(id: alertId)
        poll()
    }
}

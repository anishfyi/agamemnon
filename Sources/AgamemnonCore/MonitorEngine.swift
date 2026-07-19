import Foundation

public struct MonitorSnapshot: Sendable {
    public var todayTotal: TokenUsage
    public var todayBySource: [TokenSource: TokenUsage]
    public var fiveHour: TokenUsage
    public var sevenDay: TokenUsage
    public var burnPerMinute: Double
    public var activeAlerts: Int
    public var cursorNote: String
    public var sessions: [SessionSummary]
    public var alerts: [AbuseAlert]
    public var allTime: TokenUsage
    public var week: TokenUsage
    public var sourceStats: [SourceSpendStats]
    public var lastPoll: Date

    public static let empty = MonitorSnapshot(
        todayTotal: .zero,
        todayBySource: [:],
        fiveHour: .zero,
        sevenDay: .zero,
        burnPerMinute: 0,
        activeAlerts: 0,
        cursorNote: "",
        sessions: [],
        alerts: [],
        allTime: .zero,
        week: .zero,
        sourceStats: [],
        lastPoll: .distantPast
    )
}

public final class MonitorEngine: @unchecked Sendable {
    public let db: AgamemnonDatabase
    private let lock = NSLock()
    private let workQueue = DispatchQueue(label: "com.anishfyi.agamemnon.poll", qos: .utility)
    private var settings: AppSettings
    private var timer: Timer?
    private var cursorNote: String = ""
    private var isPolling = false
    private var lastAbuseCheck = Date.distantPast
    private var cachedClaudePaths: (fetched: Date, paths: [(TokenSource, String)])?
    private var cachedKimiPaths: (fetched: Date, paths: [String])?
    private var cachedCursorPaths: (fetched: Date, paths: [String])?
    private let discoveryTTL: TimeInterval = 60
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
        // Timer must run on main run loop for menu-bar app
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

    private func pollSync(settings: AppSettings) {
        let now = Date()
        let claudeRoots: [(TokenSource, String, Bool)] = [
            (.claudeWork, settings.paths.claudeWorkProjects, settings.toggles.claudeWork),
            (.claude, settings.paths.claudeProjects, settings.toggles.claude),
            (.claudePersonal, settings.paths.claudePersonalProjects, settings.toggles.claudePersonal),
        ]

        let claudePaths = cachedPaths(
            cache: &cachedClaudePaths,
            now: now,
            discover: {
                claudeRoots.flatMap { (source, root, enabled) -> [(TokenSource, String)] in
                    guard enabled else { return [] }
                    return ClaudeParser.discoverTranscripts(in: root).map { (source, $0) }
                }
            }
        )
        for (source, path) in claudePaths {
            ingestClaude(path: path, source: source)
        }

        if settings.toggles.kimi {
            let kimiPaths = cachedPaths(
                cache: &cachedKimiPaths,
                now: now,
                discover: { KimiParser.discoverWireLogs(in: settings.paths.kimiSessions) }
            )
            for path in kimiPaths {
                ingestKimi(path: path)
            }
        }

        if settings.toggles.cursor {
            ingestCursor(settings: settings, now: now)
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

    private func ingestCursor(settings: AppSettings, now: Date) {
        let dbPath = settings.paths.cursorTrackingDB
        if FileManager.default.fileExists(atPath: dbPath) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath)
            let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let state = db.fileState(path: dbPath)
            if state == nil || state!.mtime != mtime || state!.size != size {
                let activity = CursorParser.parseActivityDB(path: dbPath)
                _ = db.insertEvents(activity)
                db.setFileState(path: dbPath, offset: 0, mtime: mtime, size: size)
            }
        }

        var foundTokens = false
        let tokenPaths = cachedPaths(
            cache: &cachedCursorPaths,
            now: now,
            discover: {
                CursorParser.discoverTokenFiles(debugLogs: settings.paths.cursorDebugLogs)
                    + CursorParser.discoverTokenFiles(chats: settings.paths.cursorChats)
            }
        )
        for path in tokenPaths {
            let before = db.fileState(path: path)?.offset ?? 0
            ingestCursorTokenFile(path: path)
            let after = db.fileState(path: path)?.offset ?? 0
            if after > before { foundTokens = true }
        }

        lock.lock()
        if foundTokens {
            cursorNote = ""
        } else if cursorNote.isEmpty {
            cursorNote = "cursor: activity only, tokens unavailable"
        }
        lock.unlock()
    }

    private func ingestCursorTokenFile(path: String) {
        let state = db.fileState(path: path)
        let offset = state?.offset ?? 0
        let sessionId = "cursor-\(abs(path.hashValue))"
        let project = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        let (lines, newOffset, size, mtime) = JSONLReader.readNewLines(path: path, offset: offset)
        var events: [UsageEvent] = []
        for line in lines {
            if let event = CursorParser.parseTokenLine(line, sessionId: sessionId, project: project) {
                events.append(event)
            }
        }
        if lines.isEmpty, offset == 0,
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            events.append(contentsOf: CursorParser.extractFromJSONPublic(obj, sessionId: sessionId, project: project))
        }
        _ = db.insertEvents(events)
        db.setFileState(path: path, offset: newOffset, mtime: mtime, size: size)
    }

    private func ingestClaude(path: String, source: TokenSource) {
        let state = db.fileState(path: path)
        let offset = state?.offset ?? 0
        let (events, newOffset, size, mtime) = ClaudeParser.parseFile(path: path, source: source, offset: offset)
        _ = db.insertEvents(events)
        db.setFileState(path: path, offset: newOffset, mtime: mtime, size: size)
    }

    private func ingestKimi(path: String) {
        let state = db.fileState(path: path)
        let offset = state?.offset ?? 0
        let (events, newOffset, size, mtime) = KimiParser.parseFile(path: path, offset: offset)
        _ = db.insertEvents(events)
        db.setFileState(path: path, offset: newOffset, mtime: mtime, size: size)
    }

    public func snapshot(settings: AppSettings? = nil) -> MonitorSnapshot {
        let s = settings ?? currentSettings()
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        let fiveHourStart = now.addingTimeInterval(-5 * 3600)
        let sevenDayStart = now.addingTimeInterval(-7 * 24 * 3600)
        let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) ?? todayStart
        let last15 = now.addingTimeInterval(-15 * 60)

        var bySource: [TokenSource: TokenUsage] = [:]
        for source in TokenSource.allCases {
            bySource[source] = db.totalUsage(from: todayStart, to: now, source: source)
        }
        let today = db.totalUsage(from: todayStart, to: now)
        let recent = db.totalUsage(from: last15, to: now)
        let burn = Double(recent.totalTokens) / 15.0

        lock.lock()
        let note = cursorNote
        lock.unlock()

        var sourceStats: [SourceSpendStats] = []
        for dashSource in DashboardSource.allCases {
            let tokenSource = dashSource.tokenSource
            guard s.toggles.isEnabled(tokenSource) else { continue }

            let todayUsage = bySource[tokenSource] ?? .zero
            let fiveHourUsage = db.totalUsage(from: fiveHourStart, to: now, source: tokenSource)
            let sevenDayUsage = db.totalUsage(from: sevenDayStart, to: now, source: tokenSource)
            let recentSource = db.totalUsage(from: last15, to: now, source: tokenSource)
            let sourceBurn = Double(recentSource.totalTokens) / 15.0

            let limits = s.sourceLimits.limits(for: dashSource)
            let fiveHourRatio = limits.fiveHourTokens > 0
                ? Double(fiveHourUsage.totalTokens) / Double(limits.fiveHourTokens) : 0
            let weeklyRatio = limits.weeklyTokens > 0
                ? Double(sevenDayUsage.totalTokens) / Double(limits.weeklyTokens) : 0
            let worstRatio = max(fiveHourRatio, weeklyRatio)
            let state = SpendState.from(ratio: worstRatio)

            let fiveHourOldest = db.oldestEventTimestamp(from: fiveHourStart, to: now, source: tokenSource)
            let weeklyOldest = db.oldestEventTimestamp(from: sevenDayStart, to: now, source: tokenSource)
            let fiveHourReset = fiveHourOldest.map { $0.addingTimeInterval(5 * 3600) }
            let weeklyReset = weeklyOldest.map { $0.addingTimeInterval(7 * 24 * 3600) }

            let tokensUnavailable = dashSource == .cursor
                && todayUsage.totalTokens == 0
                && fiveHourUsage.totalTokens == 0
                && !note.isEmpty

            sourceStats.append(SourceSpendStats(
                source: dashSource,
                today: todayUsage,
                fiveHour: fiveHourUsage,
                sevenDay: sevenDayUsage,
                burnPerMinute: sourceBurn,
                estimatedCost: s.estimateCost(usage: todayUsage),
                fiveHourReset: fiveHourReset,
                weeklyReset: weeklyReset,
                fiveHourRatio: fiveHourRatio,
                weeklyRatio: weeklyRatio,
                state: state,
                tokensUnavailable: tokensUnavailable,
                activityNote: dashSource == .cursor ? note : ""
            ))
        }

        return MonitorSnapshot(
            todayTotal: today,
            todayBySource: bySource,
            fiveHour: db.totalUsage(from: fiveHourStart, to: now),
            sevenDay: db.totalUsage(from: sevenDayStart, to: now),
            burnPerMinute: burn,
            activeAlerts: db.activeAlertCount(),
            cursorNote: note,
            sessions: db.sessions(limit: 200),
            alerts: db.alerts(includeAcknowledged: true, limit: 200),
            allTime: db.totalUsage(),
            week: db.totalUsage(from: weekStart, to: now),
            sourceStats: sourceStats,
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

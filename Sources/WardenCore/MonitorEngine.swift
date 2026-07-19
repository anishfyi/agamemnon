import Foundation

public struct MonitorSnapshot: Sendable {
    public var todayTotal: TokenUsage
    public var todayBySource: [TokenSource: TokenUsage]
    public var fiveHour: TokenUsage
    public var sevenDay: TokenUsage
    public var burnPerMinute: Double
    public var activeAlerts: Int
    public var cursorNote: String
    public var hourly: [HourlyBucket]
    public var daily: [DailyBucket]
    public var sessions: [SessionSummary]
    public var alerts: [AbuseAlert]
    public var allTime: TokenUsage
    public var week: TokenUsage
    public var lastPoll: Date

    public static let empty = MonitorSnapshot(
        todayTotal: .zero,
        todayBySource: [:],
        fiveHour: .zero,
        sevenDay: .zero,
        burnPerMinute: 0,
        activeAlerts: 0,
        cursorNote: "",
        hourly: [],
        daily: [],
        sessions: [],
        alerts: [],
        allTime: .zero,
        week: .zero,
        lastPoll: .distantPast
    )
}

public final class MonitorEngine: @unchecked Sendable {
    public let db: WardenDatabase
    private let lock = NSLock()
    private var settings: AppSettings
    private var timer: Timer?
    private var cursorNote: String = ""
    public var onUpdate: ((MonitorSnapshot) -> Void)?
    public var onNewAlerts: (([AbuseAlert]) -> Void)?

    public init(db: WardenDatabase, settings: AppSettings = SettingsStore.load()) {
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
        poll()
        restartTimer()
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
        let s = currentSettings()
        guard !s.paused else {
            publish()
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.pollSync(settings: s)
            DispatchQueue.main.async {
                self?.publish()
            }
        }
    }

    private func pollSync(settings: AppSettings) {
        // Claude family
        let claudeRoots: [(TokenSource, String, Bool)] = [
            (.claudeWork, settings.paths.claudeWorkProjects, settings.toggles.claudeWork),
            (.claude, settings.paths.claudeProjects, settings.toggles.claude),
            (.claudePersonal, settings.paths.claudePersonalProjects, settings.toggles.claudePersonal),
        ]
        for (source, root, enabled) in claudeRoots where enabled {
            for path in ClaudeParser.discoverTranscripts(in: root) {
                ingestClaude(path: path, source: source)
            }
        }

        if settings.toggles.kimi {
            for path in KimiParser.discoverWireLogs(in: settings.paths.kimiSessions) {
                ingestKimi(path: path)
            }
        }

        // Cursor never blocks others; run last and swallow errors
        if settings.toggles.cursor {
            let result = CursorParser.parse(
                trackingDB: settings.paths.cursorTrackingDB,
                debugLogs: settings.paths.cursorDebugLogs,
                chats: settings.paths.cursorChats
            )
            lock.lock()
            cursorNote = result.note.isEmpty ? cursorNote : result.note
            if result.activityOnly {
                cursorNote = result.note
            }
            lock.unlock()
            _ = db.insertEvents(result.events)
        }

        let newAlerts = AbuseEngine.evaluate(db: db, thresholds: settings.thresholds)
        if !newAlerts.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.onNewAlerts?(newAlerts)
            }
        }
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

    public func snapshot() -> MonitorSnapshot {
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        let fiveHour = now.addingTimeInterval(-5 * 3600)
        let sevenDay = now.addingTimeInterval(-7 * 24 * 3600)
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

        return MonitorSnapshot(
            todayTotal: today,
            todayBySource: bySource,
            fiveHour: db.totalUsage(from: fiveHour, to: now),
            sevenDay: db.totalUsage(from: sevenDay, to: now),
            burnPerMinute: burn,
            activeAlerts: db.activeAlertCount(),
            cursorNote: note,
            hourly: db.hourlyBuckets(lastHours: 24),
            daily: db.dailyBuckets(lastDays: 30),
            sessions: db.sessions(limit: 200),
            alerts: db.alerts(includeAcknowledged: true, limit: 200),
            allTime: db.totalUsage(),
            week: db.totalUsage(from: weekStart, to: now),
            lastPoll: now
        )
    }

    private func publish() {
        let snap = snapshot()
        onUpdate?(snap)
    }

    public func togglePause() {
        var s = currentSettings()
        s.paused.toggle()
        updateSettings(s)
        publish()
    }

    public func acknowledge(alertId: String) {
        db.acknowledgeAlert(id: alertId)
        publish()
    }
}

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class AgamemnonDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    public let path: String

    public init(path: String? = nil) throws {
        if let path {
            self.path = path
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = base.appendingPathComponent("Agamemnon", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            Self.migrateLegacyDatabaseIfNeeded(into: dir)
            self.path = dir.appendingPathComponent("agamemnon.db").path
        }
        try open()
        try migrate()
    }

    private static func migrateLegacyDatabaseIfNeeded(into agamemnonDir: URL) {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let wardenDir = base.appendingPathComponent("Warden", isDirectory: true)
        let legacyDB = wardenDir.appendingPathComponent("warden.db")
        let newDB = agamemnonDir.appendingPathComponent("agamemnon.db")
        guard fm.fileExists(atPath: legacyDB.path), !fm.fileExists(atPath: newDB.path) else { return }
        try? fm.copyItem(at: legacyDB, to: newDB)
    }

    deinit {
        if db != nil { sqlite3_close(db) }
    }

    private func open() throws {
        if sqlite3_open(path, &db) != SQLITE_OK {
            throw DBError.openFailed(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil)
    }

    private func migrate() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS usage_events (
            id TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            session_id TEXT NOT NULL,
            project TEXT NOT NULL,
            model TEXT NOT NULL,
            timestamp REAL NOT NULL,
            input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            cache_creation INTEGER NOT NULL,
            cache_read INTEGER NOT NULL,
            message_id TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_events_ts ON usage_events(timestamp);
        CREATE INDEX IF NOT EXISTS idx_events_source ON usage_events(source);
        CREATE INDEX IF NOT EXISTS idx_events_session ON usage_events(session_id);
        CREATE INDEX IF NOT EXISTS idx_events_message ON usage_events(message_id);

        CREATE TABLE IF NOT EXISTS file_offsets (
            path TEXT PRIMARY KEY,
            offset INTEGER NOT NULL,
            mtime REAL NOT NULL,
            size INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS alerts (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            source TEXT NOT NULL,
            session_id TEXT,
            message TEXT NOT NULL,
            fired_at REAL NOT NULL,
            acknowledged INTEGER NOT NULL,
            value REAL NOT NULL,
            threshold REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_alerts_ack ON alerts(acknowledged);

        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """
        try exec(sql)
    }

    public enum DBError: Error, CustomStringConvertible {
        case openFailed(String)
        case execFailed(String)

        public var description: String {
            switch self {
            case .openFailed(let s): return "open failed: \(s)"
            case .execFailed(let s): return "exec failed: \(s)"
            }
        }
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DBError.execFailed(msg)
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: - File offsets

    public struct FileState: Sendable {
        public var offset: Int64
        public var mtime: Date
        public var size: Int64
    }

    public func fileState(path: String) -> FileState? {
        withLock {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT offset, mtime, size FROM file_offsets WHERE path = ?", -1, &stmt, nil) == SQLITE_OK else {
                return nil
            }
            sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return FileState(
                offset: sqlite3_column_int64(stmt, 0),
                mtime: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                size: sqlite3_column_int64(stmt, 2)
            )
        }
    }

    public func setFileState(path: String, offset: Int64, mtime: Date, size: Int64) {
        withLock {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "INSERT OR REPLACE INTO file_offsets(path, offset, mtime, size) VALUES(?,?,?,?)"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, offset)
            sqlite3_bind_double(stmt, 3, mtime.timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 4, size)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Events

    public func insertEvent(_ event: UsageEvent) -> Bool {
        withLock {
            if let mid = event.messageId, !mid.isEmpty {
                var check: OpaquePointer?
                defer { sqlite3_finalize(check) }
                if sqlite3_prepare_v2(db, "SELECT 1 FROM usage_events WHERE message_id = ? AND source = ? LIMIT 1", -1, &check, nil) == SQLITE_OK {
                    sqlite3_bind_text(check, 1, mid, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(check, 2, event.source.rawValue, -1, SQLITE_TRANSIENT)
                    if sqlite3_step(check) == SQLITE_ROW { return false }
                }
            }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
            INSERT OR IGNORE INTO usage_events
            (id, source, session_id, project, model, timestamp, input_tokens, output_tokens, cache_creation, cache_read, message_id)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            bindEvent(stmt, event)
            return sqlite3_step(stmt) == SQLITE_DONE
        }
    }

    public func insertEvents(_ events: [UsageEvent]) -> Int {
        var count = 0
        for e in events {
            if insertEvent(e) { count += 1 }
        }
        return count
    }

    private func bindEvent(_ stmt: OpaquePointer?, _ event: UsageEvent) {
        sqlite3_bind_text(stmt, 1, event.id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, event.source.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, event.sessionId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, event.project, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, event.model, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 6, event.timestamp.timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 7, Int64(event.usage.inputTokens))
        sqlite3_bind_int64(stmt, 8, Int64(event.usage.outputTokens))
        sqlite3_bind_int64(stmt, 9, Int64(event.usage.cacheCreationTokens))
        sqlite3_bind_int64(stmt, 10, Int64(event.usage.cacheReadTokens))
        if let mid = event.messageId {
            sqlite3_bind_text(stmt, 11, mid, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 11)
        }
    }

    public func events(from: Date? = nil, to: Date? = nil, source: TokenSource? = nil, limit: Int = 10_000) -> [UsageEvent] {
        withLock {
            var clauses: [String] = []
            if from != nil { clauses.append("timestamp >= ?") }
            if to != nil { clauses.append("timestamp < ?") }
            if source != nil { clauses.append("source = ?") }
            let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
            let sql = "SELECT id, source, session_id, project, model, timestamp, input_tokens, output_tokens, cache_creation, cache_read, message_id FROM usage_events \(whereSQL) ORDER BY timestamp DESC LIMIT ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            var idx: Int32 = 1
            if let from {
                sqlite3_bind_double(stmt, idx, from.timeIntervalSince1970)
                idx += 1
            }
            if let to {
                sqlite3_bind_double(stmt, idx, to.timeIntervalSince1970)
                idx += 1
            }
            if let source {
                sqlite3_bind_text(stmt, idx, source.rawValue, -1, SQLITE_TRANSIENT)
                idx += 1
            }
            sqlite3_bind_int(stmt, idx, Int32(limit))
            return readEvents(stmt)
        }
    }

    private func readEvents(_ stmt: OpaquePointer?) -> [UsageEvent] {
        var results: [UsageEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let sourceRaw = sqlite3_column_text(stmt, 1),
                  let source = TokenSource(rawValue: String(cString: sourceRaw)) else { continue }
            let mid: String? = sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 10))
            results.append(UsageEvent(
                id: String(cString: sqlite3_column_text(stmt, 0)),
                source: source,
                sessionId: String(cString: sqlite3_column_text(stmt, 2)),
                project: String(cString: sqlite3_column_text(stmt, 3)),
                model: String(cString: sqlite3_column_text(stmt, 4)),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                usage: TokenUsage(
                    inputTokens: Int(sqlite3_column_int64(stmt, 6)),
                    outputTokens: Int(sqlite3_column_int64(stmt, 7)),
                    cacheCreationTokens: Int(sqlite3_column_int64(stmt, 8)),
                    cacheReadTokens: Int(sqlite3_column_int64(stmt, 9))
                ),
                messageId: mid
            ))
        }
        return results
    }

    public func totalUsage(from: Date? = nil, to: Date? = nil, source: TokenSource? = nil) -> TokenUsage {
        withLock {
            var clauses: [String] = []
            if from != nil { clauses.append("timestamp >= ?") }
            if to != nil { clauses.append("timestamp < ?") }
            if source != nil { clauses.append("source = ?") }
            let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
            let sql = """
            SELECT COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0),
                   COALESCE(SUM(cache_creation),0), COALESCE(SUM(cache_read),0)
            FROM usage_events \(whereSQL)
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return .zero }
            var idx: Int32 = 1
            if let from {
                sqlite3_bind_double(stmt, idx, from.timeIntervalSince1970)
                idx += 1
            }
            if let to {
                sqlite3_bind_double(stmt, idx, to.timeIntervalSince1970)
                idx += 1
            }
            if let source {
                sqlite3_bind_text(stmt, idx, source.rawValue, -1, SQLITE_TRANSIENT)
                idx += 1
            }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return .zero }
            return TokenUsage(
                inputTokens: Int(sqlite3_column_int64(stmt, 0)),
                outputTokens: Int(sqlite3_column_int64(stmt, 1)),
                cacheCreationTokens: Int(sqlite3_column_int64(stmt, 2)),
                cacheReadTokens: Int(sqlite3_column_int64(stmt, 3))
            )
        }
    }

    public func oldestEventTimestamp(from: Date, to: Date, source: TokenSource) -> Date? {
        withLock {
            let sql = """
            SELECT MIN(timestamp) FROM usage_events
            WHERE timestamp >= ? AND timestamp < ? AND source = ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_double(stmt, 1, from.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, to.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, source.rawValue, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return nil }
            return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
        }
    }

    public func hourlyBuckets(lastHours: Int = 24) -> [HourlyBucket] {
        let cal = Calendar.current
        let now = Date()
        guard let start = cal.date(byAdding: .hour, value: -lastHours, to: now) else { return [] }
        let events = events(from: start, to: now, limit: 100_000)
        var map: [String: HourlyBucket] = [:]
        for e in events {
            let comps = cal.dateComponents([.year, .month, .day, .hour], from: e.timestamp)
            guard let hour = cal.date(from: comps) else { continue }
            let key = "\(e.source.rawValue)-\(hour.timeIntervalSince1970)"
            if var existing = map[key] {
                existing.usage = existing.usage + e.usage
                map[key] = existing
            } else {
                map[key] = HourlyBucket(source: e.source, hour: hour, usage: e.usage)
            }
        }
        return map.values.sorted { $0.hour < $1.hour }
    }

    public func dailyBuckets(lastDays: Int = 30) -> [DailyBucket] {
        let cal = Calendar.current
        let now = Date()
        guard let start = cal.date(byAdding: .day, value: -lastDays, to: now) else { return [] }
        let events = events(from: start, to: now, limit: 500_000)
        var map: [String: DailyBucket] = [:]
        for e in events {
            let day = cal.startOfDay(for: e.timestamp)
            let key = "\(e.source.rawValue)-\(day.timeIntervalSince1970)"
            if var existing = map[key] {
                existing.usage = existing.usage + e.usage
                map[key] = existing
            } else {
                map[key] = DailyBucket(source: e.source, day: day, usage: e.usage)
            }
        }
        return map.values.sorted { $0.day < $1.day }
    }

    public func sessions(limit: Int = 200) -> [SessionSummary] {
        withLock {
            let sql = """
            SELECT session_id, source, project,
                   MIN(timestamp), MAX(timestamp),
                   SUM(input_tokens), SUM(output_tokens), SUM(cache_creation), SUM(cache_read),
                   COUNT(*), MAX(model)
            FROM usage_events
            GROUP BY session_id, source
            ORDER BY MAX(timestamp) DESC
            LIMIT ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            var results: [SessionSummary] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let sourceRaw = sqlite3_column_text(stmt, 1),
                      let source = TokenSource(rawValue: String(cString: sourceRaw)) else { continue }
                results.append(SessionSummary(
                    id: String(cString: sqlite3_column_text(stmt, 0)),
                    source: source,
                    project: String(cString: sqlite3_column_text(stmt, 2)),
                    startTime: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                    endTime: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                    usage: TokenUsage(
                        inputTokens: Int(sqlite3_column_int64(stmt, 5)),
                        outputTokens: Int(sqlite3_column_int64(stmt, 6)),
                        cacheCreationTokens: Int(sqlite3_column_int64(stmt, 7)),
                        cacheReadTokens: Int(sqlite3_column_int64(stmt, 8))
                    ),
                    messageCount: Int(sqlite3_column_int64(stmt, 9)),
                    model: String(cString: sqlite3_column_text(stmt, 10))
                ))
            }
            return results
        }
    }

    public func sessionEvents(sessionId: String) -> [UsageEvent] {
        withLock {
            let sql = """
            SELECT id, source, session_id, project, model, timestamp, input_tokens, output_tokens, cache_creation, cache_read, message_id
            FROM usage_events WHERE session_id = ? ORDER BY timestamp ASC
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)
            return readEvents(stmt)
        }
    }

    // MARK: - Alerts

    public func upsertAlert(_ alert: AbuseAlert) {
        withLock {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
            INSERT OR REPLACE INTO alerts
            (id, kind, source, session_id, message, fired_at, acknowledged, value, threshold)
            VALUES (?,?,?,?,?,?,?,?,?)
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, alert.id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, alert.kind.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, alert.source.rawValue, -1, SQLITE_TRANSIENT)
            if let sid = alert.sessionId {
                sqlite3_bind_text(stmt, 4, sid, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_bind_text(stmt, 5, alert.message, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 6, alert.firedAt.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 7, alert.acknowledged ? 1 : 0)
            sqlite3_bind_double(stmt, 8, alert.value)
            sqlite3_bind_double(stmt, 9, alert.threshold)
            sqlite3_step(stmt)
        }
    }

    public func alerts(includeAcknowledged: Bool = true, limit: Int = 200) -> [AbuseAlert] {
        withLock {
            let sql: String
            if includeAcknowledged {
                sql = "SELECT id, kind, source, session_id, message, fired_at, acknowledged, value, threshold FROM alerts ORDER BY fired_at DESC LIMIT ?"
            } else {
                sql = "SELECT id, kind, source, session_id, message, fired_at, acknowledged, value, threshold FROM alerts WHERE acknowledged = 0 ORDER BY fired_at DESC LIMIT ?"
            }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            var results: [AbuseAlert] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let kindRaw = sqlite3_column_text(stmt, 1),
                      let kind = AlertKind(rawValue: String(cString: kindRaw)),
                      let sourceRaw = sqlite3_column_text(stmt, 2),
                      let source = TokenSource(rawValue: String(cString: sourceRaw)) else { continue }
                let sid: String? = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 3))
                results.append(AbuseAlert(
                    id: String(cString: sqlite3_column_text(stmt, 0)),
                    kind: kind,
                    source: source,
                    sessionId: sid,
                    message: String(cString: sqlite3_column_text(stmt, 4)),
                    firedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                    acknowledged: sqlite3_column_int(stmt, 6) != 0,
                    value: sqlite3_column_double(stmt, 7),
                    threshold: sqlite3_column_double(stmt, 8)
                ))
            }
            return results
        }
    }

    public func acknowledgeAlert(id: String) {
        withLock {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "UPDATE alerts SET acknowledged = 1 WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    public func activeAlertCount() -> Int {
        withLock {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM alerts WHERE acknowledged = 0", -1, &stmt, nil) == SQLITE_OK else {
                return 0
            }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    public func findRecentAlert(kind: AlertKind, source: TokenSource, sessionId: String?, within: TimeInterval) -> AbuseAlert? {
        let since = Date().addingTimeInterval(-within)
        return alerts(includeAcknowledged: true, limit: 500).first { alert in
            alert.kind == kind
                && alert.source == source
                && alert.sessionId == sessionId
                && alert.firedAt >= since
                && !alert.acknowledged
        }
    }
}

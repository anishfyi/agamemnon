import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum JSONLReader {
    /// Read new complete lines from `path` starting at `offset`. Returns lines and new offset.
    /// Tolerant of partial trailing lines and malformed content.
    public static func readNewLines(path: String, offset: Int64) -> (lines: [String], newOffset: Int64, size: Int64, mtime: Date) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              let attrs = try? fm.attributesOfItem(atPath: path),
              let sizeNum = attrs[.size] as? NSNumber,
              let mtime = attrs[.modificationDate] as? Date else {
            return ([], offset, 0, Date.distantPast)
        }
        let size = sizeNum.int64Value
        if size < offset {
            return readNewLines(path: path, offset: 0)
        }
        guard size > offset else {
            return ([], offset, size, mtime)
        }
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return ([], offset, size, mtime)
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            guard let data = try handle.readToEnd(), !data.isEmpty else {
                return ([], offset, size, mtime)
            }
            guard var text = String(data: data, encoding: .utf8) else {
                return ([], offset, size, mtime)
            }
            var consumed = data.count
            if !text.hasSuffix("\n") {
                if let lastNL = text.lastIndex(of: "\n") {
                    let incomplete = text[text.index(after: lastNL)...]
                    consumed -= incomplete.utf8.count
                    text = String(text[..<text.index(after: lastNL)])
                } else {
                    return ([], offset, size, mtime)
                }
            }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let cleaned = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return (cleaned, offset + Int64(consumed), size, mtime)
        } catch {
            return ([], offset, size, mtime)
        }
    }

    public static func parseJSONObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public static func parseDate(_ value: Any?) -> Date? {
        if let n = value as? Double {
            if n > 1_000_000_000_000 { return Date(timeIntervalSince1970: n / 1000.0) }
            return Date(timeIntervalSince1970: n)
        }
        if let n = value as? Int {
            let d = Double(n)
            if d > 1_000_000_000_000 { return Date(timeIntervalSince1970: d / 1000.0) }
            return Date(timeIntervalSince1970: d)
        }
        if let s = value as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime]
            if let d = iso.date(from: s) { return d }
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
            return df.date(from: s)
        }
        return nil
    }

    public static func intValue(_ dict: [String: Any], _ key: String) -> Int {
        if let n = dict[key] as? Int { return n }
        if let n = dict[key] as? Double { return Int(n) }
        if let n = dict[key] as? NSNumber { return n.intValue }
        if let s = dict[key] as? String, let n = Int(s) { return n }
        return 0
    }
}

public enum ClaudeParser {
    public static func parseLine(
        _ line: String,
        source: TokenSource,
        sessionId: String,
        project: String
    ) -> UsageEvent? {
        guard let obj = JSONLReader.parseJSONObject(line) else { return nil }

        let type = (obj["type"] as? String) ?? ""
        var usageDict: [String: Any]?
        var model = ""
        var messageId: String?
        var timestamp = JSONLReader.parseDate(obj["timestamp"]) ?? Date()

        if let message = obj["message"] as? [String: Any] {
            usageDict = message["usage"] as? [String: Any]
            model = (message["model"] as? String) ?? (obj["model"] as? String) ?? ""
            messageId = (message["id"] as? String) ?? (obj["id"] as? String)
            if let ts = JSONLReader.parseDate(message["timestamp"]) { timestamp = ts }
        } else {
            usageDict = obj["usage"] as? [String: Any]
            model = (obj["model"] as? String) ?? ""
            messageId = obj["id"] as? String
        }

        if type == "user" || type == "system" { return nil }
        guard let usage = usageDict else { return nil }

        let input = JSONLReader.intValue(usage, "input_tokens")
        let output = JSONLReader.intValue(usage, "output_tokens")
        let cacheCreate = JSONLReader.intValue(usage, "cache_creation_input_tokens")
        let cacheRead = JSONLReader.intValue(usage, "cache_read_input_tokens")
        if input == 0 && output == 0 && cacheCreate == 0 && cacheRead == 0 { return nil }

        // The nested `cache_creation` object splits the write between the two cache
        // TTLs, which bill at 2x (1h) and 1.25x (5m). Without the split every write
        // would be treated as the cheaper kind.
        var cacheWrite1h = 0
        if let breakdown = usage["cache_creation"] as? [String: Any] {
            cacheWrite1h = JSONLReader.intValue(breakdown, "ephemeral_1h_input_tokens")
        }

        let id = messageId.map { "\(source.rawValue)-\($0)" } ?? UUID().uuidString
        return UsageEvent(
            id: id,
            source: source,
            sessionId: sessionId,
            project: project,
            model: model,
            timestamp: timestamp,
            usage: TokenUsage(
                inputTokens: input,
                outputTokens: output,
                cacheCreationTokens: cacheCreate,
                cacheReadTokens: cacheRead,
                cacheWrite1hTokens: cacheWrite1h
            ),
            messageId: messageId
        )
    }

    public struct FileScan: Sendable {
        public var events: [UsageEvent]
        public var limits: [LimitHit]
        public var newOffset: Int64
        public var size: Int64
        public var mtime: Date
    }

    public static func parseFile(
        path: String,
        source: TokenSource,
        offset: Int64 = 0
    ) -> FileScan {
        let url = URL(fileURLWithPath: path)
        let sessionId = url.deletingPathExtension().lastPathComponent
        let project = url.deletingLastPathComponent().lastPathComponent
        let (lines, newOffset, size, mtime) = JSONLReader.readNewLines(path: path, offset: offset)
        var events: [UsageEvent] = []
        var limits: [LimitHit] = []
        var seen = Set<String>()
        var seenLimits = Set<String>()
        for line in lines {
            if let hit = LimitLogParser.parseLine(line, source: source) {
                // The CLI repeats one limit message across every retry; the hit id is
                // keyed on the reset instant so those collapse to a single event.
                if seenLimits.insert(hit.id).inserted {
                    limits.append(hit)
                }
                continue
            }
            guard let event = parseLine(line, source: source, sessionId: sessionId, project: project) else { continue }
            if let mid = event.messageId {
                if seen.contains(mid) { continue }
                seen.insert(mid)
            }
            events.append(event)
        }
        return FileScan(events: events, limits: limits, newOffset: newOffset, size: size, mtime: mtime)
    }

    public static func discoverTranscripts(in root: String) -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root) else { return [] }
        var results: [String] = []
        guard let enumerator = fm.enumerator(atPath: root) else { return [] }
        while let rel = enumerator.nextObject() as? String {
            if rel.hasSuffix(".jsonl") {
                results.append((root as NSString).appendingPathComponent(rel))
            }
        }
        return results
    }
}

public enum KimiParser {
    public static func parseLine(
        _ line: String,
        sessionId: String,
        project: String
    ) -> UsageEvent? {
        guard let obj = JSONLReader.parseJSONObject(line) else { return nil }

        var usageDict = obj["usage"] as? [String: Any]
        if usageDict == nil, let data = obj["data"] as? [String: Any] {
            usageDict = data["usage"] as? [String: Any]
        }
        if usageDict == nil, let message = obj["message"] as? [String: Any] {
            usageDict = message["usage"] as? [String: Any]
        }
        guard let usage = usageDict else { return nil }

        let inputOther = JSONLReader.intValue(usage, "inputOther")
            + JSONLReader.intValue(usage, "input_other")
            + JSONLReader.intValue(usage, "input_tokens")
        let output = JSONLReader.intValue(usage, "output")
            + JSONLReader.intValue(usage, "output_tokens")
        let cacheRead = JSONLReader.intValue(usage, "inputCacheRead")
            + JSONLReader.intValue(usage, "input_cache_read")
            + JSONLReader.intValue(usage, "cache_read_input_tokens")
        let cacheCreate = JSONLReader.intValue(usage, "inputCacheCreation")
            + JSONLReader.intValue(usage, "input_cache_creation")
            + JSONLReader.intValue(usage, "cache_creation_input_tokens")
        if inputOther == 0 && output == 0 && cacheRead == 0 && cacheCreate == 0 { return nil }

        // Kimi's `usage.record` carries epoch milliseconds under `time`. Missing that
        // key meant every Kimi event was stamped with the poll time instead of when it
        // happened, which put all of its history into the current window.
        let timestamp = JSONLReader.parseDate(obj["time"])
            ?? JSONLReader.parseDate(obj["timestamp"])
            ?? JSONLReader.parseDate(obj["ts"])
            ?? JSONLReader.parseDate(obj["created_at"])
            ?? Date()
        let model = (obj["model"] as? String)
            ?? ((obj["message"] as? [String: Any])?["model"] as? String)
            ?? "kimi"
        let messageId = (obj["id"] as? String)
            ?? ((obj["message"] as? [String: Any])?["id"] as? String)

        // Kimi's wire log carries no message id, so the identity has to be derived from
        // the record itself. A random suffix would re-insert every row whenever a file
        // is re-read from offset zero, silently doubling the totals.
        let fingerprint = "\(inputOther)/\(output)/\(cacheRead)/\(cacheCreate)/\(model)"
        let id = messageId.map { "kimi-\($0)" }
            ?? "kimi-\(sessionId)-\(Int(timestamp.timeIntervalSince1970 * 1000))-\(fingerprint.hashValue)"
        return UsageEvent(
            id: id,
            source: .kimi,
            sessionId: sessionId,
            project: project,
            model: model,
            timestamp: timestamp,
            usage: TokenUsage(
                inputTokens: inputOther,
                outputTokens: output,
                cacheCreationTokens: cacheCreate,
                cacheReadTokens: cacheRead
            ),
            messageId: messageId
        )
    }

    public static func parseFile(
        path: String,
        offset: Int64 = 0
    ) -> (events: [UsageEvent], newOffset: Int64, size: Int64, mtime: Date) {
        let parts = path.split(separator: "/").map(String.init)
        var sessionId = "unknown"
        var project = "unknown"
        if let sIdx = parts.lastIndex(where: { $0.hasPrefix("session_") }) {
            sessionId = parts[sIdx]
            if sIdx > 0 { project = parts[sIdx - 1] }
        }
        let (lines, newOffset, size, mtime) = JSONLReader.readNewLines(path: path, offset: offset)
        var events: [UsageEvent] = []
        for line in lines {
            if let event = parseLine(line, sessionId: sessionId, project: project) {
                events.append(event)
            }
        }
        return (events, newOffset, size, mtime)
    }

    public static func discoverWireLogs(in root: String) -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root) else { return [] }
        var results: [String] = []
        guard let enumerator = fm.enumerator(atPath: root) else { return [] }
        while let rel = enumerator.nextObject() as? String {
            if (rel as NSString).lastPathComponent == "wire.jsonl" {
                results.append((root as NSString).appendingPathComponent(rel))
            }
        }
        return results
    }
}
/// What Cursor actually records locally.
///
/// Cursor keeps no token counts on disk at all: `ai-code-tracking.db` measures
/// AI-authored lines of code, and the per-chat `store.db` blobs carry conversation
/// content with no usage fields. All quota accounting is server side. Rather than
/// scanning megabytes of chat blobs on every poll looking for token keys that do not
/// exist, this reports the real signals Cursor does have.
public struct CursorActivity: Sendable, Equatable {
    public var requestsByModel: [String: Int]
    public var linesAdded: Int
    public var linesRemoved: Int
    public var lastActivity: Date?
    public var conversationCount: Int

    public init(
        requestsByModel: [String: Int] = [:],
        linesAdded: Int = 0,
        linesRemoved: Int = 0,
        lastActivity: Date? = nil,
        conversationCount: Int = 0
    ) {
        self.requestsByModel = requestsByModel
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.lastActivity = lastActivity
        self.conversationCount = conversationCount
    }

    public var totalRequests: Int {
        requestsByModel.values.reduce(0, +)
    }

    public var topModels: [(model: String, requests: Int)] {
        requestsByModel
            .sorted { $0.value > $1.value }
            .prefix(4)
            .map { (model: $0.key, requests: $0.value) }
    }

    public static let empty = CursorActivity()
}

public enum CursorParser {
    public static let unavailableNote = "cursor: activity only, token counts are server-side"

    /// Read activity stats from the AI code-tracking database. Never throws, never
    /// blocks the other sources, and returns empty rather than partial garbage.
    public static func parseActivity(trackingDB path: String, since: Date? = nil) -> CursorActivity {
        guard FileManager.default.fileExists(atPath: path) else { return .empty }
        var db: OpaquePointer?
        // Opened read-only and immutable so a running Cursor cannot block the poll.
        let uri = "file:\(path)?immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let db else {
            if db != nil { sqlite3_close(db) }
            return .empty
        }
        defer { sqlite3_close(db) }

        var activity = CursorActivity()
        let cutoff = since?.timeIntervalSince1970

        if tableExists(db: db, name: "ai_code_hashes") {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = cutoff == nil
                ? "SELECT model, MAX(timestamp), COUNT(DISTINCT requestId), COUNT(DISTINCT conversationId) FROM ai_code_hashes GROUP BY model"
                : "SELECT model, MAX(timestamp), COUNT(DISTINCT requestId), COUNT(DISTINCT conversationId) FROM ai_code_hashes WHERE timestamp >= ? GROUP BY model"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                if let cutoff {
                    // Cursor stores epoch milliseconds in this column.
                    sqlite3_bind_double(stmt, 1, cutoff * 1000)
                }
                var conversations = 0
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let model = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "unknown"
                    let ts = sqlite3_column_double(stmt, 1)
                    let requests = Int(sqlite3_column_int64(stmt, 2))
                    conversations += Int(sqlite3_column_int64(stmt, 3))
                    activity.requestsByModel[model, default: 0] += requests
                    if ts > 0 {
                        let date = ts > 1_000_000_000_000
                            ? Date(timeIntervalSince1970: ts / 1000)
                            : Date(timeIntervalSince1970: ts)
                        if activity.lastActivity == nil || date > activity.lastActivity! {
                            activity.lastActivity = date
                        }
                    }
                }
                activity.conversationCount = conversations
            }
        }

        if tableExists(db: db, name: "scored_commits") {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = cutoff == nil
                ? "SELECT COALESCE(SUM(composerLinesAdded),0), COALESCE(SUM(composerLinesDeleted),0) FROM scored_commits"
                : "SELECT COALESCE(SUM(composerLinesAdded),0), COALESCE(SUM(composerLinesDeleted),0) FROM scored_commits WHERE scoredAt >= ?"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                if let cutoff {
                    sqlite3_bind_double(stmt, 1, cutoff * 1000)
                }
                if sqlite3_step(stmt) == SQLITE_ROW {
                    activity.linesAdded = Int(sqlite3_column_int64(stmt, 0))
                    activity.linesRemoved = Int(sqlite3_column_int64(stmt, 1))
                }
            }
        }

        return activity
    }

    private static func tableExists(db: OpaquePointer, name: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' AND name=?", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW
    }
}

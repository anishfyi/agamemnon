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
                cacheReadTokens: cacheRead
            ),
            messageId: messageId
        )
    }

    public static func parseFile(
        path: String,
        source: TokenSource,
        offset: Int64 = 0
    ) -> (events: [UsageEvent], newOffset: Int64, size: Int64, mtime: Date) {
        let url = URL(fileURLWithPath: path)
        let sessionId = url.deletingPathExtension().lastPathComponent
        let project = url.deletingLastPathComponent().lastPathComponent
        let (lines, newOffset, size, mtime) = JSONLReader.readNewLines(path: path, offset: offset)
        var events: [UsageEvent] = []
        var seen = Set<String>()
        for line in lines {
            guard let event = parseLine(line, source: source, sessionId: sessionId, project: project) else { continue }
            if let mid = event.messageId {
                if seen.contains(mid) { continue }
                seen.insert(mid)
            }
            events.append(event)
        }
        return (events, newOffset, size, mtime)
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

        let timestamp = JSONLReader.parseDate(obj["timestamp"])
            ?? JSONLReader.parseDate(obj["ts"])
            ?? JSONLReader.parseDate(obj["created_at"])
            ?? Date()
        let model = (obj["model"] as? String)
            ?? ((obj["message"] as? [String: Any])?["model"] as? String)
            ?? "kimi"
        let messageId = (obj["id"] as? String)
            ?? ((obj["message"] as? [String: Any])?["id"] as? String)

        let id = messageId.map { "kimi-\($0)" } ?? "kimi-\(sessionId)-\(timestamp.timeIntervalSince1970)-\(UUID().uuidString.prefix(8))"
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

public struct CursorParseResult: Sendable {
    public var events: [UsageEvent]
    public var activityOnly: Bool
    public var note: String

    public init(events: [UsageEvent], activityOnly: Bool, note: String) {
        self.events = events
        self.activityOnly = activityOnly
        self.note = note
    }
}

public enum CursorParser {
    public static func discoverTokenFiles(debugLogs: String) -> [String] {
        discoverTokenFiles(in: debugLogs)
    }

    public static func discoverTokenFiles(chats: String) -> [String] {
        discoverTokenFiles(in: chats)
    }

    private static func discoverTokenFiles(in root: String) -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root) else { return [] }
        var results: [String] = []
        guard let enumerator = fm.enumerator(atPath: root) else { return [] }
        while let rel = enumerator.nextObject() as? String {
            let name = (rel as NSString).lastPathComponent.lowercased()
            if name.hasSuffix(".jsonl") || name.hasSuffix(".json") || name.hasSuffix(".log") {
                results.append((root as NSString).appendingPathComponent(rel))
            }
        }
        return results
    }

    public static func extractFromJSONPublic(_ obj: Any, sessionId: String, project: String) -> [UsageEvent] {
        extractFromJSON(obj, sessionId: sessionId, project: project)
    }

    public static func parse(
        trackingDB: String,
        debugLogs: String,
        chats: String
    ) -> CursorParseResult {
        var events: [UsageEvent] = []
        var foundTokens = false

        let logEvents = scanDirectoryForTokens(root: debugLogs, sessionPrefix: "cursor-debug")
        let chatEvents = scanDirectoryForTokens(root: chats, sessionPrefix: "cursor-chat")
        events.append(contentsOf: logEvents)
        events.append(contentsOf: chatEvents)
        if !logEvents.isEmpty || !chatEvents.isEmpty {
            foundTokens = true
        }

        let activity = parseActivityDB(path: trackingDB)
        if !foundTokens {
            events.append(contentsOf: activity)
            return CursorParseResult(
                events: events,
                activityOnly: true,
                note: "cursor: activity only, tokens unavailable"
            )
        }
        let tokenSessions = Set(events.map(\.sessionId))
        for a in activity where !tokenSessions.contains(a.sessionId) {
            events.append(a)
        }
        return CursorParseResult(
            events: events,
            activityOnly: false,
            note: ""
        )
    }

    public static func scanDirectoryForTokens(root: String, sessionPrefix: String) -> [UsageEvent] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root) else { return [] }
        var events: [UsageEvent] = []
        guard let enumerator = fm.enumerator(atPath: root) else { return [] }
        while let rel = enumerator.nextObject() as? String {
            let full = (root as NSString).appendingPathComponent(rel)
            let name = (rel as NSString).lastPathComponent.lowercased()
            if name.hasSuffix(".jsonl") || name.hasSuffix(".json") || name.hasSuffix(".log") {
                events.append(contentsOf: scanFileForTokens(path: full, sessionId: "\(sessionPrefix)-\(abs(rel.hashValue))"))
            }
        }
        return events
    }

    public static func scanFileForTokens(path: String, sessionId: String) -> [UsageEvent] {
        let (lines, _, _, _) = JSONLReader.readNewLines(path: path, offset: 0)
        var events: [UsageEvent] = []
        let project = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        for line in lines {
            if let e = parseTokenLine(line, sessionId: sessionId, project: project) {
                events.append(e)
            }
        }
        if lines.isEmpty, let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            events.append(contentsOf: extractFromJSON(obj, sessionId: sessionId, project: project))
        }
        return events
    }

    public static func parseTokenLine(_ line: String, sessionId: String, project: String) -> UsageEvent? {
        guard let obj = JSONLReader.parseJSONObject(line) else {
            return parseTokenRegex(line, sessionId: sessionId, project: project)
        }
        if let usage = obj["usage"] as? [String: Any] {
            let input = JSONLReader.intValue(usage, "input_tokens")
                + JSONLReader.intValue(usage, "prompt_tokens")
                + JSONLReader.intValue(usage, "inputTokens")
            let output = JSONLReader.intValue(usage, "output_tokens")
                + JSONLReader.intValue(usage, "completion_tokens")
                + JSONLReader.intValue(usage, "outputTokens")
            let cacheRead = JSONLReader.intValue(usage, "cache_read_input_tokens")
                + JSONLReader.intValue(usage, "cacheReadTokens")
            let cacheCreate = JSONLReader.intValue(usage, "cache_creation_input_tokens")
                + JSONLReader.intValue(usage, "cacheWriteTokens")
            if input + output + cacheRead + cacheCreate == 0 { return nil }
            let ts = JSONLReader.parseDate(obj["timestamp"]) ?? JSONLReader.parseDate(obj["createdAt"]) ?? Date()
            let model = (obj["model"] as? String) ?? "cursor"
            return UsageEvent(
                id: "cursor-\(sessionId)-\(ts.timeIntervalSince1970)-\(UUID().uuidString.prefix(6))",
                source: .cursor,
                sessionId: sessionId,
                project: project,
                model: model,
                timestamp: ts,
                usage: TokenUsage(
                    inputTokens: input,
                    outputTokens: output,
                    cacheCreationTokens: cacheCreate,
                    cacheReadTokens: cacheRead
                ),
                messageId: obj["id"] as? String
            )
        }
        return nil
    }

    private static func parseTokenRegex(_ line: String, sessionId: String, project: String) -> UsageEvent? {
        func capture(_ key: String) -> Int {
            let pattern = "\"?\(key)\"?\\s*[:=]\\s*(\\d+)"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return 0 }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, options: [], range: range),
                  let r = Range(match.range(at: 1), in: line) else { return 0 }
            return Int(line[r]) ?? 0
        }
        let input = capture("input_tokens") + capture("prompt_tokens")
        let output = capture("output_tokens") + capture("completion_tokens")
        if input == 0 && output == 0 { return nil }
        return UsageEvent(
            id: "cursor-rx-\(UUID().uuidString)",
            source: .cursor,
            sessionId: sessionId,
            project: project,
            model: "cursor",
            timestamp: Date(),
            usage: TokenUsage(inputTokens: input, outputTokens: output),
            messageId: nil
        )
    }

    private static func extractFromJSON(_ obj: Any, sessionId: String, project: String) -> [UsageEvent] {
        var out: [UsageEvent] = []
        if let dict = obj as? [String: Any] {
            if let data = try? JSONSerialization.data(withJSONObject: dict),
               let line = String(data: data, encoding: .utf8),
               let e = parseTokenLine(line, sessionId: sessionId, project: project) {
                out.append(e)
            }
            for (_, v) in dict {
                out.append(contentsOf: extractFromJSON(v, sessionId: sessionId, project: project))
            }
        } else if let arr = obj as? [Any] {
            for v in arr {
                out.append(contentsOf: extractFromJSON(v, sessionId: sessionId, project: project))
            }
        }
        return out
    }

    public static func parseActivityDB(path: String) -> [UsageEvent] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return []
        }
        defer { sqlite3_close(db) }

        var events: [UsageEvent] = []
        if tableExists(db: db, name: "conversation_summaries") {
            events.append(contentsOf: readConversationSummaries(db: db))
        }
        if tableExists(db: db, name: "scored_commits") {
            events.append(contentsOf: readScoredCommits(db: db))
        }
        if events.isEmpty && tableExists(db: db, name: "ai_code_hashes") {
            events.append(contentsOf: readCodeHashes(db: db))
        }
        return events
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

    private static func readConversationSummaries(db: OpaquePointer) -> [UsageEvent] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT * FROM conversation_summaries LIMIT 500"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var colNames: [String] = []
        let count = sqlite3_column_count(stmt)
        for i in 0..<count {
            if let name = sqlite3_column_name(stmt, i) {
                colNames.append(String(cString: name).lowercased())
            } else {
                colNames.append("")
            }
        }
        var events: [UsageEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var id = UUID().uuidString
            var ts = Date()
            var title = "conversation"
            for (i, name) in colNames.enumerated() {
                if name.contains("id"), let t = sqlite3_column_text(stmt, Int32(i)) {
                    id = String(cString: t)
                } else if name.contains("time") || name.contains("created") || name.contains("updated") {
                    if sqlite3_column_type(stmt, Int32(i)) == SQLITE_FLOAT || sqlite3_column_type(stmt, Int32(i)) == SQLITE_INTEGER {
                        let v = sqlite3_column_double(stmt, Int32(i))
                        ts = v > 1_000_000_000_000 ? Date(timeIntervalSince1970: v / 1000) : Date(timeIntervalSince1970: v)
                    } else if let t = sqlite3_column_text(stmt, Int32(i)) {
                        ts = JSONLReader.parseDate(String(cString: t)) ?? ts
                    }
                } else if name.contains("title") || name.contains("summary") || name.contains("name"),
                          let t = sqlite3_column_text(stmt, Int32(i)) {
                    title = String(cString: t)
                }
            }
            events.append(UsageEvent(
                id: "cursor-conv-\(id)",
                source: .cursor,
                sessionId: id,
                project: title,
                model: "cursor",
                timestamp: ts,
                usage: .zero,
                messageId: id
            ))
        }
        return events
    }

    private static func readScoredCommits(db: OpaquePointer) -> [UsageEvent] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT * FROM scored_commits LIMIT 500", -1, &stmt, nil) == SQLITE_OK else { return [] }
        let count = sqlite3_column_count(stmt)
        var colNames: [String] = []
        for i in 0..<count {
            colNames.append(sqlite3_column_name(stmt, i).map { String(cString: $0).lowercased() } ?? "")
        }
        var events: [UsageEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var id = UUID().uuidString
            var ts = Date()
            var project = "commit"
            for (i, name) in colNames.enumerated() {
                if (name.contains("hash") || name == "id"), let t = sqlite3_column_text(stmt, Int32(i)) {
                    id = String(cString: t)
                } else if name.contains("time") || name.contains("date") {
                    let v = sqlite3_column_double(stmt, Int32(i))
                    if v > 0 {
                        ts = v > 1_000_000_000_000 ? Date(timeIntervalSince1970: v / 1000) : Date(timeIntervalSince1970: v)
                    }
                } else if name.contains("repo") || name.contains("path") || name.contains("cwd"),
                          let t = sqlite3_column_text(stmt, Int32(i)) {
                    project = String(cString: t)
                }
            }
            events.append(UsageEvent(
                id: "cursor-commit-\(id)",
                source: .cursor,
                sessionId: id,
                project: project,
                model: "cursor",
                timestamp: ts,
                usage: .zero,
                messageId: id
            ))
        }
        return events
    }

    private static func readCodeHashes(db: OpaquePointer) -> [UsageEvent] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT * FROM ai_code_hashes LIMIT 200", -1, &stmt, nil) == SQLITE_OK else { return [] }
        var events: [UsageEvent] = []
        var idx = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            idx += 1
            let id = "hash-\(idx)"
            events.append(UsageEvent(
                id: "cursor-hash-\(id)",
                source: .cursor,
                sessionId: id,
                project: "ai-code",
                model: "cursor",
                timestamp: Date(),
                usage: .zero,
                messageId: id
            ))
        }
        return events
    }
}

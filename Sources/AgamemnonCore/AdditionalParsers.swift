import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Opening a live CLI database without disturbing it.
///
/// These files belong to another running process, so they are opened read-only via URI.
/// `mode=ro` is tried first because several of these CLIs keep most of their recent data
/// in a write-ahead log that `immutable=1` cannot see; `immutable=1` is the fallback for
/// the case where the WAL is unreadable, at the cost of missing the newest rows.
enum ReadOnlySQLite {
    static func open(_ path: String) -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        for suffix in ["?mode=ro", "?immutable=1"] {
            var db: OpaquePointer?
            if sqlite3_open_v2("file:\(escaped)\(suffix)", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
               let db {
                return db
            }
            if db != nil { sqlite3_close(db) }
        }
        return nil
    }

    static func tableExists(_ db: OpaquePointer, _ name: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' AND name=?", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW
    }
}

// MARK: - Codex

/// OpenAI Codex CLI. Rollout transcripts under `~/.codex/sessions/YYYY/MM/DD/`.
public enum CodexParser {
    public static func discoverRollouts(in root: String) -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root), let e = fm.enumerator(atPath: root) else { return [] }
        var out: [String] = []
        while let rel = e.nextObject() as? String {
            let name = (rel as NSString).lastPathComponent
            if name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
                out.append((root as NSString).appendingPathComponent(rel))
            }
        }
        return out
    }

    public static func parseFile(
        path: String,
        offset: Int64 = 0
    ) -> (events: [UsageEvent], newOffset: Int64, size: Int64, mtime: Date) {
        let sessionId = (path as NSString).lastPathComponent
            .replacingOccurrences(of: "rollout-", with: "")
            .replacingOccurrences(of: ".jsonl", with: "")
        let (lines, newOffset, size, mtime) = JSONLReader.readNewLines(path: path, offset: offset)

        var events: [UsageEvent] = []
        var model = "gpt-5"
        var project = "codex"
        var index = 0

        for line in lines {
            guard let obj = JSONLReader.parseJSONObject(line),
                  let payload = obj["payload"] as? [String: Any] else { continue }
            let kind = (obj["type"] as? String) ?? ""

            // Model and cwd arrive on their own envelope lines ahead of the counts.
            if kind == "turn_context" || kind == "session_meta" {
                if let m = payload["model"] as? String { model = m }
                if let cwd = payload["cwd"] as? String {
                    project = (cwd as NSString).lastPathComponent
                }
                continue
            }

            guard (payload["type"] as? String) == "token_count",
                  let info = payload["info"] as? [String: Any],
                  // `total_token_usage` is cumulative for the session; only the per-turn
                  // delta may be summed or the totals compound quadratically.
                  let last = info["last_token_usage"] as? [String: Any] else { continue }

            let rawInput = JSONLReader.intValue(last, "input_tokens")
            let cached = JSONLReader.intValue(last, "cached_input_tokens")
            let output = JSONLReader.intValue(last, "output_tokens")
                + JSONLReader.intValue(last, "reasoning_output_tokens")
            // OpenAI reports cached tokens as a subset of input_tokens, unlike Anthropic
            // which reports them separately. Subtracting avoids counting them twice.
            let fresh = max(0, rawInput - cached)
            if fresh == 0 && output == 0 && cached == 0 { continue }

            index += 1
            let ts = JSONLReader.parseDate(obj["timestamp"]) ?? Date()
            events.append(UsageEvent(
                id: "codex-\(sessionId)-\(index)",
                source: .codex,
                sessionId: sessionId,
                project: project,
                model: model,
                timestamp: ts,
                usage: TokenUsage(inputTokens: fresh, outputTokens: output, cacheReadTokens: cached),
                messageId: nil
            ))
        }
        return (events, newOffset, size, mtime)
    }
}

// MARK: - Gemini

/// Gemini CLI keeps one JSON file per chat under `~/.gemini/tmp/<project>/chats/`.
public enum GeminiParser {
    public static func discoverChats(in root: String) -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root), let e = fm.enumerator(atPath: root) else { return [] }
        var out: [String] = []
        while let rel = e.nextObject() as? String {
            let name = (rel as NSString).lastPathComponent
            if name.hasPrefix("session-") && name.hasSuffix(".json") {
                out.append((root as NSString).appendingPathComponent(rel))
            }
        }
        return out
    }

    /// Whole-file parse: these are JSON documents, not append-only logs, so an offset
    /// would not be meaningful. Deterministic ids keep re-reads idempotent.
    public static func parseFile(path: String) -> [UsageEvent] {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = obj["messages"] as? [[String: Any]] else { return [] }

        let sessionId = (path as NSString).lastPathComponent
            .replacingOccurrences(of: ".json", with: "")
        // .../tmp/<project>/chats/<file>
        let chatsDir = (path as NSString).deletingLastPathComponent
        let project = ((chatsDir as NSString).deletingLastPathComponent as NSString).lastPathComponent

        var events: [UsageEvent] = []
        for (i, message) in messages.enumerated() {
            guard let tokens = message["tokens"] as? [String: Any] else { continue }
            let input = JSONLReader.intValue(tokens, "input")
            let cached = JSONLReader.intValue(tokens, "cached")
            let output = JSONLReader.intValue(tokens, "output")
                + JSONLReader.intValue(tokens, "thoughts")
            let tool = JSONLReader.intValue(tokens, "tool")
            // As with OpenAI, `cached` is part of `input` rather than additional to it.
            let fresh = max(0, input - cached) + tool
            if fresh == 0 && output == 0 && cached == 0 { continue }

            let ts = JSONLReader.parseDate(message["timestamp"])
                ?? JSONLReader.parseDate(obj["lastUpdated"])
                ?? Date()
            let id = (message["id"] as? String) ?? "\(i)"
            events.append(UsageEvent(
                id: "gemini-\(sessionId)-\(id)",
                source: .gemini,
                sessionId: sessionId,
                project: project,
                model: (message["model"] as? String) ?? "gemini",
                timestamp: ts,
                usage: TokenUsage(inputTokens: fresh, outputTokens: output, cacheReadTokens: cached),
                messageId: id
            ))
        }
        return events
    }
}

// MARK: - OpenCode

/// OpenCode stores messages in SQLite with usage nested inside a JSON `data` column.
public enum OpenCodeParser {
    public static func parse(dbPath: String, since: Date? = nil) -> [UsageEvent] {
        guard let db = ReadOnlySQLite.open(dbPath) else { return [] }
        defer { sqlite3_close(db) }
        guard ReadOnlySQLite.tableExists(db, "message") else { return [] }

        var sql = "SELECT id, session_id, time_created, data FROM message"
        if since != nil { sql += " WHERE time_created >= ?" }
        sql += " ORDER BY time_created DESC LIMIT 20000"

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        if let since {
            sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970 * 1000)
        }

        var events: [UsageEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idC = sqlite3_column_text(stmt, 0),
                  let dataC = sqlite3_column_text(stmt, 3) else { continue }
            let id = String(cString: idC)
            let sessionId = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "opencode"
            guard let obj = JSONLReader.parseJSONObject(String(cString: dataC)),
                  (obj["role"] as? String) == "assistant",
                  let tokens = obj["tokens"] as? [String: Any] else { continue }

            let input = JSONLReader.intValue(tokens, "input")
            let output = JSONLReader.intValue(tokens, "output")
                + JSONLReader.intValue(tokens, "reasoning")
            var cacheRead = 0
            var cacheWrite = 0
            if let cache = tokens["cache"] as? [String: Any] {
                cacheRead = JSONLReader.intValue(cache, "read")
                cacheWrite = JSONLReader.intValue(cache, "write")
            }
            if input == 0 && output == 0 && cacheRead == 0 && cacheWrite == 0 { continue }

            let created = sqlite3_column_double(stmt, 2)
            let ts = created > 1_000_000_000_000
                ? Date(timeIntervalSince1970: created / 1000)
                : Date(timeIntervalSince1970: created)
            let project = ((obj["path"] as? [String: Any])?["cwd"] as? String)
                .map { ($0 as NSString).lastPathComponent } ?? "opencode"

            events.append(UsageEvent(
                id: "opencode-\(id)",
                source: .opencode,
                sessionId: sessionId,
                project: project,
                model: (obj["modelID"] as? String) ?? "opencode",
                timestamp: ts,
                usage: TokenUsage(
                    inputTokens: input,
                    outputTokens: output,
                    cacheCreationTokens: cacheWrite,
                    cacheReadTokens: cacheRead
                ),
                messageId: id
            ))
        }
        return events
    }
}

// MARK: - Crush

/// Crush records totals per session rather than per message.
public enum CrushParser {
    public static func parse(dbPath: String) -> [UsageEvent] {
        guard let db = ReadOnlySQLite.open(dbPath) else { return [] }
        defer { sqlite3_close(db) }
        guard ReadOnlySQLite.tableExists(db, "sessions") else { return [] }

        let sql = """
        SELECT id, title, prompt_tokens, completion_tokens, updated_at
        FROM sessions WHERE prompt_tokens > 0 OR completion_tokens > 0
        ORDER BY updated_at DESC LIMIT 2000
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

        var events: [UsageEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idC = sqlite3_column_text(stmt, 0) else { continue }
            let id = String(cString: idC)
            let updated = sqlite3_column_double(stmt, 4)
            let ts = updated > 1_000_000_000_000
                ? Date(timeIntervalSince1970: updated / 1000)
                : Date(timeIntervalSince1970: updated)
            // One row per session, so the id is stable and re-reads are idempotent even
            // though the token totals grow as the session continues.
            events.append(UsageEvent(
                id: "crush-\(id)",
                source: .crush,
                sessionId: id,
                project: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "crush",
                model: "crush",
                timestamp: ts,
                usage: TokenUsage(
                    inputTokens: Int(sqlite3_column_int64(stmt, 2)),
                    outputTokens: Int(sqlite3_column_int64(stmt, 3))
                ),
                messageId: id
            ))
        }
        return events
    }
}

// MARK: - Copilot

/// GitHub Copilot CLI reports output tokens only, so its cards show a partial picture
/// by design rather than a fabricated input count.
public enum CopilotParser {
    public static let partialNote = "copilot: output tokens only, input is not recorded locally"

    public static func discoverEventLogs(in root: String) -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root),
              let entries = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        return entries
            .map { (root as NSString).appendingPathComponent($0) }
            .map { ($0 as NSString).appendingPathComponent("events.jsonl") }
            .filter { fm.fileExists(atPath: $0) }
    }

    public static func parseFile(
        path: String,
        offset: Int64 = 0
    ) -> (events: [UsageEvent], newOffset: Int64, size: Int64, mtime: Date) {
        let sessionId = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let (lines, newOffset, size, mtime) = JSONLReader.readNewLines(path: path, offset: offset)

        var events: [UsageEvent] = []
        var model = "copilot"
        var project = "copilot"

        for line in lines {
            guard let obj = JSONLReader.parseJSONObject(line),
                  let data = obj["data"] as? [String: Any] else { continue }
            let type = (obj["type"] as? String) ?? ""

            if type == "session.start" || type == "session.resume" {
                if let m = data["selectedModel"] as? String { model = m }
                if let ctx = data["context"] as? [String: Any],
                   let cwd = ctx["cwd"] as? String {
                    project = (cwd as NSString).lastPathComponent
                }
                continue
            }

            guard type == "assistant.message" else { continue }
            let output = JSONLReader.intValue(data, "outputTokens")
            guard output > 0 else { continue }

            let messageId = (data["messageId"] as? String) ?? UUID().uuidString
            let ts = JSONLReader.parseDate(obj["timestamp"])
                ?? JSONLReader.parseDate(data["timestamp"])
                ?? Date()
            events.append(UsageEvent(
                id: "copilot-\(messageId)",
                source: .copilot,
                sessionId: sessionId,
                project: project,
                model: model,
                timestamp: ts,
                usage: TokenUsage(outputTokens: output),
                messageId: messageId
            ))
        }
        return (events, newOffset, size, mtime)
    }
}

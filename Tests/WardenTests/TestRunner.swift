import Foundation
import SQLite3
import WardenCore

@main
struct WardenTestRunner {
    static func main() {
        var failed = 0
        failed += run("ClaudeParser.parsesAndDedupes", testClaudeParsesAndDedupes)
        failed += run("ClaudeParser.skipsMalformed", testClaudeSkipsMalformed)
        failed += run("ClaudeParser.incrementalOffset", testClaudeIncrementalOffset)
        failed += run("KimiParser.parsesWireUsage", testKimiParsesWire)
        failed += run("KimiParser.toleratesGarbage", testKimiGarbage)
        failed += run("CursorParser.parsesTokenJSONL", testCursorTokenJSONL)
        failed += run("CursorParser.activityOnlyHonest", testCursorActivityOnly)
        failed += run("CursorParser.tokensDisableActivityOnly", testCursorTokensPresent)
        failed += run("Database.insertAndAggregate", testDatabaseInsert)
        failed += run("AbuseEngine.dailyCap", testDailyCapAlert)

        if failed == 0 {
            print("All tests passed.")
            exit(0)
        } else {
            print("FAILED: \(failed) test(s)")
            exit(1)
        }
    }

    static func run(_ name: String, _ body: () throws -> Void) -> Int {
        do {
            try body()
            print("PASS \(name)")
            return 0
        } catch {
            print("FAIL \(name): \(error)")
            return 1
        }
    }

    static func fixture(_ name: String) throws -> URL {
        let candidates: [URL] = [
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/\(name)"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Tests/WardenTests/Fixtures/\(name)"),
        ]
        // Bundle.module is available when SPM embeds resources
        #if SWIFT_PACKAGE
        if let bundled = Bundle.module.url(forResource: name.replacingOccurrences(of: ".jsonl", with: ""), withExtension: "jsonl", subdirectory: "Fixtures") {
            return bundled
        }
        if let bundled = Bundle.module.path(forResource: name, ofType: nil, inDirectory: "Fixtures") {
            return URL(fileURLWithPath: bundled)
        }
        #endif
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        throw TestError("fixture not found: \(name)")
    }

    // MARK: - Claude

    static func testClaudeParsesAndDedupes() throws {
        let url = try fixture("claude_sample.jsonl")
        let (events, _, _, _) = ClaudeParser.parseFile(path: url.path, source: .claudeWork, offset: 0)
        try expect(events.count == 3, "expected 3 events, got \(events.count)")
        let byId = Dictionary(uniqueKeysWithValues: events.compactMap { e -> (String, UsageEvent)? in
            guard let mid = e.messageId else { return nil }
            return (mid, e)
        })
        try expect(byId["msg_001"]?.usage.inputTokens == 1200)
        try expect(byId["msg_001"]?.usage.cacheReadTokens == 8000)
        try expect(byId["msg_001"]?.usage.outputTokens == 350)
        try expect(byId["msg_002"]?.usage.totalTokens == 400 + 100 + 9000 + 200)
        try expect(byId["msg_003"]?.model.contains("opus") == true)
    }

    static func testClaudeSkipsMalformed() throws {
        let url = try fixture("claude_sample.jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        var parsed = 0
        var skipped = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if ClaudeParser.parseLine(line, source: .claudeWork, sessionId: "s", project: "p") != nil {
                parsed += 1
            } else {
                skipped += 1
            }
        }
        try expect(parsed > 0)
        try expect(skipped > 0)
    }

    static func testClaudeIncrementalOffset() throws {
        let url = try fixture("claude_sample.jsonl")
        let (first, offset, _, _) = ClaudeParser.parseFile(path: url.path, source: .claudeWork, offset: 0)
        try expect(!first.isEmpty)
        let (second, _, _, _) = ClaudeParser.parseFile(path: url.path, source: .claudeWork, offset: offset)
        try expect(second.isEmpty)
    }

    // MARK: - Kimi

    static func testKimiParsesWire() throws {
        let url = try fixture("kimi_wire.jsonl")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sessions/myproj/session_abc/agents/a", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let dest = tmp.appendingPathComponent("wire.jsonl")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: url, to: dest)

        let (events, _, _, _) = KimiParser.parseFile(path: dest.path, offset: 0)
        try expect(events.count >= 3, "expected >=3 kimi events, got \(events.count)")
        guard let first = events.first(where: { $0.messageId == "kimi_1" || $0.id.contains("kimi_1") }) else {
            throw TestError("missing kimi_1")
        }
        try expect(first.usage.inputTokens == 1500)
        try expect(first.usage.outputTokens == 400)
        try expect(first.usage.cacheReadTokens == 7000)
        try expect(first.usage.cacheCreationTokens == 200)
        try expect(first.sessionId == "session_abc")
        try expect(first.project == "myproj")
        try expect(events.contains { $0.usage.inputTokens == 10 && $0.usage.outputTokens == 5 })
        try expect(events.contains { $0.usage.inputTokens == 99 && $0.usage.outputTokens == 11 })
    }

    static func testKimiGarbage() throws {
        try expect(KimiParser.parseLine("this is not json {{{", sessionId: "s", project: "p") == nil)
    }

    // MARK: - Cursor

    static func testCursorTokenJSONL() throws {
        let url = try fixture("cursor_tokens.jsonl")
        let events = CursorParser.scanFileForTokens(path: url.path, sessionId: "test-session")
        try expect(events.count >= 2)
        try expect(events.contains { $0.usage.inputTokens == 2000 && $0.usage.outputTokens == 500 })
        try expect(events.contains { $0.usage.inputTokens == 100 && $0.usage.outputTokens == 20 })
    }

    static func testCursorActivityOnly() throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-activity-\(UUID().uuidString).db").path
        try createCursorActivityDB(at: dbPath)
        let result = CursorParser.parse(
            trackingDB: dbPath,
            debugLogs: "/tmp/warden-nonexistent-debug",
            chats: "/tmp/warden-nonexistent-chats"
        )
        try expect(result.activityOnly)
        try expect(result.note == "cursor: activity only, tokens unavailable")
        try expect(!result.events.isEmpty)
        try expect(result.events.allSatisfy { $0.usage.totalTokens == 0 })
    }

    static func testCursorTokensPresent() throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-activity-\(UUID().uuidString).db").path
        try createCursorActivityDB(at: dbPath)
        let logs = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-logs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let fixtureURL = try fixture("cursor_tokens.jsonl")
        try FileManager.default.copyItem(at: fixtureURL, to: logs.appendingPathComponent("usage.jsonl"))
        let result = CursorParser.parse(
            trackingDB: dbPath,
            debugLogs: logs.path,
            chats: "/tmp/warden-nonexistent-chats"
        )
        try expect(!result.activityOnly)
        try expect(result.events.contains { $0.usage.totalTokens > 0 })
    }

    static func createCursorActivityDB(at path: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else {
            throw TestError("sqlite open failed")
        }
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE conversation_summaries (id TEXT, title TEXT, created_at REAL);
        CREATE TABLE scored_commits (hash TEXT, repo TEXT, committed_at REAL);
        CREATE TABLE ai_code_hashes (hash TEXT);
        INSERT INTO conversation_summaries VALUES ('conv1', 'Refactor auth', 1752832800);
        INSERT INTO scored_commits VALUES ('abc123', '/Users/me/proj', 1752832900);
        INSERT INTO ai_code_hashes VALUES ('hash1');
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw TestError("sqlite exec failed")
        }
    }

    // MARK: - DB / Abuse

    static func testDatabaseInsert() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("warden-test-\(UUID().uuidString).db").path
        let db = try WardenDatabase(path: path)
        let e1 = UsageEvent(
            source: .claudeWork,
            sessionId: "s1",
            project: "p",
            model: "claude-sonnet",
            timestamp: Date(),
            usage: TokenUsage(inputTokens: 100, outputTokens: 50, cacheCreationTokens: 10, cacheReadTokens: 200),
            messageId: "m1"
        )
        try expect(db.insertEvent(e1))
        try expect(!db.insertEvent(e1))
        let total = db.totalUsage(source: .claudeWork)
        try expect(total.inputTokens == 100)
        try expect(total.outputTokens == 50)
    }

    static func testDailyCapAlert() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("warden-alert-\(UUID().uuidString).db").path
        let db = try WardenDatabase(path: path)
        let e = UsageEvent(
            source: .kimi,
            sessionId: "s",
            project: "p",
            model: "kimi",
            timestamp: Date(),
            usage: TokenUsage(inputTokens: 6_000_000, outputTokens: 0),
            messageId: "big"
        )
        _ = db.insertEvent(e)
        var thresholds = AlertThresholds.default
        thresholds.dailyCapTokens = 5_000_000
        let alerts = AbuseEngine.evaluate(db: db, thresholds: thresholds)
        try expect(alerts.contains { $0.kind == .dailyCap && $0.source == .kimi })
    }

    static func expect(_ condition: Bool, _ message: String = "assertion failed") throws {
        if !condition { throw TestError(message) }
    }
}

struct TestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

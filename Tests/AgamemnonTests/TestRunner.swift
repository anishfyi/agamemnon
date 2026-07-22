import Foundation
import SQLite3
import AgamemnonCore

@main
struct AgamemnonTestRunner {
    static func main() {
        var failed = 0
        failed += run("ClaudeParser.parsesAndDedupes", testClaudeParsesAndDedupes)
        failed += run("ClaudeParser.skipsMalformed", testClaudeSkipsMalformed)
        failed += run("ClaudeParser.incrementalOffset", testClaudeIncrementalOffset)
        failed += run("ClaudeParser.splitsCacheTTLs", testClaudeCacheTTLSplit)
        failed += run("KimiParser.parsesWireUsage", testKimiParsesWire)
        failed += run("KimiParser.toleratesGarbage", testKimiGarbage)
        failed += run("KimiParser.stableIdsAcrossReparse", testKimiStableIds)
        failed += run("CursorParser.readsActivityNotTokens", testCursorActivity)
        failed += run("Pricing.cacheMultipliers", testPricingCacheMultipliers)
        failed += run("Pricing.longestMatchWins", testPricingLongestMatch)
        failed += run("Pricing.billableExcludesCacheNoise", testBillableWeighting)
        failed += run("LimitLog.parsesSessionReset", testLimitLogSessionReset)
        failed += run("LimitLog.collapsesRepeats", testLimitLogCollapsesRepeats)
        failed += run("LimitLog.ignoresServerThrottle", testLimitLogServerThrottle)
        failed += run("LimitCalibrator.prefersMeasured", testLimitCalibration)
        failed += run("LimitCalibrator.usesMedian", testLimitCalibrationUsesMedian)
        failed += run("Database.insertAndAggregate", testDatabaseInsert)
        failed += run("Database.usageByModel", testUsageByModel)
        failed += run("Database.limitHitRoundTrip", testLimitHitRoundTrip)
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
                .appendingPathComponent("Tests/AgamemnonTests/Fixtures/\(name)"),
        ]
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

    static func tempFile(_ contents: String, ext: String = "jsonl") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agamemnon-\(UUID().uuidString).\(ext)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Claude

    static func testClaudeParsesAndDedupes() throws {
        let url = try fixture("claude_sample.jsonl")
        let scan = ClaudeParser.parseFile(path: url.path, source: .claudeWork, offset: 0)
        try expect(scan.events.count == 3, "expected 3 events, got \(scan.events.count)")
        let byId = Dictionary(uniqueKeysWithValues: scan.events.compactMap { e -> (String, UsageEvent)? in
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
        let first = ClaudeParser.parseFile(path: url.path, source: .claudeWork, offset: 0)
        try expect(!first.events.isEmpty)
        let second = ClaudeParser.parseFile(path: url.path, source: .claudeWork, offset: first.newOffset)
        try expect(second.events.isEmpty)
    }

    /// The 1-hour cache bills at 2x and the 5-minute at 1.25x, so the split has to
    /// survive parsing or every write is silently treated as the cheaper kind.
    static func testClaudeCacheTTLSplit() throws {
        let line = """
        {"type":"assistant","timestamp":"2026-07-22T08:00:00.000Z","message":{"id":"msg_ttl","model":"claude-opus-4-8","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":1000,"cache_read_input_tokens":5000,"cache_creation":{"ephemeral_1h_input_tokens":800,"ephemeral_5m_input_tokens":200}}}}
        """
        guard let event = ClaudeParser.parseLine(line, source: .claudeWork, sessionId: "s", project: "p") else {
            throw TestError("failed to parse line")
        }
        try expect(event.usage.cacheCreationTokens == 1000)
        try expect(event.usage.cacheWrite1hTokens == 800, "1h split lost")
        try expect(event.usage.cacheWrite5mTokens == 200, "5m split wrong")
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

    /// Kimi's wire log has no message id. Ids must be derived deterministically, or a
    /// file re-read from offset zero double-counts every record it contains.
    static func testKimiStableIds() throws {
        let line = """
        {"type":"usage.record","model":"kimi-code/k3","usageScope":"turn","time":1784416266733,"usage":{"inputOther":2465,"output":59,"inputCacheRead":19200,"inputCacheCreation":0}}
        """
        guard let a = KimiParser.parseLine(line, sessionId: "session_x", project: "proj"),
              let b = KimiParser.parseLine(line, sessionId: "session_x", project: "proj") else {
            throw TestError("failed to parse kimi usage record")
        }
        try expect(a.id == b.id, "kimi ids are not reproducible: \(a.id) vs \(b.id)")
        try expect(a.usage.cacheReadTokens == 19200)
        try expect(a.model == "kimi-code/k3")
    }

    // MARK: - Cursor

    /// Cursor stores no token counts anywhere on disk. The parser must report the
    /// activity it does have and must not invent usage rows.
    static func testCursorActivity() throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-activity-\(UUID().uuidString).db").path
        try createCursorActivityDB(at: dbPath)
        let activity = CursorParser.parseActivity(trackingDB: dbPath)
        try expect(activity.totalRequests == 3, "expected 3 requests, got \(activity.totalRequests)")
        try expect(activity.requestsByModel["composer-2.5"] == 2)
        try expect(activity.requestsByModel["grok-4.5"] == 1)
        try expect(activity.linesAdded == 120)
        try expect(activity.lastActivity != nil)
    }

    static func createCursorActivityDB(at path: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else {
            throw TestError("sqlite open failed")
        }
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE ai_code_hashes (hash TEXT, source TEXT, fileExtension TEXT, fileName TEXT,
            requestId TEXT, conversationId TEXT, timestamp REAL, model TEXT, createdAt REAL);
        CREATE TABLE scored_commits (commitHash TEXT, branchName TEXT, scoredAt REAL,
            composerLinesAdded INTEGER, composerLinesDeleted INTEGER);
        INSERT INTO ai_code_hashes VALUES ('h1','composer','swift','a.swift','req1','c1',1784416266733,'composer-2.5',1784416266733);
        INSERT INTO ai_code_hashes VALUES ('h2','composer','swift','b.swift','req2','c1',1784416266734,'composer-2.5',1784416266734);
        INSERT INTO ai_code_hashes VALUES ('h3','composer','swift','c.swift','req3','c2',1784416266735,'grok-4.5',1784416266735);
        INSERT INTO scored_commits VALUES ('abc','main',1784416266000,120,30);
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw TestError("sqlite exec failed")
        }
    }

    // MARK: - Pricing

    /// The original bug: every input-side token, including cache reads, was charged at
    /// the full input rate. On a cache-heavy agent workload that overstates spend ~2x.
    static func testPricingCacheMultipliers() throws {
        let opus = DefaultPricing.match("claude-opus-4-8", in: DefaultPricing.table)
        try expect(opus.inputPerMillion == 5.0, "opus 4.8 input price wrong")
        try expect(opus.outputPerMillion == 25.0, "opus 4.8 output price wrong")

        // 1M cache reads on Opus cost $0.50, not $5.00.
        let readsOnly = TokenUsage(cacheReadTokens: 1_000_000)
        try expect(abs(opus.estimateCost(usage: readsOnly) - 0.50) < 0.0001,
                   "cache read should be 0.1x input, got \(opus.estimateCost(usage: readsOnly))")

        // 1M 1-hour cache writes cost $10.00 (2x); 5-minute writes cost $6.25 (1.25x).
        let write1h = TokenUsage(cacheCreationTokens: 1_000_000, cacheWrite1hTokens: 1_000_000)
        try expect(abs(opus.estimateCost(usage: write1h) - 10.0) < 0.0001,
                   "1h cache write should be 2x input, got \(opus.estimateCost(usage: write1h))")
        let write5m = TokenUsage(cacheCreationTokens: 1_000_000)
        try expect(abs(opus.estimateCost(usage: write5m) - 6.25) < 0.0001,
                   "5m cache write should be 1.25x input, got \(opus.estimateCost(usage: write5m))")
    }

    /// A `claude-opus` family row must not shadow the specific `claude-opus-4-8` row
    /// just because it happens to appear earlier in the table.
    static func testPricingLongestMatch() throws {
        let m = DefaultPricing.match("claude-opus-4-8[1m]", in: DefaultPricing.table)
        try expect(m.model == "claude-opus-4-8", "matched \(m.model) instead of claude-opus-4-8")
        try expect(m.inputPerMillion == 5.0)

        let haiku = DefaultPricing.match("claude-haiku-4-5-20251001", in: DefaultPricing.table)
        try expect(haiku.model == "claude-haiku-4-5", "matched \(haiku.model)")
        try expect(haiku.inputPerMillion == 1.0)

        let unknown = DefaultPricing.match("some-model-nobody-has-heard-of", in: DefaultPricing.table)
        try expect(unknown.model == "default")
    }

    /// Window bars track input-token-equivalents. A million cache reads must not count
    /// the same as a million fresh input tokens, or the ratio is meaningless.
    static func testBillableWeighting() throws {
        let opus = DefaultPricing.match("claude-opus-4-8", in: DefaultPricing.table)
        let cacheHeavy = TokenUsage(inputTokens: 0, outputTokens: 0, cacheReadTokens: 1_000_000)
        let fresh = TokenUsage(inputTokens: 1_000_000)
        try expect(opus.billableTokens(usage: cacheHeavy) < opus.billableTokens(usage: fresh) / 5,
                   "cache reads should weigh far less than fresh input")
        // Output is 5x input on Opus, so it must dominate an equal raw token count.
        let output = TokenUsage(outputTokens: 1_000_000)
        try expect(opus.billableTokens(usage: output) > opus.billableTokens(usage: fresh),
                   "output should outweigh input at a 5x price ratio")
    }

    // MARK: - Limit log

    static func testLimitLogSessionReset() throws {
        let hitAt = "2026-07-22T02:15:00.000Z"
        let line = """
        {"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","timestamp":"\(hitAt)","uuid":"u1","message":{"model":"<synthetic>","content":[{"type":"text","text":"You've hit your session limit · resets 10:20am (Asia/Calcutta)"}]}}
        """
        guard let hit = LimitLogParser.parseLine(line, source: .claudeWork) else {
            throw TestError("did not parse a session limit hit")
        }
        try expect(hit.kind == .session, "wrong kind: \(hit.kind)")
        guard let reset = hit.resetAt else { throw TestError("no reset time") }

        // 10:20am in Asia/Calcutta is 04:50 UTC. The hit was at 02:15 UTC the same day,
        // so the reset is later that same day rather than the next.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Calcutta")!
        let comps = cal.dateComponents([.hour, .minute], from: reset)
        try expect(comps.hour == 10 && comps.minute == 20,
                   "reset resolved to \(comps.hour ?? -1):\(comps.minute ?? -1) local, expected 10:20")
        try expect(reset > hit.hitAt, "reset must be after the hit")
    }

    /// The CLI writes the same limit message on every retry, hundreds of times. They
    /// must collapse to one event or the calibrator sees phantom limit hits.
    static func testLimitLogCollapsesRepeats() throws {
        func line(_ uuid: String, _ ts: String) -> String {
            """
            {"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","timestamp":"\(ts)","uuid":"\(uuid)","message":{"model":"<synthetic>","content":[{"type":"text","text":"You've hit your session limit · resets 4:40am (Asia/Calcutta)"}]}}
            """
        }
        let contents = [
            line("a", "2026-07-22T02:15:00.000Z"),
            line("b", "2026-07-22T02:16:00.000Z"),
            line("c", "2026-07-22T02:17:00.000Z"),
        ].joined(separator: "\n") + "\n"
        let url = try tempFile(contents)
        let scan = ClaudeParser.parseFile(path: url.path, source: .claudeWork, offset: 0)
        try expect(scan.limits.count == 1, "expected 1 collapsed limit hit, got \(scan.limits.count)")
        try expect(scan.events.isEmpty, "limit lines must not become usage events")
    }

    static func testLimitLogServerThrottle() throws {
        let line = """
        {"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","timestamp":"2026-07-22T02:15:00.000Z","uuid":"u2","message":{"model":"<synthetic>","content":[{"type":"text","text":"API Error: Server is temporarily limiting requests (not your usage limit) · Rate limited"}]}}
        """
        guard let hit = LimitLogParser.parseLine(line, source: .claudeWork) else {
            throw TestError("did not parse throttle line")
        }
        try expect(hit.kind == .serverThrottle, "server throttling must not be counted as a quota hit")
        try expect(hit.resetAt == nil)
    }

    static func testLimitCalibration() throws {
        let now = Date()
        let reset = now.addingTimeInterval(-3600)
        let hit = LimitHit(
            id: "h1", kind: .session, source: .claudeWork,
            hitAt: reset.addingTimeInterval(-60), resetAt: reset, rawText: ""
        )
        // Observed consumption in the block that filled up, well above the seed floor.
        let measured = LimitCalibrator.calibrate(
            hits: [hit], kind: .session, window: 5 * 3600, seed: 1_000_000,
            billableIn: { _, _ in 4_200_000 }
        )
        try expect(measured.origin == .measured, "should prefer a measured limit")
        try expect(measured.limit == 4_200_000)

        // A block we barely observed must not drag the limit down to nothing.
        let partial = LimitCalibrator.calibrate(
            hits: [hit], kind: .session, window: 5 * 3600, seed: 1_000_000,
            billableIn: { _, _ in 1_000 }
        )
        try expect(partial.origin == .planEstimate, "partial block should fall back to the seed")
        try expect(partial.limit == 1_000_000)

        // No hits at all means we are still guessing, and must say so.
        let none = LimitCalibrator.calibrate(
            hits: [], kind: .session, window: 5 * 3600, seed: 1_000_000,
            billableIn: { _, _ in 0 }
        )
        try expect(none.origin == .planEstimate)
    }

    /// Measured blocks vary by ~3x in real data. The estimator must take the median, or
    /// one contaminated block permanently inflates the limit and the bar reads far
    /// emptier than the window really is.
    static func testLimitCalibrationUsesMedian() throws {
        let now = Date()
        var hits: [LimitHit] = []
        var perReset: [Double: Double] = [:]
        // Three blocks measuring 10M, 11M and one 36M outlier.
        for (i, value) in [10_000_000.0, 11_000_000.0, 36_000_000.0].enumerated() {
            let reset = now.addingTimeInterval(-Double(i + 1) * 6 * 3600)
            perReset[reset.timeIntervalSince1970] = value
            hits.append(LimitHit(
                id: "h\(i)", kind: .session, source: .claudeWork,
                hitAt: reset.addingTimeInterval(-60), resetAt: reset, rawText: ""
            ))
        }
        let result = LimitCalibrator.calibrate(
            hits: hits, kind: .session, window: 5 * 3600, seed: 1_000_000,
            billableIn: { start, _ in
                perReset[start.addingTimeInterval(5 * 3600).timeIntervalSince1970] ?? 0
            }
        )
        try expect(result.sampleCount == 3, "expected 3 samples, got \(result.sampleCount)")
        try expect(result.limit == 11_000_000,
                   "expected the median 11M, got \(result.limit), an outlier is dominating")
    }

    // MARK: - DB / Abuse

    static func testDatabaseInsert() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("agamemnon-test-\(UUID().uuidString).db").path
        let db = try AgamemnonDatabase(path: path)
        let e1 = UsageEvent(
            source: .claudeWork,
            sessionId: "s1",
            project: "p",
            model: "claude-sonnet",
            timestamp: Date(),
            usage: TokenUsage(inputTokens: 100, outputTokens: 50, cacheCreationTokens: 10, cacheReadTokens: 200, cacheWrite1hTokens: 4),
            messageId: "m1"
        )
        try expect(db.insertEvent(e1))
        try expect(!db.insertEvent(e1))
        let total = db.totalUsage(source: .claudeWork)
        try expect(total.inputTokens == 100)
        try expect(total.outputTokens == 50)
        try expect(total.cacheWrite1hTokens == 4, "1h cache split did not survive the round trip")
    }

    /// Cost and quota weighting both depend on which model produced the tokens, so the
    /// aggregate has to stay split by model rather than collapsing to one total.
    static func testUsageByModel() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("agamemnon-bymodel-\(UUID().uuidString).db").path
        let db = try AgamemnonDatabase(path: path)
        _ = db.insertEvent(UsageEvent(
            source: .claudeWork, sessionId: "s", project: "p", model: "claude-opus-4-8",
            timestamp: Date(), usage: TokenUsage(inputTokens: 1_000_000), messageId: "a"
        ))
        _ = db.insertEvent(UsageEvent(
            source: .claudeWork, sessionId: "s", project: "p", model: "claude-haiku-4-5",
            timestamp: Date(), usage: TokenUsage(inputTokens: 1_000_000), messageId: "b"
        ))
        let byModel = db.usageByModel(source: .claudeWork)
        try expect(byModel.count == 2, "expected 2 model buckets, got \(byModel.count)")

        let settings = AppSettings.default
        // Opus at $5/M plus Haiku at $1/M is $6, not 2M tokens at one blended rate.
        let cost = settings.estimateCost(byModel: byModel)
        try expect(abs(cost - 6.0) < 0.0001, "per-model cost wrong: \(cost)")
    }

    static func testLimitHitRoundTrip() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("agamemnon-limits-\(UUID().uuidString).db").path
        let db = try AgamemnonDatabase(path: path)
        let reset = Date().addingTimeInterval(3600)
        let hit = LimitHit(
            id: "claude-work-session-\(Int(reset.timeIntervalSince1970))",
            kind: .session, source: .claudeWork,
            hitAt: Date(), resetAt: reset, rawText: "You've hit your session limit"
        )
        try expect(db.insertLimitHits([hit]) == 1)
        try expect(db.insertLimitHits([hit]) == 0, "same limit hit must not be stored twice")
        let stored = db.limitHits(source: .claudeWork)
        try expect(stored.count == 1)
        try expect(stored[0].kind == .session)
        try expect(stored[0].isActive, "a hit resetting in the future should read as active")
    }

    static func testDailyCapAlert() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("agamemnon-alert-\(UUID().uuidString).db").path
        let db = try AgamemnonDatabase(path: path)
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

import Foundation

public enum AbuseEngine {
    /// Evaluate rules against the database and return newly fired alerts.
    public static func evaluate(db: WardenDatabase, thresholds: AlertThresholds) -> [AbuseAlert] {
        var fired: [AbuseAlert] = []
        fired.append(contentsOf: checkBurnSpike(db: db, thresholds: thresholds))
        fired.append(contentsOf: checkDailyCap(db: db, thresholds: thresholds))
        fired.append(contentsOf: checkCacheMiss(db: db, thresholds: thresholds))
        fired.append(contentsOf: checkLoop(db: db, thresholds: thresholds))
        for alert in fired {
            db.upsertAlert(alert)
        }
        return fired
    }

    // Burn spike: tokens/min over last 15 min > 3x trailing 7-day hourly average (as tokens/min)
    private static func checkBurnSpike(db: WardenDatabase, thresholds: AlertThresholds) -> [AbuseAlert] {
        let now = Date()
        let last15 = now.addingTimeInterval(-15 * 60)
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        var alerts: [AbuseAlert] = []

        for source in TokenSource.allCases {
            let recent = db.totalUsage(from: last15, to: now, source: source).totalTokens
            let ratePerMin = Double(recent) / 15.0
            let weekTotal = db.totalUsage(from: weekAgo, to: now, source: source).totalTokens
            // Trailing 7-day hourly average as tokens per minute
            let hours = 7.0 * 24.0
            let hourlyAvg = Double(weekTotal) / hours
            let avgPerMin = hourlyAvg / 60.0
            guard avgPerMin > 0 else { continue }
            let threshold = avgPerMin * thresholds.burnSpikeMultiplier
            if ratePerMin > threshold {
                if db.findRecentAlert(kind: .burnSpike, source: source, sessionId: nil, within: 30 * 60) != nil {
                    continue
                }
                alerts.append(AbuseAlert(
                    kind: .burnSpike,
                    source: source,
                    message: "\(source.displayName): burn \(String(format: "%.0f", ratePerMin)) tok/min exceeds \(String(format: "%.0f", threshold)) ( \(thresholds.burnSpikeMultiplier)x 7d avg)",
                    value: ratePerMin,
                    threshold: threshold
                ))
            }
        }
        return alerts
    }

    private static func checkDailyCap(db: WardenDatabase, thresholds: AlertThresholds) -> [AbuseAlert] {
        let start = Calendar.current.startOfDay(for: Date())
        var alerts: [AbuseAlert] = []
        for source in TokenSource.allCases {
            let total = db.totalUsage(from: start, to: Date(), source: source).totalTokens
            if total > thresholds.dailyCapTokens {
                if db.findRecentAlert(kind: .dailyCap, source: source, sessionId: nil, within: 12 * 3600) != nil {
                    continue
                }
                alerts.append(AbuseAlert(
                    kind: .dailyCap,
                    source: source,
                    message: "\(source.displayName): today \(TokenFormat.compact(total)) exceeds daily cap \(TokenFormat.compact(thresholds.dailyCapTokens))",
                    value: Double(total),
                    threshold: Double(thresholds.dailyCapTokens)
                ))
            }
        }
        return alerts
    }

    private static func checkCacheMiss(db: WardenDatabase, thresholds: AlertThresholds) -> [AbuseAlert] {
        var alerts: [AbuseAlert] = []
        let sessions = db.sessions(limit: 50)
        for session in sessions {
            let events = db.sessionEvents(sessionId: session.id)
                .filter { $0.source == session.source }
                .suffix(thresholds.cacheMissWindow)
            guard events.count >= max(5, thresholds.cacheMissWindow / 2) else { continue }
            let totalInput = events.reduce(0) { $0 + $1.usage.totalInput }
            let cacheRead = events.reduce(0) { $0 + $1.usage.cacheReadTokens }
            guard totalInput > 0 else { continue }
            let ratio = Double(cacheRead) / Double(totalInput)
            if ratio < thresholds.cacheMissRatioFloor {
                if db.findRecentAlert(kind: .cacheMissAnomaly, source: session.source, sessionId: session.id, within: 60 * 60) != nil {
                    continue
                }
                alerts.append(AbuseAlert(
                    kind: .cacheMissAnomaly,
                    source: session.source,
                    sessionId: session.id,
                    message: "\(session.source.displayName) session \(session.id.prefix(8)): cache_read ratio \(String(format: "%.0f%%", ratio * 100)) below \(String(format: "%.0f%%", thresholds.cacheMissRatioFloor * 100))",
                    value: ratio,
                    threshold: thresholds.cacheMissRatioFloor
                ))
            }
        }
        return alerts
    }

    private static func checkLoop(db: WardenDatabase, thresholds: AlertThresholds) -> [AbuseAlert] {
        var alerts: [AbuseAlert] = []
        let window = TimeInterval(thresholds.loopWindowSeconds)
        let sessions = db.sessions(limit: 50)
        for session in sessions {
            let events = db.sessionEvents(sessionId: session.id).filter { $0.source == session.source }
            guard events.count >= thresholds.loopMessageCount else { continue }
            // Sliding window: any span of N messages within window seconds
            let sorted = events.sorted { $0.timestamp < $1.timestamp }
            let n = thresholds.loopMessageCount
            for i in 0...(sorted.count - n) {
                let first = sorted[i]
                let last = sorted[i + n - 1]
                if last.timestamp.timeIntervalSince(first.timestamp) <= window {
                    if db.findRecentAlert(kind: .loopDetection, source: session.source, sessionId: session.id, within: window) != nil {
                        break
                    }
                    alerts.append(AbuseAlert(
                        kind: .loopDetection,
                        source: session.source,
                        sessionId: session.id,
                        message: "\(session.source.displayName) session \(session.id.prefix(8)): \(n) messages in \(Int(last.timestamp.timeIntervalSince(first.timestamp)))s (runaway agent)",
                        value: Double(n),
                        threshold: Double(thresholds.loopMessageCount)
                    ))
                    break
                }
            }
        }
        return alerts
    }
}

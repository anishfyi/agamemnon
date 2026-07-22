import SwiftUI
import AppKit
import AgamemnonCore

struct MenuBarLabel: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        let snap = appState.snapshot
        let blocked = snap.sourceStats.contains { $0.activeLimitHit != nil }
        let warning = snap.activeAlerts > 0 || snap.sourceStats.contains { $0.state != .ok }
        Label {
            Text(TokenFormat.currency(snap.todayCost))
                .monospacedDigit()
        } icon: {
            MenuBarIconView()
        }
        .labelStyle(.titleAndIcon)
        .foregroundStyle(blocked ? Color.red : (warning ? Color.orange : Color.primary))
    }
}

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let snap = appState.snapshot
        let settings = appState.settings

        Text("Today: \(TokenFormat.compact(snap.todayTotal.totalTokens)) tok · \(TokenFormat.currency(snap.todayCost))")
        Divider()

        ForEach(snap.sourceStats) { stats in
            Text(menuLine(for: stats))
        }

        Divider()

        // Only the tightest window is worth surfacing here; the full picture lives in
        // the dashboard.
        if let tightest = snap.sourceStats.filter({ $0.session.limit > 0 }).max(by: { $0.session.ratio < $1.session.ratio }) {
            Text("\(tightest.source.shortName) session: \(Int(tightest.session.ratio * 100))% used")
                .foregroundStyle(tightest.session.ratio >= 0.9 ? .red : .primary)
            if let reset = tightest.session.reset {
                Text("Resets \(reset, format: .dateTime.hour().minute())")
                    .foregroundStyle(.secondary)
            }
        }

        Text("Burn: \(TokenFormat.compact(Int(snap.burnPerMinute)))/min billable")
        Text("Alerts: \(snap.activeAlerts)")
            .foregroundStyle(snap.activeAlerts > 0 ? .orange : .primary)

        Divider()
        Button("Open Agamemnon") {
            openWindow(id: "admin")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button(settings.paused ? "Resume monitoring" : "Pause monitoring") {
            appState.togglePause()
        }
        Divider()
        Button("Quit Agamemnon") {
            NSApp.terminate(nil)
        }
    }

    private func menuLine(for stats: SourceSpendStats) -> String {
        if stats.activeLimitHit != nil {
            return "\(stats.source.shortName): limit reached"
        }
        if stats.tokensUnavailable {
            return "\(stats.source.shortName): activity only"
        }
        return "\(stats.source.shortName): \(TokenFormat.compact(stats.today.totalTokens)) · \(TokenFormat.currency(stats.todayCost))"
    }
}

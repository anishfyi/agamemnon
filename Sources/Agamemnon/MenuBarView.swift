import SwiftUI
import AppKit
import AgamemnonCore

struct MenuBarLabel: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        let total = appState.snapshot.todayTotal.totalTokens
        let warning = appState.snapshot.activeAlerts > 0
        Label {
            Text(TokenFormat.compact(total))
                .monospacedDigit()
        } icon: {
            MenuBarIconView()
        }
        .labelStyle(.titleAndIcon)
        .foregroundStyle(warning ? Color.orange : Color.primary)
    }
}

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let snap = appState.snapshot
        let settings = appState.settings

        Text("Today: \(TokenFormat.compact(snap.todayTotal.totalTokens))")
        Divider()

        ForEach(DashboardSource.allCases) { dashSource in
            if settings.toggles.isEnabled(dashSource.tokenSource) {
                let u = snap.todayBySource[dashSource.tokenSource] ?? .zero
                Text("\(dashSource.shortName): \(TokenFormat.compact(u.totalTokens))")
            }
        }

        if !snap.cursorNote.isEmpty {
            Text(snap.cursorNote)
                .foregroundStyle(.secondary)
        }

        Divider()
        Text("5h burn: \(TokenFormat.compact(snap.fiveHour.totalTokens))")
        Text("7d burn: \(TokenFormat.compact(snap.sevenDay.totalTokens))")
        Text("Rate: \(String(format: "%.0f", snap.burnPerMinute)) tok/min")
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
}

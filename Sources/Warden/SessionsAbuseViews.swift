import SwiftUI
import WardenCore

struct SessionsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedId: String?
    @State private var detailEvents: [UsageEvent] = []

    private var sessions: [SessionSummary] {
        appState.snapshot.sessions.sorted { $0.endTime > $1.endTime }
    }

    var body: some View {
        VStack(spacing: 0) {
            sessionTable
            if selectedId != nil {
                Divider()
                sessionDetail
            }
        }
        .padding(8)
    }

    private var sessionTable: some View {
        Table(sessions, selection: $selectedId) {
            TableColumn("Source") { (s: SessionSummary) in
                Text(s.source.displayName)
            }
            .width(min: 100, ideal: 130)

            TableColumn("Project") { (s: SessionSummary) in
                Text(s.project).lineLimit(1)
            }

            TableColumn("Start") { (s: SessionSummary) in
                Text(s.startTime, format: .dateTime.month().day().hour().minute())
            }
            .width(min: 110, ideal: 140)

            TableColumn("Duration") { (s: SessionSummary) in
                Text(TokenFormat.duration(s.duration))
            }
            .width(70)

            TableColumn("In") { (s: SessionSummary) in
                Text(TokenFormat.compact(s.usage.totalInput))
            }
            .width(70)

            TableColumn("Out") { (s: SessionSummary) in
                Text(TokenFormat.compact(s.usage.outputTokens))
            }
            .width(70)

            TableColumn("Cache") { (s: SessionSummary) in
                Text(TokenFormat.compact(s.usage.cacheReadTokens + s.usage.cacheCreationTokens))
            }
            .width(70)

            TableColumn("Msgs") { (s: SessionSummary) in
                Text("\(s.messageCount)")
            }
            .width(50)

            TableColumn("Est. cost") { (s: SessionSummary) in
                Text(TokenFormat.currency(appState.settings.estimateCost(usage: s.usage, model: s.model)))
            }
            .width(80)
        }
        .onChange(of: selectedId) { newId in
            if let newId {
                detailEvents = appState.db.sessionEvents(sessionId: newId)
            } else {
                detailEvents = []
            }
        }
    }

    private var sessionDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Session \(selectedId ?? "")")
                    .font(.headline)
                Spacer()
                Text("\(detailEvents.count) messages")
                    .foregroundStyle(.secondary)
                Button("Close") {
                    selectedId = nil
                    detailEvents = []
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            List(detailEvents) { event in
                HStack {
                    Text(event.timestamp, format: .dateTime.hour().minute().second())
                        .frame(width: 90, alignment: .leading)
                    Text(event.model)
                        .frame(width: 140, alignment: .leading)
                        .lineLimit(1)
                    Text("in \(TokenFormat.compact(event.usage.totalInput))")
                        .frame(width: 80)
                    Text("out \(TokenFormat.compact(event.usage.outputTokens))")
                        .frame(width: 80)
                    Text("cache \(TokenFormat.compact(event.usage.cacheReadTokens))")
                        .frame(width: 90)
                    Spacer()
                }
                .font(.system(.caption, design: .monospaced))
            }
            .frame(height: 180)
        }
    }
}

struct AbuseView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Text("Rules: burn spike (3x 7d avg), daily cap, cache-miss anomaly, loop detection. Thresholds are editable in Settings.")
                .foregroundStyle(.secondary)
                .font(.callout)

            if appState.snapshot.alerts.isEmpty {
                emptyState
            } else {
                alertList
            }
        }
        .padding(20)
    }

    private var header: some View {
        HStack {
            Text("Abuse alerts")
                .font(.title2.weight(.semibold))
            Spacer()
            Text("\(appState.snapshot.activeAlerts) active")
                .foregroundStyle(appState.snapshot.activeAlerts > 0 ? Color.orange : Color.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.shield")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No alerts")
                .font(.headline)
            Text("Monitoring is quiet.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var alertList: some View {
        List(appState.snapshot.alerts) { alert in
            HStack(alignment: .top) {
                Image(systemName: alert.acknowledged ? "checkmark.circle" : "exclamationmark.triangle.fill")
                    .foregroundStyle(alert.acknowledged ? Color.secondary : Color.orange)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(alert.kind.displayName)
                            .font(.headline)
                        Text(alert.source.displayName)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .cornerRadius(4)
                    }
                    Text(alert.message)
                        .font(.callout)
                    Text(alert.firedAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !alert.acknowledged {
                    Button("Acknowledge") {
                        appState.acknowledge(alert)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

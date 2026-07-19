import SwiftUI
import Charts
import WardenCore

enum AdminSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case sessions = "Sessions"
    case abuse = "Abuse"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "chart.xyaxis.line"
        case .sessions: return "list.bullet.rectangle"
        case .abuse: return "exclamationmark.triangle"
        case .settings: return "gearshape"
        }
    }
}

struct AdminPanelView: View {
    @EnvironmentObject var appState: AppState
    @State private var section: AdminSection = .overview

    var body: some View {
        NavigationSplitView {
            List(AdminSection.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
            .listStyle(.sidebar)
        } detail: {
            switch section {
            case .overview:
                OverviewView()
            case .sessions:
                SessionsView()
            case .abuse:
                AbuseView()
            case .settings:
                SettingsView()
            }
        }
        .navigationTitle("Warden")
    }
}

struct OverviewView: View {
    @EnvironmentObject var appState: AppState
    @State private var chartMode: ChartMode = .hourly

    enum ChartMode: String, CaseIterable {
        case hourly = "24h"
        case daily = "30d"
    }

    var body: some View {
        let snap = appState.snapshot
        let settings = appState.settings
        let todayCost = settings.estimateCost(usage: snap.todayTotal)
        let weekCost = settings.estimateCost(usage: snap.week)
        let allCost = settings.estimateCost(usage: snap.allTime)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !snap.cursorNote.isEmpty {
                    Text(snap.cursorNote)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12))
                        .cornerRadius(6)
                }

                HStack(spacing: 16) {
                    StatCard(title: "Today", value: TokenFormat.compact(snap.todayTotal.totalTokens), subtitle: TokenFormat.currency(todayCost))
                    StatCard(title: "This week", value: TokenFormat.compact(snap.week.totalTokens), subtitle: TokenFormat.currency(weekCost))
                    StatCard(title: "All-time", value: TokenFormat.compact(snap.allTime.totalTokens), subtitle: TokenFormat.currency(allCost))
                    StatCard(title: "Est. cost (today)", value: TokenFormat.currency(todayCost), subtitle: "\(String(format: "%.0f", snap.burnPerMinute)) tok/min")
                }

                Picker("Range", selection: $chartMode) {
                    ForEach(ChartMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)

                Group {
                    if chartMode == .hourly {
                        Chart(snap.hourly) { bucket in
                            BarMark(
                                x: .value("Hour", bucket.hour),
                                y: .value("Tokens", bucket.usage.totalTokens)
                            )
                            .foregroundStyle(by: .value("Source", bucket.source.displayName))
                        }
                        .chartForegroundStyleScale([
                            TokenSource.claudeWork.displayName: Color.blue,
                            TokenSource.claude.displayName: Color.cyan,
                            TokenSource.claudePersonal.displayName: Color.teal,
                            TokenSource.kimi.displayName: Color.purple,
                            TokenSource.cursor.displayName: Color.green,
                        ])
                        .frame(height: 280)
                        .chartXAxis {
                            AxisMarks(values: .stride(by: .hour, count: 4)) { _ in
                                AxisGridLine()
                                AxisValueLabel(format: .dateTime.hour())
                            }
                        }
                    } else {
                        Chart(snap.daily) { bucket in
                            AreaMark(
                                x: .value("Day", bucket.day),
                                y: .value("Tokens", bucket.usage.totalTokens)
                            )
                            .foregroundStyle(by: .value("Source", bucket.source.displayName))
                            .opacity(0.7)
                        }
                        .frame(height: 280)
                        .chartXAxis {
                            AxisMarks(values: .stride(by: .day, count: 5)) { _ in
                                AxisGridLine()
                                AxisValueLabel(format: .dateTime.month().day())
                            }
                        }
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Today by source")
                        .font(.headline)
                    ForEach(TokenSource.allCases) { source in
                        if settings.toggles.isEnabled(source) {
                            let u = snap.todayBySource[source] ?? .zero
                            HStack {
                                Text(source.displayName)
                                Spacer()
                                Text(TokenFormat.compact(u.totalTokens))
                                    .monospacedDigit()
                                Text(TokenFormat.currency(settings.estimateCost(usage: u)))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 70, alignment: .trailing)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
}

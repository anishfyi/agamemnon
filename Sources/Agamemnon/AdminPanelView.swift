import SwiftUI
import AgamemnonCore

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
        .navigationTitle("Agamemnon")
    }
}

struct OverviewView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        let snap = appState.snapshot
        let settings = appState.settings
        let todayCost = settings.estimateCost(usage: snap.todayTotal)
        let weekCost = settings.estimateCost(usage: snap.week)
        let allCost = settings.estimateCost(usage: snap.allTime)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    StatCard(title: "Today", value: TokenFormat.compact(snap.todayTotal.totalTokens), subtitle: TokenFormat.currency(todayCost))
                    StatCard(title: "This week", value: TokenFormat.compact(snap.week.totalTokens), subtitle: TokenFormat.currency(weekCost))
                    StatCard(title: "All-time", value: TokenFormat.compact(snap.allTime.totalTokens), subtitle: TokenFormat.currency(allCost))
                    StatCard(title: "Burn rate", value: "\(String(format: "%.0f", snap.burnPerMinute)) tok/min", subtitle: "last 15 min")
                }

                HStack {
                    Text("Live spend by source")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Text("Updated \(snap.lastPoll, format: .dateTime.hour().minute().second())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(snap.sourceStats) { stats in
                    SourceSpendCard(stats: stats, settings: settings)
                }

                if snap.sourceStats.isEmpty {
                    Text("No sources enabled. Turn on kimi, cursor, or claude-work in Settings.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                }
            }
            .padding(20)
        }
    }
}

struct SourceSpendCard: View {
    let stats: SourceSpendStats
    let settings: AppSettings

    private var limits: SourceWindowLimits {
        settings.sourceLimits.limits(for: stats.source)
    }

    private var stateColor: Color {
        switch stats.state {
        case .ok: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(stats.source.displayName)
                            .font(.headline)
                        Circle()
                            .fill(stateColor)
                            .frame(width: 8, height: 8)
                        Text(stats.state.rawValue)
                            .font(.caption)
                            .foregroundStyle(stateColor)
                    }
                    if stats.tokensUnavailable {
                        Text(stats.activityNote.isEmpty ? "cursor: activity only, tokens unavailable" : stats.activityNote)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(TokenFormat.currency(stats.estimatedCost))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                    Text("\(String(format: "%.0f", stats.burnPerMinute)) tok/min")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !stats.tokensUnavailable {
                HStack(spacing: 20) {
                    tokenColumn("Input", stats.today.inputTokens)
                    tokenColumn("Output", stats.today.outputTokens)
                    tokenColumn("Cache read", stats.today.cacheReadTokens)
                    tokenColumn("Cache write", stats.today.cacheCreationTokens)
                }
                .font(.caption)
            }

            UsageWindowBar(
                title: "5-hour window",
                used: stats.fiveHour.totalTokens,
                limit: limits.fiveHourTokens,
                ratio: stats.fiveHourRatio,
                resetLabel: TokenFormat.resetTime(stats.fiveHourReset)
            )

            UsageWindowBar(
                title: "Weekly window",
                used: stats.sevenDay.totalTokens,
                limit: limits.weeklyTokens,
                ratio: stats.weeklyRatio,
                resetLabel: TokenFormat.resetTime(stats.weeklyReset)
            )
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(stateColor.opacity(stats.state == .ok ? 0 : 0.35), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func tokenColumn(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(TokenFormat.compact(value))
                .monospacedDigit()
        }
    }
}

struct UsageWindowBar: View {
    let title: String
    let used: Int
    let limit: Int
    let ratio: Double
    let resetLabel: String

    private var barColor: Color {
        switch SpendState.from(ratio: ratio) {
        case .ok: return .accentColor
        case .warning: return .orange
        case .critical: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.medium))
                Spacer()
                Text("\(TokenFormat.compact(used)) / \(TokenFormat.compact(limit))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(barColor)
                        .frame(width: max(0, geo.size.width * min(1, ratio)))
                }
            }
            .frame(height: 8)
            Text(resetLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
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

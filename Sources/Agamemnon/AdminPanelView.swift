import SwiftUI
import AgamemnonCore

enum AdminSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case suggestions = "Suggestions"
    case sessions = "Sessions"
    case abuse = "Abuse"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "chart.xyaxis.line"
        case .suggestions: return "lightbulb"
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
            case .suggestions:
                SuggestionsView()
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

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    StatCard(
                        title: "Today",
                        value: TokenFormat.currency(snap.todayCost),
                        subtitle: "\(TokenFormat.compact(snap.todayTotal.totalTokens)) tokens"
                    )
                    StatCard(
                        title: "This week",
                        value: TokenFormat.currency(snap.weekCost),
                        subtitle: "\(TokenFormat.compact(snap.week.totalTokens)) tokens"
                    )
                    StatCard(
                        title: "All-time",
                        value: TokenFormat.currency(snap.allTimeCost),
                        subtitle: "\(TokenFormat.compact(snap.allTime.totalTokens)) tokens"
                    )
                    StatCard(
                        title: "Burn rate",
                        value: "\(TokenFormat.compact(Int(snap.burnPerMinute)))/min",
                        subtitle: "billable, last 15 min"
                    )
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
                    SourceSpendCard(stats: stats, cursorActivity: snap.cursorActivity)
                }

                if snap.sourceStats.isEmpty {
                    Text("No sources enabled. Turn on auto-detect, or enable a CLI in Settings.")
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
    let cursorActivity: CursorActivity

    private var stateColor: Color {
        switch stats.state {
        case .ok: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if stats.tokensUnavailable {
                cursorActivityRow
            } else {
                HStack(spacing: 20) {
                    tokenColumn("Input", stats.today.inputTokens)
                    tokenColumn("Output", stats.today.outputTokens)
                    tokenColumn("Cache read", stats.today.cacheReadTokens)
                    tokenColumn("Cache write 5m", stats.today.cacheWrite5mTokens)
                    tokenColumn("Cache write 1h", stats.today.cacheWrite1hTokens)
                }
                .font(.caption)

                if stats.session.limit > 0 || stats.weekly.limit > 0 {
                    UsageWindowBar(title: "Session window", window: stats.session)
                    UsageWindowBar(title: "Weekly window", window: stats.weekly)
                } else {
                    Text("No subscription window applies to this source. Tracking spend only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(stateColor.opacity(stats.state == .ok ? 0 : 0.35), lineWidth: 1)
        )
    }

    private var header: some View {
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
                if let hit = stats.activeLimitHit {
                    Text(limitBanner(hit))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.red)
                }
                if stats.tokensUnavailable {
                    Text(stats.activityNote)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(TokenFormat.currency(stats.todayCost))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text("\(TokenFormat.compact(Int(stats.burnPerMinute)))/min billable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func limitBanner(_ hit: LimitHit) -> String {
        guard let reset = hit.resetAt else { return "\(hit.kind.displayName) reached" }
        let f = DateFormatter()
        f.timeStyle = .short
        return "\(hit.kind.displayName) reached, resets \(f.string(from: reset))"
    }

    @ViewBuilder
    private var cursorActivityRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 20) {
                tokenColumn("Requests", cursorActivity.totalRequests)
                tokenColumn("Lines added", cursorActivity.linesAdded)
                tokenColumn("Lines removed", cursorActivity.linesRemoved)
                tokenColumn("Conversations", cursorActivity.conversationCount)
            }
            .font(.caption)

            if !cursorActivity.topModels.isEmpty {
                HStack(spacing: 12) {
                    ForEach(cursorActivity.topModels, id: \.model) { entry in
                        Text("\(entry.model) \(entry.requests)")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12))
                            .cornerRadius(4)
                    }
                }
            }
        }
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
    let window: WindowStats

    private var barColor: Color {
        switch SpendState.from(ratio: window.ratio) {
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
                // Naming the provenance is the whole point: an invented default must
                // never read as a real quota.
                Text(window.origin.label)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(originColor.opacity(0.15))
                    .foregroundStyle(originColor)
                    .cornerRadius(3)
                Spacer()
                Text("\(TokenFormat.compact(Int(window.billable))) / \(TokenFormat.compact(Int(window.limit))) billable")
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
                        .frame(width: max(0, geo.size.width * min(1, window.ratio)))
                }
            }
            .frame(height: 8)
            HStack {
                Text(TokenFormat.resetTime(window.reset))
                Spacer()
                Text(TokenFormat.currency(window.cost))
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var originColor: Color {
        switch window.origin {
        case .measured: return .green
        case .userSet: return .accentColor
        case .planEstimate: return .orange
        case .none: return .secondary
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

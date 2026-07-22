import SwiftUI
import AgamemnonCore

struct SuggestionsView: View {
    @EnvironmentObject var appState: AppState
    @State private var suggestions: [Suggestion] = []
    @State private var showKnowledgeBase = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if suggestions.isEmpty {
                    emptyState
                } else {
                    ForEach(suggestions) { s in
                        SuggestionCard(suggestion: s)
                    }
                }

                DisclosureGroup("How token accounting works", isExpanded: $showKnowledgeBase) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(KnowledgeBase.entries) { entry in
                            KnowledgeCard(entry: entry)
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.title3.weight(.semibold))
                .padding(.top, 8)
            }
            .padding(20)
        }
        .onAppear(perform: refresh)
        // Two-parameter onChange needs macOS 14; the deployment target is 13.
        .onChange(of: appState.snapshot.lastPoll) { _ in refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Suggestions")
                    .font(.title3.weight(.semibold))
                Spacer()
                let total = suggestions.reduce(0) { $0 + $1.weeklySaving }
                if total > 0.01 {
                    Text("Up to \(TokenFormat.currency(total))/week addressable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Derived locally from the last seven days of collected usage. No network calls, no model involved.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Nothing worth flagging yet.")
                .foregroundStyle(.secondary)
            Text("Findings appear once there is a week of usage to compare against.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func refresh() {
        let db = appState.db
        let settings = appState.settings
        let snapshot = appState.snapshot
        // Runs off the main thread: it walks the full session history.
        DispatchQueue.global(qos: .userInitiated).async {
            let results = SuggestionEngine.analyze(db: db, settings: settings, snapshot: snapshot)
            DispatchQueue.main.async { suggestions = results }
        }
    }
}

struct SuggestionCard: View {
    let suggestion: Suggestion

    private var severityColor: Color {
        switch suggestion.severity {
        case .high: return .red
        case .moderate: return .orange
        case .info: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(suggestion.title)
                    .font(.headline)
                Text(suggestion.severity.label)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(severityColor.opacity(0.15))
                    .foregroundStyle(severityColor)
                    .cornerRadius(4)
                if let source = suggestion.source {
                    Text(source.shortName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(4)
                }
                Spacer()
                if suggestion.weeklySaving > 0.01 {
                    Text("~\(TokenFormat.currency(suggestion.weeklySaving))/week")
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                }
            }

            Text(suggestion.finding)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text(suggestion.action)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let id = suggestion.mechanism, let entry = KnowledgeBase.entry(id) {
                HStack(spacing: 6) {
                    Image(systemName: "book")
                        .font(.caption2)
                    Text(entry.title)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(severityColor.opacity(suggestion.severity == .info ? 0 : 0.3), lineWidth: 1)
        )
    }
}

struct KnowledgeCard: View {
    let entry: KnowledgeEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.title)
                    .font(.subheadline.weight(.semibold))
                Text(entry.provider)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(3)
            }
            Text(entry.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(entry.practice)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
}

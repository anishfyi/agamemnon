import SwiftUI
import AgamemnonCore

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var pricingText: String = ""
    @State private var pricingError: String?

    var body: some View {
        Form {
            Section("Sources") {
                Toggle("Claude Code (claude-work)", isOn: $appState.settings.toggles.claudeWork)
                pathField("Projects path", text: $appState.settings.paths.claudeWorkProjects)

                Toggle("Claude Code (~/.claude)", isOn: $appState.settings.toggles.claude)
                pathField("Projects path", text: $appState.settings.paths.claudeProjects)

                Toggle("Claude Code (personal)", isOn: $appState.settings.toggles.claudePersonal)
                pathField("Projects path", text: $appState.settings.paths.claudePersonalProjects)

                Toggle("Kimi Code CLI", isOn: $appState.settings.toggles.kimi)
                pathField("Sessions path", text: $appState.settings.paths.kimiSessions)

                Toggle("Cursor CLI", isOn: $appState.settings.toggles.cursor)
                pathField("Tracking DB", text: $appState.settings.paths.cursorTrackingDB)
                pathField("Debug logs", text: $appState.settings.paths.cursorDebugLogs)
                pathField("Chats", text: $appState.settings.paths.cursorChats)
            }

            Section("Source limits") {
                sourceLimitFields("Kimi", limits: $appState.settings.sourceLimits.kimi)
                sourceLimitFields("Cursor CLI", limits: $appState.settings.sourceLimits.cursor)
                sourceLimitFields("Claude-work", limits: $appState.settings.sourceLimits.claudeWork)
            }

            Section("Alert thresholds") {
                LabeledContent("Burn spike multiplier") {
                    TextField("", value: $appState.settings.thresholds.burnSpikeMultiplier, format: .number)
                        .frame(width: 80)
                }
                LabeledContent("Daily cap (tokens)") {
                    TextField("", value: $appState.settings.thresholds.dailyCapTokens, format: .number)
                        .frame(width: 120)
                }
                LabeledContent("Cache-miss ratio floor") {
                    TextField("", value: $appState.settings.thresholds.cacheMissRatioFloor, format: .number)
                        .frame(width: 80)
                }
                LabeledContent("Cache-miss window (msgs)") {
                    TextField("", value: $appState.settings.thresholds.cacheMissWindow, format: .number)
                        .frame(width: 80)
                }
                LabeledContent("Loop message count") {
                    TextField("", value: $appState.settings.thresholds.loopMessageCount, format: .number)
                        .frame(width: 80)
                }
                LabeledContent("Loop window (seconds)") {
                    TextField("", value: $appState.settings.thresholds.loopWindowSeconds, format: .number)
                        .frame(width: 80)
                }
            }

            Section("Pricing (USD per 1M tokens, JSON)") {
                TextEditor(text: $pricingText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 140)
                if let pricingError {
                    Text(pricingError).foregroundStyle(.red).font(.caption)
                }
                Button("Apply pricing JSON") {
                    applyPricing()
                }
            }

            Section("Monitoring") {
                LabeledContent("Poll interval (seconds)") {
                    TextField("", value: $appState.settings.pollIntervalSeconds, format: .number)
                        .frame(width: 80)
                }
                Toggle("Launch at login", isOn: $appState.settings.launchAtLogin)
                Toggle("Paused", isOn: $appState.settings.paused)
            }

            Section {
                Button("Save settings") {
                    applyPricing()
                    appState.saveSettings()
                }
                .keyboardShortcut("s", modifiers: .command)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            pricingText = appState.settings.pricingJSON
        }
    }

    @ViewBuilder
    private func pathField(_ title: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 360)
        }
    }

    private func applyPricing() {
        guard let data = pricingText.data(using: .utf8) else {
            pricingError = "Invalid UTF-8"
            return
        }
        do {
            let decoded = try JSONDecoder().decode([ModelPricing].self, from: data)
            appState.settings.pricing = decoded
            pricingError = nil
        } catch {
            pricingError = "JSON parse error: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private func sourceLimitFields(_ name: String, limits: Binding<SourceWindowLimits>) -> some View {
        Group {
            LabeledContent("\(name) 5-hour limit (tokens)") {
                TextField("", value: limits.fiveHourTokens, format: .number)
                    .frame(width: 120)
            }
            LabeledContent("\(name) weekly limit (tokens)") {
                TextField("", value: limits.weeklyTokens, format: .number)
                    .frame(width: 120)
            }
        }
    }
}

import SwiftUI
import AgamemnonCore

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var pricingText: String = ""
    @State private var pricingError: String?

    var body: some View {
        Form {
            Section("Sources") {
                Toggle("Auto-detect installed CLIs", isOn: $appState.settings.toggles.autoDetect)
                Text("When on, any CLI whose data directory exists is monitored without being listed here first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(TokenSource.dashboardOrder) { source in
                    sourceRow(source)
                }
            }

            Section("Window limits") {
                Text("Limits are in input-token-equivalents: cache reads count at 0.1x and output at its price ratio, matching how spend is actually billed. Leave a field at 0 to use the measured or plan-derived value.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(TokenSource.dashboardOrder.filter { $0.hasSubscriptionWindows }) { source in
                    limitFields(for: source)
                }
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
                Text("Each entry may set cacheReadMultiplier, cacheWrite5mMultiplier and cacheWrite1hMultiplier. Defaults are 0.1x, 1.25x and 2x of the input rate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $pricingText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 140)
                if let pricingError {
                    Text(pricingError).foregroundStyle(.red).font(.caption)
                }
                HStack {
                    Button("Apply pricing JSON") { applyPricing() }
                    Button("Reset to published prices") {
                        appState.settings.pricing = AppSettings.defaultPricing
                        pricingText = appState.settings.pricingJSON
                        pricingError = nil
                    }
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

    // MARK: - Rows

    @ViewBuilder
    private func sourceRow(_ source: TokenSource) -> some View {
        let detected = appState.settings.paths.exists(source)
        VStack(alignment: .leading, spacing: 4) {
            Toggle(source.displayName, isOn: enabledBinding(source))
            HStack(spacing: 6) {
                Circle()
                    .fill(detected ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text(detected ? "data directory found" : "not installed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let plan = appState.snapshot.detectedPlans[source], source.isClaudeFamily {
                    Text("· \(plan.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            pathField("Path", text: pathBinding(source))
        }
    }

    @ViewBuilder
    private func limitFields(for source: TokenSource) -> some View {
        let stats = appState.snapshot.sourceStats.first { $0.source == source }
        VStack(alignment: .leading, spacing: 4) {
            Text(source.displayName).font(.subheadline.weight(.medium))
            if let stats {
                Text("Currently using \(stats.session.origin.label) limits: session \(TokenFormat.compact(Int(stats.session.limit))), weekly \(TokenFormat.compact(Int(stats.weekly.limit))).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Session override") {
                TextField("0 = auto", value: limitBinding(source, session: true), format: .number)
                    .frame(width: 120)
            }
            LabeledContent("Weekly override") {
                TextField("0 = auto", value: limitBinding(source, session: false), format: .number)
                    .frame(width: 120)
            }
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

    // MARK: - Bindings

    private func enabledBinding(_ source: TokenSource) -> Binding<Bool> {
        Binding(
            get: { appState.settings.toggles.isEnabled(source, paths: appState.settings.paths) },
            set: { appState.settings.toggles.set($0, for: source) }
        )
    }

    private func pathBinding(_ source: TokenSource) -> Binding<String> {
        Binding(
            get: { appState.settings.paths.root(for: source) },
            set: { appState.settings.paths.setRoot($0, for: source) }
        )
    }

    private func limitBinding(_ source: TokenSource, session: Bool) -> Binding<Double> {
        Binding(
            get: {
                let l = appState.settings.sourceLimits.limits(for: source)
                return session ? l.sessionBillable : l.weeklyBillable
            },
            set: { newValue in
                var l = appState.settings.sourceLimits.limits(for: source)
                if session { l.sessionBillable = newValue } else { l.weeklyBillable = newValue }
                appState.settings.sourceLimits.setLimits(l, for: source)
            }
        )
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
}

import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement
import AgamemnonCore

@main
struct AgamemnonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            MenuBarLabel()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.menu)

        Window("Agamemnon", id: "admin") {
            AdminPanelView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 980, height: 680)
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var snapshot: MonitorSnapshot = .empty
    @Published var settings: AppSettings
    @Published var showAdmin = false

    let engine: MonitorEngine
    let db: AgamemnonDatabase

    init() {
        let database: AgamemnonDatabase
        do {
            database = try AgamemnonDatabase()
        } catch {
            // Fallback to temp db so the app still launches
            database = try! AgamemnonDatabase(path: NSTemporaryDirectory() + "agamemnon-fallback.db")
        }
        self.db = database
        let loaded = SettingsStore.load()
        self.settings = loaded
        self.engine = MonitorEngine(db: database, settings: loaded)
        engine.onUpdate = { [weak self] snap in
            Task { @MainActor in
                self?.snapshot = snap
            }
        }
        engine.onNewAlerts = { alerts in
            for alert in alerts {
                Self.notify(alert)
            }
        }
        requestNotificationPermission()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.engine.start()
        }
    }

    func openAdmin() {
        NSApp.setActivationPolicy(.accessory)
        if let url = URL(string: "agamemnon://admin") {
            _ = url
        }
        // Open via Window environment; use NSApp windows
        for window in NSApp.windows where window.title == "Agamemnon" {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // Fallback: open via notification to openWindow
        NotificationCenter.default.post(name: .agamemnonOpenAdmin, object: nil)
    }

    func saveSettings() {
        engine.updateSettings(settings)
        applyLaunchAtLogin()
    }

    func togglePause() {
        engine.togglePause()
        settings = engine.currentSettings()
    }

    func acknowledge(_ alert: AbuseAlert) {
        engine.acknowledge(alertId: alert.id)
    }

    private func applyLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            do {
                if settings.launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Ignore registration failures on unsigned builds
            }
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func notify(_ alert: AbuseAlert) {
        let content = UNMutableNotificationContent()
        content.title = "Agamemnon: \(alert.kind.displayName)"
        content.body = alert.message
        content.sound = .default
        let req = UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

extension Notification.Name {
    static let agamemnonOpenAdmin = Notification.Name("agamemnonOpenAdmin")
}

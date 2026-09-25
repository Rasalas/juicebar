import SwiftUI
import AppKit
import UserNotifications
import JuicebarCore

@main
enum JuicebarEntry {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--verify-activity-persistence") {
            _ = NSApplication.shared
            do { try PreviewRenderer.verifyActivityPersistence() }
            catch { fputs("Activity persistence failed: \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--verify-tray-layout") {
            _ = NSApplication.shared
            do { try PreviewRenderer.verifyTrayLayout() }
            catch { fputs("Tray layout failed: \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--render-previews") {
            _ = NSApplication.shared
            do { try PreviewRenderer.render() } catch { fputs("Preview failed: \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--diagnose-activity") {
            Task.detached(priority: .utility) {
                do {
                    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Juicebar")
                    let start = Date()
                    let hosts = CommandLine.arguments.filter { $0.hasPrefix("--ssh=") }.map { String($0.dropFirst(6)) }
                    let result = try ActivityImport.read(roots: ActivityLogs.defaultRoots(accounts: []), databasePath: nil, hosts: hosts, directory: directory)
                    let report = result.0
                    for source in ActivitySource.allCases {
                        let days = report.days.filter { $0.source == source }
                        print("\(source.name): \(days.count) days, \(days.reduce(0) { $0 + $1.responses }) responses, \(Int(days.reduce(0) { $0 + $1.tokens })) tokens")
                    }
                    print("API equivalent: \(report.days.reduce(0) { $0 + $1.apiCost }) USD; oldest Claude day: \(report.days.filter { $0.source == .claude }.map(\.day).min()?.description ?? "none")")
                    print("Import complete: \(Int(Date().timeIntervalSince(start)))s; \((report.warnings + report.notices).joined(separator: "; "))")
                    fflush(stdout); exit(0)
                } catch { print("Activity import: \(error.localizedDescription)"); fflush(stdout); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--diagnose") {
            Task {
            let registry = ProviderRegistry()
            for kind in [ProviderKind.codex, .claude, .opencodeGo] {
                do {
                    let snapshot = try await registry.provider(for: kind).read(configuration: AccountConfiguration(id: "diagnostic-\(kind.rawValue)", provider: kind), includeHistory: true)
                    print("\(kind.name): OK · \(snapshot.windows.count) Limits · Resetdaten \(snapshot.benefitsChecked ? tr("verfügbar") : tr("unbekannt"))")
                    for window in snapshot.windows { print("  \(window.title): \(Int(window.usedPercent)) % · Reset \(window.resetsAt == nil ? tr("unbekannt") : "vorhanden")") }
                } catch { print("\(kind.name): \(error.localizedDescription)") }
                fflush(stdout)
            }
                do {
                    let report = try OpenCodeHistory.read()
                    print("OpenCode lokal: OK · \(report.messageCount) Nachrichten · \(report.days.count) Tage")
                } catch { print("OpenCode lokal: \(error.localizedDescription)") }
                exit(0)
            }
            dispatchMain()
        }
        JuicebarApplication.main()
    }
}

@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DashboardWindow.shared.show(store: AppStore.shared)
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await AppStore.shared.shutDown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        AppStore.shared.start()
        DashboardWindow.shared.show(store: AppStore.shared)
        AppUpdates.shared.start()
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

struct JuicebarApplication: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) var delegate
    @StateObject private var store = AppStore.shared
    var body: some Scene {
        MenuBarExtra {
            TrayView(store: store)
        } label: {
            TrayLabel(store: store)
        }
        .menuBarExtraStyle(.window)

    }
}

struct TrayLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: AppStore
    private var detail: String {
        let values = store.trayMeters.map { meter in
            guard let window = meter.window else { return tr("{0}: kein aktuelles Limit verfügbar", meter.account.displayName) }
            if meter.expired { return tr("{0} · {1}: Reset erreicht, neuer Stand ausstehend", meter.account.displayName, window.title) }
            return tr("{0} · {1}: {2} % {3}{4}", meter.account.displayName, window.title, Int(store.settings.displayMode.value(used: window.usedPercent).rounded()), store.settings.displayMode.label.lowercased(), meter.fresh ? "" : tr(" · letzter Stand"))
        }
        return (values.isEmpty ? tr("Juicebar · Keine Limits für die Menüleiste ausgewählt") : values.joined(separator: "\n")) + (store.expiringCount > 0 ? tr("\nReset-Frist läuft bald ab") : "")
    }
    var body: some View {
        Image(nsImage: MenuLimitImage.make(meters: store.trayMeters, mode: store.settings.displayMode, dark: colorScheme == .dark, expiring: store.expiringCount > 0))
            .help(detail).accessibilityLabel(detail)
    }
}

@MainActor final class DashboardWindow: NSObject, NSWindowDelegate {
    static let shared = DashboardWindow()
    private var window: NSWindow?
    func show(store: AppStore) {
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let value = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            value.title = "Juicebar"; value.titleVisibility = .hidden; value.titlebarAppearsTransparent = true
            value.isReleasedWhenClosed = false; value.minSize = NSSize(width: 840, height: 620)
            value.delegate = self
            value.contentView = NSHostingView(rootView: DashboardView(store: store))
            value.center(); window = value
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { NSApp.setActivationPolicy(.accessory) }
}

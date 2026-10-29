import SwiftUI
import AppKit
import UserNotifications
import JuicebarCore

@main
enum JuicebarEntry {
    @MainActor static func main() {
        // Writing to an exited CLI or ssh must throw EPIPE instead of terminating the app.
        signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments.contains("--verify-activity-persistence") {
            _ = NSApplication.shared
            Task {
                do { try await PreviewRenderer.verifyActivityPersistence(); exit(0) }
                catch { fputs("Activity persistence failed: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--verify-quota-accessibility") {
            _ = NSApplication.shared
            let result = QuotaAccessibilityVerification.run(interactive: CommandLine.arguments.contains("--interactive"))
            print(result.message)
            exit(result.exitCode(strict: CommandLine.arguments.contains("--strict")))
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
                    for window in snapshot.windows { print("  \(window.title): \(QuotaNumbers.integerText(window.usedPercent)) % · Reset \(window.resetsAt == nil ? tr("unbekannt") : "vorhanden")") }
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
        // A login launch stays in the menu bar; a first run or an explicit open shows the dashboard.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let loginLaunch = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        let firstRun = !UserDefaults.standard.bool(forKey: "dashboardShownOnce")
        if firstRun || !loginLaunch { DashboardWindow.shared.show(store: AppStore.shared) }
        if !AppStore.shared.isDemo { UserDefaults.standard.set(true, forKey: "dashboardShownOnce") }
        AppUpdates.shared.start()
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

struct JuicebarApplication: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) var delegate
    private let store = AppStore.shared
    var body: some Scene {
        MenuBarExtra {
            TrayView(store: store)
        } label: {
            TrayLabel(store: store)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(tr("Einstellungen …")) { DashboardWindow.shared.show(store: store, page: .settings) }.keyboardShortcut(",")
            }
        }
    }
}

struct TrayLabel: View {
    // Read only so a new image is drawn when the appearance changes; colours resolve at draw time.
    @Environment(\.colorScheme) private var colorScheme
    let store: AppStore
    private func statuses(_ meters: [TrayMeter]) -> [QuotaStatus] {
        meters.map { meter in
            guard let window = meter.window, !meter.expired, let snapshot = store.snapshots[meter.account.id] else { return .unavailable }
            return QuotaStatus.assess(window: window, snapshot: snapshot, history: store.history[meter.account.id] ?? [],
                                      now: store.now, hasFailure: store.failures[meter.account.id] != nil)
        }
    }
    private func detail(_ meters: [TrayMeter], _ statuses: [QuotaStatus]) -> String {
        let values = zip(meters, statuses).map { meter, status in
            guard let window = meter.window else { return tr("{0}: kein aktuelles Limit verfügbar", meter.account.displayName) }
            if meter.expired { return tr("{0} · {1}: Reset erreicht, neuer Stand ausstehend", meter.account.displayName, window.title) }
            let alert = status.title(now: store.now)
            return tr("{0} · {1}: {2} % {3}{4}", meter.account.displayName, window.title, QuotaNumbers.integerText(store.settings.displayMode.value(used: window.usedPercent).rounded()), store.settings.displayMode.label.lowercased(), meter.fresh ? "" : tr(" · letzter Stand"))
                + (alert.isEmpty ? "" : " · \(alert)")
        }
        return (values.isEmpty ? tr("Juicebars · Keine Limits für die Menüleiste ausgewählt") : values.joined(separator: "\n")) + (store.expiringCount > 0 ? tr("\nReset-Gutschrift läuft bald ab") : "")
    }
    var body: some View {
        let meters = store.trayMeters, statuses = statuses(meters), detail = detail(meters, statuses)
        let _ = colorScheme
        Image(nsImage: MenuLimitImage.make(meters: meters, statuses: statuses, mode: store.settings.displayMode,
                                           expiring: store.expiringCount > 0, showsValue: store.settings.menuStyle == .focused))
            .help(detail).accessibilityLabel(detail)
    }
}

@MainActor final class DashboardWindow: NSObject, NSWindowDelegate {
    static let shared = DashboardWindow()
    private var window: NSWindow?
    func show(store: AppStore, page: Page? = nil, editing accountID: String? = nil) {
        if let page { DashboardNavigation.shared.page = page }
        DashboardNavigation.shared.editAccountID = accountID
        NSApp.setActivationPolicy(.regular)
        let window = self.window ?? {
            let value = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            value.title = "Juicebars"; value.titleVisibility = .hidden; value.titlebarAppearsTransparent = true
            value.isReleasedWhenClosed = false; value.minSize = NSSize(width: 840, height: 620)
            value.delegate = self
            value.center(); self.window = value
            return value
        }()
        if !(window.contentView is NSHostingView<DashboardView>) { window.contentView = NSHostingView(rootView: DashboardView(store: store)) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // A hidden dashboard would keep observing the store; rebuild it on the next show.
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window, !window.isVisible else { return }
            window.contentView = NSView()
        }
    }
}

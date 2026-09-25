import SwiftUI
import ServiceManagement
import JuicebarCore

struct PreferencesView: View {
    @ObservedObject var store: AppStore
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeading(title: "So läuft Juicebar.", subtitle: "Unauffällig in der Menüleiste. Du bestimmst, was dort zählt.")
            Panel {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Darstellung").font(.headline)
                    JuiceSegments(title: "Balken & Zahlen", selection: Binding(get: { store.settings.displayMode }, set: { store.settings.quotaDisplay = $0 }), options: QuotaDisplay.allCases.map { ($0.label, $0) })
                    Text("Standard: Der Vorrat läuft leer. Balken und Menüleistenlinien lassen sich alternativ auf verbraucht umstellen.").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Text("Menüleiste").font(.headline)
                    JuiceMenuPicker(title: "Anzeige", selection: Binding(get: { store.settings.menuStyle }, set: { store.settings.trayStyle = $0 }), options: TrayStyle.allCases.map { ($0.label, $0) })
                    if store.settings.menuStyle == .lines {
                        Toggle("Neue Limits automatisch in der Menüleiste anzeigen", isOn: Binding(
                            get: { store.settings.showsNewTrayLimits },
                            set: { store.settings.setNewTrayLimitsVisible($0, accounts: store.accounts, snapshots: store.snapshots) }
                        ))
                        Text("Die Auswahl unten bleibt dabei erhalten. Die Übersicht zeigt weiterhin alle erkannten Limits.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(QuotaOrder.accounts(store.accounts.filter(\.enabled))) { account in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(account.displayName).font(.subheadline.weight(.semibold))
                                if let snapshot = store.snapshots[account.id], !snapshot.windows.isEmpty {
                                    ForEach(QuotaOrder.visibleWindows(snapshot.windows, provider: account.provider)) { window in
                                        Toggle(window.title, isOn: Binding(
                                            get: { store.settings.showsTrayLimit(account: account, windowID: window.id) },
                                            set: { store.settings.setTrayLimit(accountID: account.id, windowID: window.id, visible: $0) }
                                        ))
                                    }
                                } else {
                                    Text("Limits erscheinen nach der ersten erfolgreichen Abfrage.").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if store.settings.menuStyle == .focused {
                        JuiceMenuPicker(title: "Angezeigtes Konto", selection: Binding(get: { store.settings.selectedTrayAccount ?? "" }, set: { store.settings.selectedTrayAccount = $0.isEmpty ? nil : $0; store.settings.selectedTrayWindow = nil }), options: [("Höchster aktueller Verbrauch", "")] + store.accounts.filter(\.enabled).map { ($0.displayName, $0.id) })
                        if let id = store.settings.selectedTrayAccount, let snapshot = store.snapshots[id] {
                            JuiceMenuPicker(title: "Kontingent", selection: Binding(get: { store.settings.selectedTrayWindow ?? "" }, set: { store.settings.selectedTrayWindow = $0.isEmpty ? nil : $0 }), options: [("Automatisch", "")] + QuotaOrder.visibleWindows(snapshot.windows, provider: store.accounts.first { $0.id == id }?.provider ?? .codex).map { ($0.title, $0.id) })
                        }
                    }
                    Text("Eine farbige Linie pro Limit. Reihenfolge: Codex, Claude, OpenCode, weitere Konten. Je Konto: Kurzlimit, Woche, Monat, zusätzliche Modelllimits. Größere Abstände trennen Konten. Gestrichelt bedeutet unbekannt oder Reset erreicht; gedimmt mit Punkt bedeutet letzter Stand. Details erscheinen beim Klick.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Hintergrund").font(.headline)
                    JuiceMenuPicker(title: "Aktualisieren", selection: $store.settings.refreshSeconds, options: [("Jede Minute", 60.0), ("Alle 90 Sekunden", 90.0), ("Alle 3 Minuten", 180.0), ("Alle 5 Minuten", 300.0)])
                    Text("API-Kosten höchstens alle 5 Minuten. Bei Fehlern wartet Juicebar länger; beim Ruhezustand stoppt die laufende Abfrage.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Beim Anmelden starten", isOn: $loginEnabled).disabled(store.isDemo).onChange(of: loginEnabled) { _, enabled in
                        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginError = nil }
                        catch { loginError = error.localizedDescription }
                    }
                    if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
                    Toggle("Automatische Abfragen pausieren", isOn: $store.isPaused)
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Lokal gespeichert", systemImage: "internaldrive").font(.headline)
                    Text("Juicebar speichert Verbrauchsmessungen, Einstellungen und zugestellte Warnungen. Keine Gesprächsinhalte, keine Telemetrie. Zugangsschlüssel liegen separat im Schlüsselbund.").font(.callout).foregroundStyle(.secondary)
                    Button("Verlaufsordner öffnen") {
                        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Juicebar")
                        NSWorkspace.shared.open(url)
                    }.disabled(store.isDemo)
                    Divider()
                    HStack { Text("macOS 14+").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Beenden") { store.stop(); NSApp.terminate(nil) } }
                }
            }
            AboutView()
        }.onChange(of: store.settings) { _, _ in store.persistSettings() }
    }
}

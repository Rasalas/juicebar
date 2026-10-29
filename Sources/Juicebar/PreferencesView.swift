import SwiftUI
import ServiceManagement
import JuicebarCore

struct PreferencesView: View {
    @Bindable var store: AppStore
    @AppStorage("appLanguage") private var appLanguage = "system"
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeading(title: tr("So läuft Juicebars."), subtitle: tr("Unauffällig in der Menüleiste. Du bestimmst, was dort zählt."))
            Panel {
                VStack(alignment: .leading, spacing: 20) {
                    Text(tr("Darstellung")).font(.headline)
                    JuiceMenuPicker(title: tr("Sprache"), selection: $appLanguage, options: [(tr("Systemsprache"), "system"), ("Deutsch", "de"), ("English", "en")])
                    if appLanguage != Localization.selectionAtLaunch && Localization.resolve(appLanguage) != Localization.language {
                        HStack {
                            Text(tr("Die neue Sprache gilt nach einem Neustart.")).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(tr("Jetzt neu starten")) { relaunch() }.buttonStyle(JuiceButtonStyle(prominent: true))
                                .disabled(store.isDemo || !Bundle.main.bundlePath.hasSuffix(".app"))
                        }
                    }
                    Divider()
                    JuiceSegments(title: tr("Balken & Zahlen"), selection: Binding(get: { store.settings.displayMode }, set: { value in store.editSettings { $0.quotaDisplay = value } }), options: QuotaDisplay.allCases.map { ($0.label, $0) }, showsTitle: true)
                    Text(tr("Standard: Der Vorrat läuft leer. Balken und Menüleistenlinien lassen sich alternativ auf verbraucht umstellen.")).font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Text(tr("Menüleiste")).font(.headline)
                    JuiceMenuPicker(title: tr("Anzeige"), selection: Binding(get: { store.settings.menuStyle }, set: { value in store.editSettings { $0.trayStyle = value } }), options: TrayStyle.allCases.map { ($0.label, $0) })
                    if store.settings.menuStyle == .lines {
                        Toggle(tr("Neue Limits automatisch in der Menüleiste anzeigen"), isOn: Binding(
                            get: { store.settings.showsNewTrayLimits },
                            set: { value in store.editSettings { $0.setNewTrayLimitsVisible(value, accounts: store.accounts, snapshots: store.snapshots) } }
                        ))
                        Text(tr("Die Auswahl unten bleibt dabei erhalten. Die Übersicht zeigt weiterhin alle erkannten Limits."))
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(QuotaOrder.accounts(store.accounts.filter(\.enabled))) { account in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(account.displayName).font(.subheadline.weight(.semibold))
                                if let snapshot = store.snapshots[account.id], !snapshot.windows.isEmpty {
                                    ForEach(QuotaOrder.visibleWindows(snapshot.windows, provider: account.provider)) { window in
                                        Toggle(tr(window.title), isOn: Binding(
                                            get: { store.settings.showsTrayLimit(account: account, windowID: window.id) },
                                            set: { value in store.editSettings { $0.setTrayLimit(accountID: account.id, windowID: window.id, visible: value) } }
                                        ))
                                    }
                                } else {
                                    Text(tr("Limits erscheinen nach der ersten erfolgreichen Abfrage.")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if store.settings.menuStyle == .focused {
                        JuiceMenuPicker(title: tr("Angezeigtes Konto"), selection: Binding(get: { store.settings.selectedTrayAccount ?? "" }, set: { value in store.editSettings { $0.selectedTrayAccount = value.isEmpty ? nil : value; $0.selectedTrayWindow = nil } }), options: [(tr("Höchster aktueller Verbrauch"), "")] + store.accounts.filter(\.enabled).map { ($0.displayName, $0.id) })
                        if let id = store.settings.selectedTrayAccount, let snapshot = store.snapshots[id] {
                            JuiceMenuPicker(title: tr("Kontingent"), selection: Binding(get: { store.settings.selectedTrayWindow ?? "" }, set: { value in store.editSettings { $0.selectedTrayWindow = value.isEmpty ? nil : value } }), options: [(tr("Automatisch"), "")] + QuotaOrder.visibleWindows(snapshot.windows, provider: store.accounts.first { $0.id == id }?.provider ?? .codex).map { ($0.title, $0.id) })
                        }
                    }
                    MenuBarLegend()
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 20) {
                    Text(tr("Hintergrund")).font(.headline)
                    JuiceMenuPicker(title: tr("Aktualisieren"), selection: store.setting(\.refreshSeconds), options: [(tr("Jede Minute"), 60.0), (tr("Alle 3 Minuten"), 180.0), (tr("Alle 5 Minuten"), 300.0)])
                    Text(tr("Bleibt der Stand unverändert oder ist der Stromsparmodus an, fragt Juicebars bis zu dreimal seltener ab. API-Kosten höchstens alle 5 Minuten. Bei Fehlern wartet Juicebars länger; beim Ruhezustand stoppt die laufende Abfrage.")).font(.caption).foregroundStyle(.secondary)
                    Toggle(tr("Beim Anmelden starten"), isOn: $loginEnabled).disabled(store.isDemo).onChange(of: loginEnabled) { _, enabled in
                        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginError = nil }
                        catch { loginError = error.localizedDescription }
                    }
                    if let loginError { Text(loginError).font(.caption).foregroundStyle(Palette.warning) }
                    Toggle(tr("Automatische Abfragen pausieren"), isOn: $store.isPaused)
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 14) {
                    Label(tr("Lokal gespeichert"), systemImage: "internaldrive").font(.headline)
                    Text(tr("Juicebars speichert Verbrauchsmessungen, Einstellungen und zugestellte Warnungen. Keine Gesprächsinhalte, keine Telemetrie. Zugangsschlüssel liegen separat im Schlüsselbund.")).font(.callout).foregroundStyle(.secondary)
                    Button(tr("Verlaufsordner öffnen")) {
                        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Juicebar")
                        NSWorkspace.shared.open(url)
                    }.disabled(store.isDemo)
                }
            }
            AboutView()
        }.onChange(of: store.settings) { _, _ in Task { await store.persistSettings() } }
    }
    private func relaunch() {
        // Wait until this instance has exited so two menu bar items never overlap.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"",
                             "sh", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        do { try process.run(); store.stop(); NSApp.terminate(nil) } catch { store.storageError = error.localizedDescription }
    }
}

/// A drawn key for the menu bar lines, matching `MenuLimitImage`.
private struct MenuBarLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Eine Linie pro Limit, nach Konto gruppiert. Ein Klick auf das Symbol zeigt Details."))
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 18) {
                item(LegendLine(fill: 0.6), tr("Aktueller Stand"))
                item(LegendLine(fill: 0.6, stale: true), tr("Letzter Stand"))
                item(LegendLine(fill: nil), tr("Unbekannt"))
                item(LegendLine(fill: 0.05, alert: true), tr("Limit erreicht oder bald erreicht"))
            }.font(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }
    private func item(_ line: LegendLine, _ label: String) -> some View {
        HStack(spacing: 6) { line; Text(label) }
    }
}

private struct LegendLine: View {
    let fill: Double?
    var stale = false
    var alert = false
    var body: some View {
        let color = Palette.provider(.codex), shape = RoundedRectangle(cornerRadius: 2)
        ZStack(alignment: .bottom) {
            if let fill {
                shape.fill(color.opacity(0.22))
                shape.fill(color.opacity(stale ? 0.45 : 1)).frame(height: 18 * fill)
            } else { shape.strokeBorder(color.opacity(0.85), style: StrokeStyle(lineWidth: 1, dash: [2, 2])) }
        }
        .frame(width: 4, height: 18)
        .overlay(alignment: .top) { if stale { Circle().fill(.primary).frame(width: 2, height: 2) } }
        .overlay { if alert { RoundedRectangle(cornerRadius: 2.75).stroke(Palette.warning, lineWidth: 1.5).padding(-0.75) } }
        .padding(.vertical, 2).accessibilityHidden(true)
    }
}

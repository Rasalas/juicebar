import SwiftUI
import JuicebarCore

struct AccountsView: View {
    @ObservedObject var store: AppStore
    @State private var editing: AccountConfiguration?
    @State private var removing: AccountConfiguration?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                PageHeading(title: "Deine Konten.", subtitle: "Abos und API-Kosten separat verbinden. Zugangsschlüssel bleiben im macOS-Schlüsselbund.")
                Spacer()
                Button("Konto hinzufügen", systemImage: "plus") { editing = AccountConfiguration(provider: .codex) }.buttonStyle(JuiceButtonStyle(prominent: true))
            }
            ForEach(store.accounts) { account in
                Panel {
                    HStack(spacing: 16) {
                        ProviderMark(kind: account.provider, size: 42)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(account.displayName).font(.headline)
                            Text(account.provider.name + (account.enabled ? "" : " · Pausiert")).font(.caption).foregroundStyle(.secondary)
                            if let failure = store.failures[account.id] { Text(failure).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                            else if let snapshot = store.snapshots[account.id] { Text("\(snapshot.source) · \(updatedText(snapshot.observedAt, now: store.now))").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button("Bearbeiten") { editing = account }
                        Menu { Button("Konto entfernen", role: .destructive) { removing = account } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                    }
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Vorhandene Anmeldung verwenden", systemImage: "lock.shield").font(.headline)
                    Text("Für Codex und Claude meldest du dich einmal in der jeweiligen CLI an. Juicebar liest deren Verbrauch, ohne eine Modellanfrage zu stellen. Mehrere CLI-Konten lassen sich über getrennte Profilverzeichnisse verbinden.").font(.callout).foregroundStyle(.secondary)
                    Text("OpenCode Go kann den vorhandenen lokalen API-Key verwenden. Für Zen gibt es derzeit keinen verifizierten Guthabenabruf; lokale Aktivität findest du unter Nutzung.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }.sheet(item: $editing) { AccountEditor(store: store, configuration: $0) }
            .alert("Konto entfernen?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button("Abbrechen", role: .cancel) { removing = nil }
                Button("Entfernen", role: .destructive) { if let account = removing { store.removeAccount(account) }; removing = nil }
            } message: { Text("Der lokale Verlauf, manuelle Fristen und der von Juicebar gespeicherte Schlüssel dieses Kontos werden gelöscht. Deine Anbieter-Anmeldung bleibt bestehen.") }
    }
}

struct AccountEditor: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var configuration: AccountConfiguration
    @State private var secret = ""
    @State private var budget = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(store.accounts.contains(where: { $0.id == configuration.id }) ? "Konto bearbeiten" : "Konto hinzufügen").font(.title2.bold())
            Form {
                JuiceMenuPicker(title: "Anbieter", selection: $configuration.provider, options: ProviderKind.allCases.map { ($0.name, $0) })
                    .disabled(store.accounts.contains(where: { $0.id == configuration.id }))
                TextField("Name", text: $configuration.label, prompt: Text(configuration.provider.name))
                Toggle("Verbrauch abrufen", isOn: $configuration.enabled)
                if configuration.provider == .codex || configuration.provider == .claude {
                    TextField("CLI-Pfad", text: $configuration.executablePath, prompt: Text("Automatisch erkennen"))
                    TextField("Profilordner", text: $configuration.profileDirectory, prompt: Text("Standardprofil"))
                    Text("Optional: absoluter Pfad zum Programm und zu CODEX_HOME bzw. CLAUDE_CONFIG_DIR. Anmeldung über codex login bzw. claude auth login.").font(.caption).foregroundStyle(.secondary)
                } else if configuration.provider != .opencodeZen {
                    if configuration.provider == .opencodeGo {
                        OpenCodeSetupHelp()
                        Toggle("Gespeicherten OpenCode Go-Key automatisch übernehmen", isOn: $configuration.useLocalCredentials)
                        if APIProvider.hasLocalOpenCodeGoKey {
                            Label("Go-Key auf diesem Mac gefunden. API-Key unten leer lassen und Speichern wählen.", systemImage: "checkmark.circle")
                                .font(.caption).foregroundStyle(Palette.green)
                        }
                        Text("Ein hier gespeicherter Key hat Vorrang. Ohne eigenen Key liest Juicebar den Eintrag opencode-go auf diesem Mac. Ein Browser-Login allein ändert diesen Key nicht.").font(.caption).foregroundStyle(.secondary)
                    }
                    SecureField("API-Key", text: $secret, prompt: Text("Leer lassen, um gespeicherten Key zu behalten"))
                    Text(configuration.provider.keyHelp).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Zen-Aktivität ist über die lokale OpenCode-Datenbank verfügbar. Ein Guthabenabruf wird derzeit nicht angeboten.").font(.callout).foregroundStyle(.secondary)
                }
                if configuration.provider == .anthropicAPI || configuration.provider == .openaiAPI {
                    TextField("Monatsbudget (USD)", text: $budget, prompt: Text("Optional, z. B. 50"))
                    Text("Dein persönliches Warnbudget, kein Anbieter-Limit.").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).frame(minHeight: 280)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(configuration.provider == .opencodeGo || configuration.provider == .opencodeZen ? "OpenCode-Konsole" : "Anbieter öffnen") { store.openAccount(configuration) }
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Speichern") {
                    if !budget.isEmpty {
                        guard let amount = Double(budget.replacingOccurrences(of: ",", with: ".")), amount > 0, amount.isFinite else { error = "Bitte ein positives Monatsbudget eingeben."; return }
                        configuration.monthlyBudget = amount
                    } else { configuration.monthlyBudget = nil }
                    do { try store.saveAccount(configuration, secret: secret.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(JuiceButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 600).buttonStyle(JuiceButtonStyle()).tint(Palette.accent).onAppear { budget = configuration.monthlyBudget.map { String($0) } ?? "" }
    }
}

struct OpenCodeSetupHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mit OpenCode Go verbinden").font(.system(size: 13, weight: .semibold))
            Text("1. In der Konsole mit der bisherigen Anmeldeart anmelden und den Workspace wählen, in dem du Go abgeschlossen hast.")
            Text("2. Wenn unten ein lokaler Go-Key erkannt wird, kannst du ihn direkt übernehmen. Sonst einen vorhandenen Go-Key in das API-Key-Feld eintragen.")
            Text("3. Speichern wählen. Juicebar prüft die Verbindung und lädt die Limits. Die neue CLI-Anmeldung über opencode console login richtet OpenCode ein; deren Sitzung unterstützt dieser Verbrauchsabruf noch nicht.")
            HStack {
                Button("Konsole öffnen") { NSWorkspace.shared.open(URL(string: "https://opencode.ai/console/")!) }
                Button("Go-Anleitung") { NSWorkspace.shared.open(URL(string: "https://opencode.ai/v2/docs/console/go")!) }
            }
            Text("403 / EntitlementError: Für diesen Key wird keine Go-Berechtigung gemeldet. Das allein beweist nicht, dass ein bezahltes Abo abgelaufen ist. Zuerst Benutzer, Workspace und Abo-Zuordnung prüfen.")
                .foregroundStyle(Palette.accent)
        }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .padding(14).background(Palette.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            .buttonStyle(JuiceButtonStyle())
    }
}

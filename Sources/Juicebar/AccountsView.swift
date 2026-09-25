import SwiftUI
import JuicebarCore

struct AccountsView: View {
    @ObservedObject var store: AppStore
    @State private var editing: AccountConfiguration?
    @State private var removing: AccountConfiguration?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                PageHeading(title: tr("Deine Konten."), subtitle: tr("Abos und API-Kosten separat verbinden. Zugangsschlüssel bleiben im macOS-Schlüsselbund."))
                Spacer()
                Button(tr("Konto hinzufügen"), systemImage: "plus") { editing = AccountConfiguration(provider: .codex) }.buttonStyle(JuiceButtonStyle(prominent: true))
            }
            ForEach(store.accounts) { account in
                Panel {
                    HStack(spacing: 16) {
                        ProviderMark(kind: account.provider, size: 42)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(account.displayName).font(.headline)
                            Text(account.provider.name + (account.enabled ? "" : tr(" · Pausiert"))).font(.caption).foregroundStyle(.secondary)
                            if let failure = store.failures[account.id] { Text(failure).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                            else if let snapshot = store.snapshots[account.id] { Text("\(snapshot.source) · \(updatedText(snapshot.observedAt, now: store.now))").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button(tr("Bearbeiten")) { editing = account }
                        Menu { Button(tr("Konto entfernen"), role: .destructive) { removing = account } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                    }
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    Label(tr("Vorhandene Anmeldung verwenden"), systemImage: "lock.shield").font(.headline)
                    Text(tr("Für Codex und Claude meldest du dich einmal in der jeweiligen CLI an. Juicebar liest deren Verbrauch, ohne eine Modellanfrage zu stellen. Mehrere CLI-Konten lassen sich über getrennte Profilverzeichnisse verbinden.")).font(.callout).foregroundStyle(.secondary)
                    Text(tr("OpenCode Go kann den vorhandenen lokalen API-Key verwenden. Für Zen gibt es derzeit keinen verifizierten Guthabenabruf; lokale Aktivität findest du unter Nutzung.")).font(.callout).foregroundStyle(.secondary)
                }
            }
        }.sheet(item: $editing) { AccountEditor(store: store, configuration: $0) }
            .alert(tr("Konto entfernen?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button(tr("Abbrechen"), role: .cancel) { removing = nil }
                Button(tr("Entfernen"), role: .destructive) { if let account = removing { store.removeAccount(account) }; removing = nil }
            } message: { Text(tr("Der lokale Verlauf, manuelle Fristen und der von Juicebar gespeicherte Schlüssel dieses Kontos werden gelöscht. Deine Anbieter-Anmeldung bleibt bestehen.")) }
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
            Text(store.accounts.contains(where: { $0.id == configuration.id }) ? tr("Konto bearbeiten") : tr("Konto hinzufügen")).font(.title2.bold())
            Form {
                JuiceMenuPicker(title: tr("Anbieter"), selection: $configuration.provider, options: ProviderKind.allCases.map { ($0.name, $0) })
                    .disabled(store.accounts.contains(where: { $0.id == configuration.id }))
                TextField(tr("Name"), text: $configuration.label, prompt: Text(configuration.provider.name))
                Toggle(tr("Verbrauch abrufen"), isOn: $configuration.enabled)
                if configuration.provider == .codex || configuration.provider == .claude {
                    CLISetupHelp(configuration: configuration)
                    DisclosureGroup(tr("Erweiterte Einrichtung")) {
                        TextField(tr("CLI-Pfad"), text: $configuration.executablePath, prompt: Text(tr("Automatisch erkennen")))
                        TextField(tr("Profilordner"), text: $configuration.profileDirectory, prompt: Text(tr("Standardprofil")))
                        Text(tr("Optional: absoluter Pfad zum Programm und zu CODEX_HOME bzw. CLAUDE_CONFIG_DIR. Anmeldung über codex login bzw. claude auth login.")).font(.caption).foregroundStyle(.secondary)
                    }
                } else if configuration.provider != .opencodeZen {
                    if configuration.provider == .opencodeGo {
                        OpenCodeSetupHelp()
                        Toggle(tr("Gespeicherten OpenCode Go-Key automatisch übernehmen"), isOn: $configuration.useLocalCredentials)
                        if APIProvider.hasLocalOpenCodeGoKey {
                            Label(tr("Go-Key auf diesem Mac gefunden. API-Key unten leer lassen und Speichern wählen."), systemImage: "checkmark.circle")
                                .font(.caption).foregroundStyle(Palette.green)
                        }
                        Text(tr("Ein hier gespeicherter Key hat Vorrang. Ohne eigenen Key liest Juicebar den Eintrag opencode-go auf diesem Mac. Ein Browser-Login allein ändert diesen Key nicht.")).font(.caption).foregroundStyle(.secondary)
                    }
                    SecureField(tr("API-Key"), text: $secret, prompt: Text(tr("Leer lassen, um gespeicherten Key zu behalten")))
                    Text(configuration.provider.keyHelp).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(tr("Zen-Aktivität ist über die lokale OpenCode-Datenbank verfügbar. Ein Guthabenabruf wird derzeit nicht angeboten.")).font(.callout).foregroundStyle(.secondary)
                }
                if configuration.provider == .anthropicAPI || configuration.provider == .openaiAPI {
                    TextField(tr("Monatsbudget (USD)"), text: $budget, prompt: Text(tr("Optional, z. B. 50")))
                    Text(tr("Dein persönliches Warnbudget, kein Anbieter-Limit.")).font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).frame(minHeight: 280)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(configuration.provider == .opencodeGo || configuration.provider == .opencodeZen ? tr("OpenCode-Konsole") : tr("Anbieter öffnen")) { store.openAccount(configuration) }
                Spacer()
                Button(tr("Abbrechen")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("Speichern")) {
                    if !budget.isEmpty {
                        guard let amount = Double(budget.replacingOccurrences(of: ",", with: ".")), amount > 0, amount.isFinite else { error = tr("Bitte ein positives Monatsbudget eingeben."); return }
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
            Text(tr("Mit OpenCode Go verbinden")).font(.system(size: 13, weight: .semibold))
            Text(tr("1. In der Konsole mit der bisherigen Anmeldeart anmelden und den Workspace wählen, in dem du Go abgeschlossen hast."))
            Text(tr("2. Wenn unten ein lokaler Go-Key erkannt wird, kannst du ihn direkt übernehmen. Sonst einen vorhandenen Go-Key in das API-Key-Feld eintragen."))
            Text(tr("3. Speichern wählen. Juicebar prüft die Verbindung und lädt die Limits. Die neue CLI-Anmeldung über opencode console login richtet OpenCode ein; deren Sitzung unterstützt dieser Verbrauchsabruf noch nicht."))
            HStack {
                Button(tr("Konsole öffnen")) { NSWorkspace.shared.open(URL(string: "https://opencode.ai/console/")!) }
                Button(tr("Go-Anleitung")) { NSWorkspace.shared.open(URL(string: "https://opencode.ai/v2/docs/console/go")!) }
            }
            Text(tr("403 / EntitlementError: Für diesen Key wird keine Go-Berechtigung gemeldet. Das allein beweist nicht, dass ein bezahltes Abo abgelaufen ist. Zuerst Benutzer, Workspace und Abo-Zuordnung prüfen."))
                .foregroundStyle(Palette.accent)
        }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .padding(14).background(Palette.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            .buttonStyle(JuiceButtonStyle())
    }
}

struct CLISetupHelp: View {
    let configuration: AccountConfiguration
    @State private var copied = false
    private var command: String { configuration.provider == .codex ? "codex login" : "claude auth login" }
    private var installed: Bool { (try? ProcessClient.executable(configuration.provider == .codex ? "codex" : "claude", custom: configuration.executablePath)) != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(installed ? tr("CLI auf diesem Mac gefunden") : tr("CLI noch nicht gefunden"), systemImage: installed ? "checkmark.circle" : "terminal")
                .font(.subheadline.weight(.medium))
            Text(tr("1. CLI installieren, falls sie noch fehlt. 2. Im Terminal anmelden. 3. Hier speichern. Juicebar prüft die Verbindung automatisch."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button(copied ? tr("Kopiert") : tr("Befehl kopieren")) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string); copied = true
                }
                Link(tr("CLI installieren"), destination: configuration.provider == .codex ? URL(string: "https://developers.openai.com/codex/cli/")! : URL(string: "https://code.claude.com/docs/en/setup")!)
            }
            Text(tr("Ein gefundenes Programm bestätigt noch keine Anmeldung. Passwörter gehören nur in die Anmeldung des Anbieters."))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 6)
    }
}

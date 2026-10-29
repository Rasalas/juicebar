import SwiftUI
import JuicebarCore

struct AccountsView: View {
    let store: AppStore
    @State private var editing: AccountConfiguration?
    @State private var removing: AccountConfiguration?
    private let navigation = DashboardNavigation.shared
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
                            if let failure = store.failures[account.id] { Text(failure).font(.caption).foregroundStyle(Palette.warning).fixedSize(horizontal: false, vertical: true) }
                            else if let snapshot = store.snapshots[account.id] { Text("\(snapshot.source) · \(updatedText(snapshot.observedAt, now: store.now))").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button(tr("Bearbeiten")) { editing = account }
                        Menu { Button(tr("Konto entfernen"), role: .destructive) { removing = account } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                            .accessibilityLabel(tr("Weitere Aktionen für {0}", account.displayName)).help(tr("Weitere Aktionen"))
                    }
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    Label(tr("Vorhandene Anmeldung verwenden"), systemImage: "lock.shield").font(.headline)
                    Text(tr("Für Codex und Claude meldest du dich einmal in der jeweiligen CLI an. Juicebars liest deren Verbrauch, ohne eine Modellanfrage zu stellen. Mehrere CLI-Konten lassen sich über getrennte Profilverzeichnisse verbinden.")).font(.callout).foregroundStyle(.secondary)
                    Text(tr("OpenCode Go kann den vorhandenen lokalen API-Key verwenden. Für Zen gibt es derzeit keinen verifizierten Guthabenabruf; lokale Aktivität findest du unter Nutzung.")).font(.callout).foregroundStyle(.secondary)
                }
            }
        }.disabled(store.isLoading).sheet(item: $editing) { AccountEditor(store: store, configuration: $0) }
            .onChange(of: navigation.editAccountID, initial: true) { _, id in
                guard let id else { return }
                navigation.editAccountID = nil
                editing = store.accounts.first { $0.id == id }
            }
            .alert(tr("Konto entfernen?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button(tr("Abbrechen"), role: .cancel) { removing = nil }
                Button(tr("Entfernen"), role: .destructive) { if let account = removing { Task { await store.removeAccount(account) } }; removing = nil }
            } message: { Text(tr("Der lokale Verlauf, manuelle Fristen und der von Juicebars gespeicherte Schlüssel dieses Kontos werden gelöscht. Deine Anbieter-Anmeldung bleibt bestehen.")) }
    }
}

struct AccountEditor: View {
    let store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var configuration: AccountConfiguration
    @State private var secret = ""
    @State private var budget = ""
    @State private var error: String?
    @State private var hasStoredKey = false
    @State private var removeKeyOnSave = false
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(store.accounts.contains(where: { $0.id == configuration.id }) ? tr("Konto bearbeiten") : tr("Konto hinzufügen")).font(.title2.bold())
            Form {
                JuiceMenuPicker(title: tr("Anbieter"), selection: $configuration.provider, options: ProviderKind.allCases.map { ($0.name, $0) })
                    .disabled(store.accounts.contains(where: { $0.id == configuration.id }))
                TextField(tr("Name"), text: $configuration.label, prompt: Text(configuration.provider.name))
                Toggle(tr("Verbrauch abrufen"), isOn: $configuration.enabled)
                if configuration.provider == .codex || configuration.provider == .claude || configuration.provider == .opencodeGo {
                    WorkScheduleEditor(schedule: $configuration.workSchedule)
                }
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
                        Text(tr("Ein hier gespeicherter Key hat Vorrang. Ohne eigenen Key liest Juicebars den Eintrag opencode-go auf diesem Mac. Ein Browser-Login allein ändert diesen Key nicht.")).font(.caption).foregroundStyle(.secondary)
                    }
                    SecureField(tr("API-Key"), text: $secret, prompt: Text(hasStoredKey && !removeKeyOnSave ? tr("Leer lassen, um gespeicherten Key zu behalten") : tr("Key einfügen")))
                        .disabled(removeKeyOnSave)
                    Text(configuration.provider.keyHelp).font(.caption).foregroundStyle(.secondary)
                    if hasStoredKey {
                        Button(removeKeyOnSave ? tr("Key behalten") : tr("Gespeicherten Key entfernen"), role: removeKeyOnSave ? nil : .destructive) {
                            removeKeyOnSave.toggle()
                            if removeKeyOnSave { secret = "" }
                        }
                        Text(removeKeyOnSave ? tr("Der Key wird erst beim Speichern entfernt. Konto und Verlauf bleiben erhalten.") : tr("Konto und Verlauf bleiben erhalten. Ohne eigenen Key kann OpenCode Go wieder den lokalen Key verwenden.")).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(tr("Zen-Aktivität ist über die lokale OpenCode-Datenbank verfügbar. Ein Guthabenabruf wird derzeit nicht angeboten.")).font(.callout).foregroundStyle(.secondary)
                }
                if configuration.provider == .anthropicAPI || configuration.provider == .openaiAPI {
                    TextField(tr("Monatsbudget (USD)"), text: $budget, prompt: Text(tr("Optional, z. B. 50")))
                    Text(tr("Dein persönliches Warnbudget, kein Anbieter-Limit.")).font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(saving).formStyle(.grouped).frame(minHeight: 280)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(configuration.provider == .opencodeGo || configuration.provider == .opencodeZen ? tr("OpenCode-Konsole") : tr("Anbieter öffnen")) { store.openAccount(configuration) }
                Spacer()
                Button(tr("Abbrechen")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                if saving { ProgressView().controlSize(.small).accessibilityLabel(tr("Wird gespeichert …")) }
                Button(tr("Speichern")) {
                    if !budget.isEmpty {
                        guard let amount = Double(budget.replacingOccurrences(of: ",", with: ".")), amount > 0, amount.isFinite else { error = tr("Bitte ein positives Monatsbudget eingeben."); return }
                        configuration.monthlyBudget = amount
                    } else { configuration.monthlyBudget = nil }
                    saving = true
                    Task {
                        defer { saving = false }
                        do { try await store.saveAccount(configuration, secret: secret.trimmingCharacters(in: .whitespacesAndNewlines), removeSavedKey: removeKeyOnSave); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(JuiceButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                    .disabled(saving || (configuration.workSchedule.map { $0.isEnabled && !$0.isValid } ?? false))
            }
        }.interactiveDismissDisabled(saving).padding(28).frame(width: 600).buttonStyle(JuiceButtonStyle()).tint(Palette.accent).onAppear {
            budget = configuration.monthlyBudget.map { String($0) } ?? ""
        }.task {
            hasStoredKey = await store.hasSavedKey(for: configuration)
        }
        .onChange(of: configuration.provider) { _, provider in
            if provider != .codex && provider != .claude && provider != .opencodeGo { configuration.workSchedule = nil }
        }
    }
}

struct OpenCodeSetupHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Mit OpenCode Go verbinden")).font(.body.weight(.semibold))
            Text(tr("1. In der Konsole mit der bisherigen Anmeldeart anmelden und den Workspace wählen, in dem du Go abgeschlossen hast."))
            Text(tr("2. Wenn unten ein lokaler Go-Key erkannt wird, kannst du ihn direkt übernehmen. Sonst einen vorhandenen Go-Key in das API-Key-Feld eintragen."))
            Text(tr("3. Speichern wählen. Juicebars prüft die Verbindung und lädt die Limits. Die neue CLI-Anmeldung über opencode console login richtet OpenCode ein; deren Sitzung unterstützt dieser Verbrauchsabruf noch nicht."))
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
    static func loginCommand(for provider: ProviderKind) -> String? {
        switch provider { case .codex: return "codex login"; case .claude: return "claude auth login"; default: return nil }
    }
    private var command: String { Self.loginCommand(for: configuration.provider) ?? "" }
    /// A first run only adds the CLIs installed on this Mac, so nobody starts with errors for tools they don't use.
    nonisolated static func detectedDefaultAccounts(isInstalled: (String) -> Bool = { (try? ProcessClient.executable($0)) != nil }) -> [AccountConfiguration] {
        [(ProviderKind.codex, "codex"), (.claude, "claude")].filter { isInstalled($0.1) }
            .map { AccountConfiguration(id: "default-\($0.1)", provider: $0.0) }
    }
    private var installed: Bool { (try? ProcessClient.executable(configuration.provider == .codex ? "codex" : "claude", custom: configuration.executablePath)) != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(installed ? tr("CLI auf diesem Mac gefunden") : tr("CLI noch nicht gefunden"), systemImage: installed ? "checkmark.circle" : "terminal")
                .font(.subheadline.weight(.medium))
            Text(tr("1. CLI installieren, falls sie noch fehlt. 2. Im Terminal anmelden. 3. Hier speichern. Juicebars prüft die Verbindung automatisch."))
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

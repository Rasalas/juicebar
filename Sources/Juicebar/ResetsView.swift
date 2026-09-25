import SwiftUI
import JuicebarCore

struct ResetsView: View {
    @ObservedObject var store: AppStore
    @State private var adding = false
    private var entries: [(AccountConfiguration, ResetBenefit)] {
        store.accounts.flatMap { account in
            (store.snapshots[account.id]?.benefits ?? []).map { (account, $0) }
            + store.manualResets.filter { $0.accountID == account.id }.map { (account, $0.benefit) }
        }.sorted { ($0.1.expiresAt ?? .distantFuture) < ($1.1.expiresAt ?? .distantFuture) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                PageHeading(title: "Keinen Reset verschenken.", subtitle: "Angesparte Resets und befristete Angebote. Einlösen kannst du sie direkt beim Anbieter.")
                Spacer()
                Button("Frist ergänzen", systemImage: "plus") { adding = true }.disabled(store.accounts.isEmpty)
            }
            if entries.isEmpty {
                Panel { EmptyState(symbol: "arrow.counterclockwise", title: "Keine bekannten Reset-Fristen", message: "Nicht jeder Anbieter liefert einzelne Ablaufdaten. Eine bekannte Frist kannst du selbst ergänzen.") }
            }
            ForEach(store.accounts) { account in
                if let snapshot = store.snapshots[account.id], let count = snapshot.benefitCount, count > snapshot.benefits.filter({ $0.status == .available }).reduce(0, { $0 + $1.count }) {
                    Label("\(account.displayName): \(count) Resets verfügbar, aber nicht alle Ablaufdaten sind bekannt.", systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
                if account.provider == .claude, let notice = store.snapshots[account.id]?.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(entries, id: \.1.id) { account, benefit in
                Panel {
                    HStack(alignment: .top, spacing: 15) {
                        ProviderMark(kind: account.provider)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(account.displayName) · \(benefit.title)").font(.headline)
                            Text(benefit.scope).font(.callout).foregroundStyle(.secondary)
                            if let expiry = benefit.expiresAt {
                                Text(expiry <= store.now ? "Abgelaufen" : "Läuft \(relativeTime(expiry, now: store.now)) ab")
                                    .font(.system(size: 18, weight: .medium, design: .rounded)).foregroundStyle(expiry > store.now ? Palette.accent : Color.secondary)
                                Text(expiry.formatted(date: .complete, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            } else { Text("Ablaufdatum nicht verfügbar").font(.callout).foregroundStyle(.secondary) }
                            Text("\(benefit.count) × · \(status(benefit.status))\(benefit.isManual ? " · Manuell eingetragen" : "")").font(.caption).foregroundStyle(.secondary)
                            if !benefit.isManual, let snapshot = store.snapshots[account.id] {
                                Text(updatedText(snapshot.observedAt, now: store.now)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 12) {
                            Button("Beim Anbieter öffnen") { store.openAccount(account) }
                            if benefit.isManual { Button("Entfernen", role: .destructive) { store.removeReset(benefit.id) }.buttonStyle(JuiceButtonStyle()) }
                        }
                    }
                }
            }
            Text("Ein Kontingent-Reset und ein befristetes Reset-Angebot sind verschiedene Dinge. Juicebar löst keine Angebote automatisch ein.").font(.caption).foregroundStyle(.secondary)
        }.sheet(isPresented: $adding) { AddResetView(store: store) }
    }
    private func status(_ status: BenefitStatus) -> String {
        switch status { case .available: return "Verfügbar"; case .used: return "Verbraucht"; case .expired: return "Abgelaufen"; case .paused: return "Derzeit nicht einlösbar"; case .unknown: return "Status unbekannt" }
    }
}

struct AddResetView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var accountID = ""
    @State private var title = "Reset-Angebot"
    @State private var scope = ""
    @State private var expiry = Date().addingTimeInterval(86400)
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Reset-Frist ergänzen").font(.title2.bold())
            Text("Nutze das genaue Ablaufdatum aus deinem Konto. Die Erinnerung bleibt als manuell eingetragen gekennzeichnet.").foregroundStyle(.secondary)
            Form {
                JuiceMenuPicker(title: "Konto", selection: $accountID, options: store.accounts.map { ($0.displayName, $0.id) })
                TextField("Bezeichnung", text: $title)
                TextField("Gilt für", text: $scope, prompt: Text("z. B. Wochenkontingent"))
                DatePicker("Läuft ab", selection: $expiry, in: Date()...)
            }
            HStack { Spacer(); Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Frist speichern") { store.addReset(accountID: accountID, title: title, scope: scope.isEmpty ? "Manuelle Erinnerung" : scope, expiry: expiry); dismiss() }
                    .buttonStyle(JuiceButtonStyle(prominent: true)).keyboardShortcut(.defaultAction).disabled(accountID.isEmpty || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(28).frame(width: 480).buttonStyle(JuiceButtonStyle()).tint(Palette.accent).onAppear { accountID = store.accounts.first?.id ?? "" }
    }
}

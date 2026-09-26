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
                PageHeading(title: tr("Keinen Reset verschenken."), subtitle: tr("Angesparte Resets und befristete Angebote. Einlösen kannst du sie direkt beim Anbieter."))
                Spacer()
                Button(tr("Frist ergänzen"), systemImage: "plus") { adding = true }.disabled(store.accounts.isEmpty)
            }
            if entries.isEmpty {
                Panel { EmptyState(symbol: "arrow.counterclockwise", title: tr("Keine bekannten Reset-Fristen"), message: tr("Nicht jeder Anbieter liefert einzelne Ablaufdaten. Eine bekannte Frist kannst du selbst ergänzen.")) }
            }
            ForEach(store.accounts) { account in
                if let snapshot = store.snapshots[account.id], let count = snapshot.benefitCount, count > snapshot.benefits.filter({ $0.status == .available }).reduce(0, { $0 + $1.count }) {
                    Label(tr("{0}: {1} Resets verfügbar, aber nicht alle Ablaufdaten sind bekannt.", account.displayName, count), systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
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
                                Text(expiry <= store.now ? tr("Abgelaufen") : tr("Läuft {0} ab", relativeTime(expiry, now: store.now)))
                                    .font(.system(size: 18, weight: .medium, design: .rounded)).foregroundStyle(expiry > store.now ? Palette.accent : Color.secondary)
                                Text(expiry.formatted(Date.FormatStyle(date: .complete, time: .shortened).locale(Localization.locale))).font(.caption).foregroundStyle(.secondary)
                            } else { Text(tr("Ablaufdatum nicht verfügbar")).font(.callout).foregroundStyle(.secondary) }
                            Text("\(benefit.count) × · \(status(benefit.status))\(benefit.isManual ? tr(" · Manuell eingetragen") : "")").font(.caption).foregroundStyle(.secondary)
                            if !benefit.isManual, let snapshot = store.snapshots[account.id] {
                                Text(updatedText(snapshot.observedAt, now: store.now)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 12) {
                            Button(tr("Beim Anbieter öffnen")) { store.openAccount(account) }
                            if benefit.isManual { Button(tr("Entfernen"), role: .destructive) { store.removeReset(benefit.id) }.buttonStyle(JuiceButtonStyle()) }
                        }
                    }
                }
            }
            Text(tr("Ein Kontingent-Reset und ein befristetes Reset-Angebot sind verschiedene Dinge. Juicebars löst keine Angebote automatisch ein.")).font(.caption).foregroundStyle(.secondary)
        }.sheet(isPresented: $adding) { AddResetView(store: store) }
    }
    private func status(_ status: BenefitStatus) -> String {
        switch status { case .available: return tr("Verfügbar"); case .used: return tr("Verbraucht"); case .expired: return tr("Abgelaufen"); case .paused: return tr("Derzeit nicht einlösbar"); case .unknown: return tr("Status unbekannt") }
    }
}

struct AddResetView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var accountID = ""
    @State private var title = tr("Reset-Angebot")
    @State private var scope = ""
    @State private var expiry = Date().addingTimeInterval(86400)
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(tr("Reset-Frist ergänzen")).font(.title2.bold())
            Text(tr("Nutze das genaue Ablaufdatum aus deinem Konto. Die Erinnerung bleibt als manuell eingetragen gekennzeichnet.")).foregroundStyle(.secondary)
            Form {
                JuiceMenuPicker(title: tr("Konto"), selection: $accountID, options: store.accounts.map { ($0.displayName, $0.id) })
                TextField(tr("Bezeichnung"), text: $title)
                TextField(tr("Gilt für"), text: $scope, prompt: Text(tr("z. B. Wochenkontingent")))
                DatePicker(tr("Läuft ab"), selection: $expiry, in: Date()...)
            }
            HStack { Spacer(); Button(tr("Abbrechen")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("Frist speichern")) { store.addReset(accountID: accountID, title: title, scope: scope.isEmpty ? tr("Manuelle Erinnerung") : scope, expiry: expiry); dismiss() }
                    .buttonStyle(JuiceButtonStyle(prominent: true)).keyboardShortcut(.defaultAction).disabled(accountID.isEmpty || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(28).frame(width: 480).buttonStyle(JuiceButtonStyle()).tint(Palette.accent).onAppear { accountID = store.accounts.first?.id ?? "" }
    }
}

import SwiftUI
import JuicebarCore

struct ResetsView: View {
    let store: AppStore
    @State private var adding = false
    @State private var resetAlert: ResetAlert?
    @State private var workingCreditID: String?
    private var entries: [(AccountConfiguration, ResetBenefit)] {
        store.accounts.flatMap { account in
            (store.snapshots[account.id]?.benefits ?? []).map { (account, $0) }
            + store.manualResets.filter { $0.accountID == account.id }.map { (account, $0.benefit) }
        }.sorted { ($0.1.expiresAt ?? .distantFuture) < ($1.1.expiresAt ?? .distantFuture) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                PageHeading(title: tr("Keinen Reset verschenken."), subtitle: tr("Angesparte Reset-Gutschriften und befristete Angebote."))
                Spacer()
                Button(tr("Frist ergänzen"), systemImage: "plus") { adding = true }.disabled(store.accounts.isEmpty)
            }
            if entries.isEmpty {
                Panel { EmptyState(symbol: "arrow.counterclockwise", title: tr("Keine bekannten Reset-Gutschriften"), message: tr("Nicht jeder Anbieter liefert einzelne Ablaufdaten. Eine bekannte Frist kannst du selbst ergänzen.")) }
            }
            ForEach(store.accounts) { account in
                if let snapshot = store.snapshots[account.id], let count = snapshot.benefitCount, count > snapshot.benefits.filter({ $0.status == .available }).reduce(0, { $0 + $1.count }) {
                    Label(tr("{0}: {1} Reset-Gutschriften verfügbar, aber nicht alle Ablaufdaten sind bekannt.", account.displayName, count), systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
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
                                    .font(.system(size: 18, weight: .medium, design: .rounded)).foregroundStyle(expiry > store.now ? Palette.warning : Color.secondary)
                                Text(expiry.formatted(Date.FormatStyle(date: .complete, time: .shortened).locale(Localization.locale))).font(.caption).foregroundStyle(.secondary)
                            } else { Text(tr("Ablaufdatum nicht verfügbar")).font(.callout).foregroundStyle(.secondary) }
                            Text("\(benefit.count) × · \(status(benefit.status))\(benefit.isManual ? tr(" · Manuell eingetragen") : "")").font(.caption).foregroundStyle(.secondary)
                            if !benefit.isManual, let snapshot = store.snapshots[account.id] {
                                Text(updatedText(snapshot.observedAt, now: store.now)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 12) {
                            redemptionButton(account: account, benefit: benefit)
                            Button(tr("Beim Anbieter öffnen")) { store.openAccount(account) }
                            if benefit.isManual { Button(tr("Entfernen"), role: .destructive) { Task { await store.removeReset(benefit.id) } }.buttonStyle(JuiceButtonStyle()) }
                        }
                    }
                }
            }
            Text(tr("Juicebars löst keine Reset-Gutschriften automatisch ein.")).font(.caption).foregroundStyle(.secondary)
        }.sheet(isPresented: $adding) { AddResetView(store: store) }
            .alert(item: $resetAlert, content: alert)
    }
    @ViewBuilder private func redemptionButton(account: AccountConfiguration, benefit: ResetBenefit) -> some View {
        if account.provider == .codex, !benefit.isManual, benefit.status == .available, benefit.count > 0 {
            HStack(spacing: 7) {
                if workingCreditID == benefit.id { ProgressView().controlSize(.small) }
                Button(tr("Reset einlösen")) {
                    guard let snapshot = store.snapshots[account.id] else { return }
                    resetAlert = .confirm(ResetConfirmation(account: account, benefit: benefit, identity: snapshot.identity))
                }.buttonStyle(JuiceButtonStyle(prominent: true))
                    .disabled(!store.canRedeemReset(benefit, for: account))
                    .accessibilityIdentifier("redeem-reset-\(benefit.id)")
            }
        }
    }
    private func alert(_ value: ResetAlert) -> Alert {
        switch value {
        case .confirm(let request):
            return Alert(title: Text(tr("Reset einlösen?")),
                         message: Text(tr("Eine Reset-Gutschrift von {0} wird verbraucht.", request.account.displayName)),
                         primaryButton: .destructive(Text(tr("Reset einlösen"))) { Task { await redeem(request) } },
                         secondaryButton: .cancel(Text(tr("Abbrechen"))))
        case .result(let message):
            return Alert(title: Text(tr("Reset-Gutschrift")), message: Text(message), dismissButton: .default(Text(tr("OK"))))
        }
    }
    private func redeem(_ request: ResetConfirmation) async {
        workingCreditID = request.benefit.id
        defer { workingCreditID = nil }
        do {
            let result = try await store.redeemReset(request.benefit, for: request.account, expectedIdentity: request.identity)
            let message: String
            switch result.outcome {
            case .reset: message = tr("Reset eingelöst.")
            case .alreadyRedeemed: message = tr("Dieser Reset wurde bereits eingelöst.")
            case .nothingToReset: message = tr("Aktuell gibt es kein Kontingent zurückzusetzen.")
            case .noCredit: message = tr("Die Reset-Gutschrift ist nicht mehr verfügbar.")
            }
            resetAlert = .result(message + (result.snapshot == nil ? "\n" + tr("Der Kontostand wird beim nächsten Abruf aktualisiert.") : ""))
        } catch { resetAlert = .result(error.localizedDescription) }
    }
    private func status(_ status: BenefitStatus) -> String {
        switch status { case .available: return tr("Verfügbar"); case .used: return tr("Verbraucht"); case .expired: return tr("Abgelaufen"); case .paused: return tr("Derzeit nicht einlösbar"); case .unknown: return tr("Status unbekannt") }
    }
}

private struct ResetConfirmation {
    let account: AccountConfiguration
    let benefit: ResetBenefit
    let identity: String
}

private enum ResetAlert: Identifiable {
    case confirm(ResetConfirmation)
    case result(String)
    var id: String {
        switch self {
        case .confirm(let value): return "confirm|\(value.account.id)|\(value.benefit.id)"
        case .result(let message): return "result|\(message)"
        }
    }
}

struct AddResetView: View {
    let store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var accountID = ""
    @State private var title = tr("Reset-Gutschrift")
    @State private var scope = ""
    @State private var expiry = Date().addingTimeInterval(86400)
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(tr("Ablaufdatum einer Reset-Gutschrift ergänzen")).font(.title2.bold())
            Text(tr("Nutze das genaue Ablaufdatum aus deinem Konto. Die Erinnerung bleibt als manuell eingetragen gekennzeichnet.")).foregroundStyle(.secondary)
            Form {
                JuiceMenuPicker(title: tr("Konto"), selection: $accountID, options: store.accounts.map { ($0.displayName, $0.id) })
                TextField(tr("Bezeichnung"), text: $title)
                TextField(tr("Gilt für"), text: $scope, prompt: Text(tr("z. B. Wochenkontingent")))
                DatePicker(tr("Läuft ab"), selection: $expiry, in: Date()...)
            }
            HStack { Spacer(); Button(tr("Abbrechen")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("Frist speichern")) { Task { await store.addReset(accountID: accountID, title: title, scope: scope.isEmpty ? tr("Manuelle Erinnerung") : scope, expiry: expiry); dismiss() } }
                    .buttonStyle(JuiceButtonStyle(prominent: true)).keyboardShortcut(.defaultAction).disabled(accountID.isEmpty || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(28).frame(width: 480).buttonStyle(JuiceButtonStyle()).tint(Palette.accent).onAppear { accountID = store.accounts.first?.id ?? "" }
    }
}

import SwiftUI
import JuicebarCore

struct AboutView: View {
    @AppStorage("catalogUpdates") private var catalogUpdates = true
    @ObservedObject private var updates = AppUpdates.shared
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(tr("Über Juicebars")).font(.headline)
                    Spacer()
                    Text(updates.version).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(tr("Von Rasalas und Mitwirkenden. Open Source unter der MIT-Lizenz."))
                    .font(.callout).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack { projectLinks }
                    VStack(alignment: .leading, spacing: 10) { projectLinks }
                }
                Divider()
                if updates.available {
                    Toggle(tr("Automatisch nach App-Updates suchen"), isOn: Binding(get: { updates.automaticChecks }, set: { updates.automaticChecks = $0 }))
                    Button(tr("Nach App-Updates suchen …"), action: updates.check).disabled(!updates.canCheck)
                    Text(tr("Updates bleiben kostenlos. Es wird kein Juicebars-Konto benötigt.")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Button(tr("Veröffentlichungen ansehen"), action: updates.check)
                    Text(tr("Dieser selbst gebaute Stand hat keinen aktiven Auto-Updater. Neue Versionen und Installationshinweise stehen im Projekt."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(tr("Modellnamen und API-Preise automatisch aktualisieren"), isOn: $catalogUpdates)
                Text(tr("Signierter Datenkatalog · Stand {0}. Keine Gesprächsdaten werden übertragen.", APICost.priceDate)).font(.caption).foregroundStyle(.secondary)
                if let error = updates.error { Text(error).font(.caption).foregroundStyle(.orange) }
                DisclosureGroup(tr("Entwicklung unterstützen")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(tr("Freiwillige Beiträge helfen bei der Pflege der Anbieter-Anbindungen. Funktionen und Updates sind davon unabhängig."))
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Link("GitHub Sponsors", destination: URL(string: "https://github.com/sponsors/Rasalas")!)
                            Link(tr("Einmaliger Beitrag"), destination: URL(string: "https://buymeacoffee.com/tbuck91j")!)
                        }
                    }.padding(.top, 8)
                }
            }
        }
    }

    @ViewBuilder private var projectLinks: some View {
        Link(tr("Quellcode"), destination: AppUpdates.project)
        Link(tr("Fehler melden"), destination: AppUpdates.project.appendingPathComponent("issues"))
        Link(tr("Datenschutz"), destination: AppUpdates.project.appendingPathComponent("blob/main/PRIVACY.md"))
        Link(tr("Lizenzen"), destination: AppUpdates.project.appendingPathComponent("blob/main/THIRD_PARTY_NOTICES.md"))
    }
}

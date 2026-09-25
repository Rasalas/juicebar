import SwiftUI

struct AboutView: View {
    @ObservedObject private var updates = AppUpdates.shared
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Über Juicebar").font(.headline)
                    Spacer()
                    Text(updates.version).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text("Von Rasalas und Mitwirkenden. Open Source unter der MIT-Lizenz.")
                    .font(.callout).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack { projectLinks }
                    VStack(alignment: .leading, spacing: 10) { projectLinks }
                }
                Divider()
                if updates.available {
                    Toggle("Automatisch nach App-Updates suchen", isOn: Binding(get: { updates.automaticChecks }, set: { updates.automaticChecks = $0 }))
                    Button("Nach App-Updates suchen …", action: updates.check).disabled(!updates.canCheck)
                    Text("Updates bleiben kostenlos. Es wird kein Juicebar-Konto benötigt.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Veröffentlichungen ansehen", action: updates.check)
                    Text("Dieser selbst gebaute Stand hat keinen aktiven Auto-Updater. Neue Versionen und Installationshinweise stehen im Projekt.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = updates.error { Text(error).font(.caption).foregroundStyle(.orange) }
                DisclosureGroup("Entwicklung unterstützen") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Freiwillige Beiträge helfen bei der Pflege der Anbieter-Anbindungen. Funktionen und Updates sind davon unabhängig.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Link("GitHub Sponsors", destination: URL(string: "https://github.com/sponsors/Rasalas")!)
                            Link("Einmaliger Beitrag", destination: URL(string: "https://buymeacoffee.com/tbuck91j")!)
                        }
                    }.padding(.top, 8)
                }
            }
        }
    }

    @ViewBuilder private var projectLinks: some View {
        Link("Quellcode", destination: AppUpdates.project)
        Link("Fehler melden", destination: AppUpdates.project.appendingPathComponent("issues"))
        Link("Datenschutz", destination: AppUpdates.project.appendingPathComponent("blob/main/PRIVACY.md"))
        Link("Lizenzen", destination: AppUpdates.project.appendingPathComponent("blob/main/THIRD_PARTY_NOTICES.md"))
    }
}

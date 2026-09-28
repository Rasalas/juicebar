import SwiftUI
import JuicebarCore

struct ActivitySourcesView: View {
    @ObservedObject var store: AppStore
    @State private var format: ActivitySource = .pi

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                Text(tr("Zusätzliche Log-Ordner")).font(.headline)
                Text(tr("Standardordner werden automatisch gelesen. Ergänze hier abweichende Speicherorte oder kompatible Werkzeuge, etwa Tau mit Pi-Format."))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(store.activityRoots) { root in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(root.source.name).font(.system(size: 13, weight: .medium))
                            Text(root.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button(tr("Entfernen")) { store.removeActivityRoot(root) }
                            .disabled(store.localUsageLoading || store.isDemo)
                    }
                }
                HStack {
                    Picker(tr("Log-Format"), selection: $format) {
                        ForEach(ActivitySource.logFormats) { source in Text(source.name).tag(source) }
                    }.frame(width: 210)
                    Button(tr("Ordner hinzufügen …")) { store.selectActivityDirectory(format: format) }
                        .disabled(store.localUsageLoading || store.isDemo)
                }
                Text(tr("Gleiche Einträge zählen einmal, auch bei automatisch erkannten Ordnern und Kopien auf anderen Rechnern. Entfernen beendet zusätzliche Importe; automatisch erkannte Standardordner bleiben aktiv. Bereits erfasste Nutzung bleibt 90 Tage erhalten."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

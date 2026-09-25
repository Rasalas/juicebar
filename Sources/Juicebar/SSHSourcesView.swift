import SwiftUI
import JuicebarCore

struct SSHSourcesView: View {
    @ObservedObject var store: AppStore
    @State private var host = ""
    @State private var error: String?
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Label("Weitere Rechner", systemImage: "network").font(.headline); Spacer(); Text("SSH").font(.caption.monospaced()).foregroundStyle(.secondary) }
                Text("Vorhandene SSH-Aliase, zum Beispiel workstation. Liest Codex-, Claude- und OpenCode-Nutzung aus deinem Benutzerverzeichnis. Benötigt Python 3 und eine Anmeldung mit Schlüssel.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(store.sshHosts, id: \.self) { value in
                    HStack {
                        Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                        Text(value).font(.system(size: 13, weight: .medium, design: .monospaced))
                        Spacer()
                        Button("Entfernen") { store.removeSSHHost(value) }.disabled(store.localUsageLoading || store.isDemo)
                    }
                }
                HStack {
                    TextField("SSH-Alias oder user@host", text: $host).textFieldStyle(.roundedBorder).onSubmit(add)
                    Button("Hinzufügen", action: add).disabled(host.isEmpty || store.localUsageLoading || store.isDemo)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                Text("Übertragen werden nur Nutzungsdaten. Keine Gesprächsinhalte, keine Installation auf dem Zielrechner. Unbekannte Host-Schlüssel und Passwortabfragen werden abgewiesen. Neue Quellen werden automatisch eingelesen.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func add() {
        do { try store.addSSHHost(host); host = ""; error = nil }
        catch { self.error = error.localizedDescription }
    }
}

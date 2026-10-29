import SwiftUI
import JuicebarCore

struct UsageFreshnessView: View {
    let report: ActivityReport
    let source: ActivitySource?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let sources = report.sources {
                let relevant = sources.filter { $0.includes(source) }
                let absent = relevant.filter { $0.phase == .unavailable && $0.tools != nil && $0.lastSuccess == nil && $0.issue == nil }
                if !absent.isEmpty {
                    line(tr("Lokale Quellen ohne bestätigten Abruf: {0}.", Set(absent.flatMap { $0.tools ?? [] }.map(\.name)).sorted().joined(separator: ", ")), symbol: "clock", warning: false)
                }
                ForEach(relevant.filter { !absent.contains($0) && ($0.phase != .success || $0.issue != nil || $0.coverage?.isEmpty == false) }) { item in
                    let warning = item.phase == .stale || item.phase == .unavailable || item.issue != nil || item.coverage?.isEmpty == false
                    line(UsageFreshness.text(item), symbol: warning ? "exclamationmark.triangle" : "clock", warning: warning)
                }
            } else {
                line(tr("Gespeicherte Nutzung · Aktualität der einzelnen Quellen unbekannt."), symbol: "clock", warning: false)
            }
        }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func line(_ text: String, symbol: String, warning: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(text).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(warning ? Palette.warning : .secondary)
            .accessibilityElement(children: .combine)
    }

}

enum UsageFreshness {
    static func text(_ item: ActivitySourceHealth) -> String {
        let state: String
        switch item.phase {
        case .checking: state = tr("wird geprüft; Werte können unvollständig sein")
        case .success: state = tr("eingeschränkte Abdeckung")
        case .cached: state = tr("gespeicherter Stand; noch nicht erneut geprüft")
        case .stale: state = tr("Abruf unvollständig; letzte Werte bleiben erhalten")
        case .unavailable:
            state = item.lastSuccess == nil ? tr("nicht verfügbar; kein erfolgreicher Abruf belegt") : tr("nicht verfügbar; gespeicherte Historie nicht lesbar")
        case .retained: state = tr("Quelle entfernt; gespeicherte Historie")
        }
        let success = item.lastSuccess.map {
            tr("Letzter erfolgreicher Abruf: {0}.", $0.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Localization.locale)))
        } ?? tr("Letzter erfolgreicher Abruf unbekannt.")
        return "\(item.label): \(state). \(success)" + (item.coverage?.first.map { " \($0)" } ?? "")
    }
}

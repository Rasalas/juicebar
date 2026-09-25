import SwiftUI
import JuicebarCore

enum Palette {
    private static func adaptive(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
    }
    static let accent = adaptive(NSColor(red: 0.69, green: 0.29, blue: 0.07, alpha: 1), NSColor(red: 1, green: 0.66, blue: 0.36, alpha: 1))
    static let green = adaptive(NSColor(red: 0.16, green: 0.48, blue: 0.36, alpha: 1), NSColor(red: 0.4, green: 0.78, blue: 0.62, alpha: 1))
    static let sidebar = adaptive(NSColor(red: 0.95, green: 0.94, blue: 0.92, alpha: 1), NSColor(red: 0.14, green: 0.15, blue: 0.15, alpha: 1))
    static func provider(_ kind: ProviderKind) -> Color {
        switch kind {
        case .codex: return adaptive(NSColor(red: 0.16, green: 0.39, blue: 0.78, alpha: 1), NSColor(red: 0.42, green: 0.66, blue: 1, alpha: 1))
        case .claude: return adaptive(NSColor(red: 0.73, green: 0.38, blue: 0.26, alpha: 1), NSColor(red: 0.93, green: 0.62, blue: 0.45, alpha: 1))
        case .opencodeGo, .opencodeZen: return adaptive(NSColor(white: 0.38, alpha: 1), NSColor(white: 0.75, alpha: 1))
        default: return Color(red: 0.52, green: 0.42, blue: 0.27)
        }
    }
}

struct ProviderMark: View {
    var kind: ProviderKind
    var size: CGFloat = 36
    var body: some View {
        Group {
            if kind == .opencodeGo || kind == .opencodeZen {
                OpenCodeMark().padding(size * 0.17)
            } else if let image = ProviderArtwork.image(kind) {
                Image(nsImage: image).resizable().renderingMode(.template).scaledToFit().padding(size * 0.17)
            } else { Image(systemName: kind.symbol).font(.system(size: size * 0.43, weight: .semibold)) }
        }.frame(width: size, height: size).foregroundStyle(Palette.provider(kind))
            .background(Palette.provider(kind).opacity(0.09), in: RoundedRectangle(cornerRadius: size * 0.28))
            .accessibilityHidden(true)
    }
}

struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.07)))
    }
}

struct PageHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 30, weight: .semibold, design: .rounded)).tracking(-0.6)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.bottom, 12)
    }
}

struct QuotaBar: View {
    let window: QuotaWindow
    let color: Color
    let now: Date
    var compact = false
    @Environment(\.quotaDisplay) private var mode
    private var displayed: Double { mode.value(used: window.usedPercent) }
    private var expired: Bool { window.resetsAt.map { $0 <= now } ?? false }
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(tr(window.title)).font(.system(size: compact ? 12 : 13, weight: .medium))
                Spacer()
                Text(expired ? "—" : "\(Int(displayed.rounded()))")
                    .font(.system(size: compact ? 18 : 27, weight: .medium, design: .rounded)).monospacedDigit()
                if !expired { Text(mode == .remaining ? tr("% übrig") : tr("% verbraucht")).font(.system(size: compact ? 10 : 11)).foregroundStyle(.secondary) }
            }
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    Capsule().fill(color.opacity(0.12)).frame(height: 6).offset(y: compact ? 7 : 12)
                    Capsule().fill(expired ? Color.secondary : window.usedPercent >= 90 ? Color.red : color)
                        .frame(width: max(0, proxy.size.width * min(displayed, 100) / 100), height: 6)
                        .offset(y: compact ? 7 : 12)
                    if !expired, let ideal = window.idealPercent(at: now) {
                        Image(systemName: "diamond.fill")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.primary)
                            .frame(width: 10, height: 10)
                            // Half of the diamond overlaps the bar: center at its upper edge, y = 12.
                            .offset(x: max(0, min(proxy.size.width - 10, proxy.size.width * mode.value(used: ideal) / 100 - 5)), y: compact ? 2 : 7)
                            .help(tr("Sollstand bei gleichmäßigem Verbrauch: {0} %", Int(mode.value(used: ideal).rounded())))
                    }
                }
                .frame(height: compact ? 13 : 18, alignment: .topLeading)
            }.frame(height: compact ? 13 : 18)
            HStack(spacing: 4) {
                if let reset = window.resetsAt {
                    Image(systemName: "arrow.clockwise").font(.system(size: 9))
                    Text(expired ? tr("Reset erreicht · warte auf neuen Stand") : tr("Reset {0}", relativeTime(reset, now: now)))
                        .help(reset.formatted(Date.FormatStyle(date: .complete, time: .shortened).locale(Localization.locale)))
                } else { Text(tr("Resetzeit nicht verfügbar")) }
                Spacer(minLength: 0)
                if let ideal = window.idealPercent(at: now), !expired {
                    Label(tr("Soll {0} %", Int(mode.value(used: ideal).rounded())), systemImage: "diamond.fill")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.primary)
                        .help(tr("Erwarteter Füllstand bei gleichmäßiger Nutzung über das gesamte Zeitfenster."))
                }
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("{0}, {1} Prozent {2}{3}", window.title, Int(displayed.rounded()), mode == .remaining ? tr("übrig") : tr("verbraucht"), expired ? tr(", Wert abgelaufen") : ""))
    }
}

func relativeTime(_ date: Date, now: Date = Date()) -> String {
    let delta = date.timeIntervalSince(now)
    if delta <= 0 { return tr("jetzt") }
    if delta < 3600 { return tr("in {0} Min.", max(1, Int(delta / 60))) }
    if delta < 86400 { return tr("in {0} Std. {1} Min.", Int(delta / 3600), Int(delta.truncatingRemainder(dividingBy: 3600) / 60)) }
    return tr("in {0} Tagen", Int(ceil(delta / 86400)))
}

func updatedText(_ date: Date?, now: Date) -> String {
    guard let date else { return tr("Noch nicht abgerufen") }
    let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
    if minutes < 1 { return tr("Gerade aktualisiert") }
    if minutes < 60 { return tr("Stand vor {0} Min.", minutes) }
    return tr("Stand {0}", date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Localization.locale)))
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(Palette.accent)
            Text(title).font(.system(size: 18, weight: .semibold))
            Text(message).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 410)
        }.padding(36).frame(maxWidth: .infinity)
    }
}

/// The original OpenCode mark has a separate shaded inner panel, which template tinting loses.
private struct OpenCodeMark: View {
    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width, proxy.size.height) / 375
            let transform = CGAffineTransform(scaleX: scale, y: scale)
            Path { path in
                path.addRect(CGRect(x: 127.5, y: 157.5, width: 120, height: 120), transform: transform)
            }.fill(Color.primary.opacity(0.26))
            Path { path in
                path.addRect(CGRect(x: 67.5, y: 37.5, width: 240, height: 300), transform: transform)
                path.addRect(CGRect(x: 127.5, y: 97.5, width: 120, height: 180), transform: transform)
            }.fill(Color.primary.opacity(0.86), style: FillStyle(eoFill: true))
        }
    }
}

struct ResetAvailability: View {
    let snapshot: AccountSnapshot
    let now: Date
    private var expiry: Date? {
        snapshot.benefits.filter { $0.status == .available && $0.count > 0 }
            .compactMap(\.expiresAt).min()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            let count = snapshot.benefitCount ?? 0
            Label("\(count) \(count == 1 ? tr("Reset verfügbar") : tr("Resets verfügbar"))", systemImage: "arrow.counterclockwise")
                .foregroundStyle(Palette.accent)
            if let expiry {
                Text(expiry <= now ? tr("Ablauf erreicht · neuer Stand ausstehend") :
                     "\(count == 1 ? tr("Läuft") : tr("Nächster Ablauf")) \(relativeTime(expiry, now: now))\(count == 1 ? tr(" ab") : "") · \(expiry.formatted(.dateTime.day().month(.abbreviated).hour().minute()))")
                    .foregroundStyle(.secondary)
                    .help(expiry.formatted(Date.FormatStyle(date: .complete, time: .shortened).locale(Localization.locale)))
            } else {
                Text(tr("Ablaufdatum nicht verfügbar")).foregroundStyle(.secondary)
            }
        }.font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
    }
}

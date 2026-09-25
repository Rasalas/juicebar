import SwiftUI
import AppKit
import JuicebarCore

private struct QuotaDisplayKey: EnvironmentKey { static let defaultValue = QuotaDisplay.remaining }
extension EnvironmentValues {
    var quotaDisplay: QuotaDisplay { get { self[QuotaDisplayKey.self] } set { self[QuotaDisplayKey.self] = newValue } }
}

struct JuiceButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .foregroundStyle(prominent ? Palette.accent : Color.primary.opacity(0.85))
            .background {
                RoundedRectangle(cornerRadius: 9)
                    .fill(prominent ? Palette.accent.opacity(configuration.isPressed ? 0.24 : 0.13) : Color.primary.opacity(configuration.isPressed ? 0.12 : 0.045))
            }
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(prominent ? Palette.accent.opacity(0.24) : Color.primary.opacity(0.1)))
            .opacity(enabled ? 1 : 0.4).contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

struct GlassOutline: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        path.move(to: point(0.12, 0.08)); path.addLine(to: point(0.88, 0.08))
        path.addLine(to: point(0.77, 0.86)); path.addQuadCurve(to: point(0.67, 0.94), control: point(0.76, 0.94))
        path.addLine(to: point(0.33, 0.94)); path.addQuadCurve(to: point(0.23, 0.86), control: point(0.24, 0.94))
        path.closeSubpath(); return path
    }
}
struct JuiceGlass: View {
    let fill: Double
    var color: Color = Palette.accent
    var stale = false
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                GlassOutline().fill(color.opacity(0.06))
                Rectangle().fill(color.gradient).frame(height: proxy.size.height * (0.06 + 0.86 * max(0, min(fill, 1))))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).clipShape(GlassOutline())
                GlassOutline().stroke(color.opacity(stale ? 0.4 : 0.8), lineWidth: 1.4)
                if stale { Image(systemName: "questionmark").font(.system(size: 10, weight: .bold)).frame(maxHeight: .infinity) }
            }.opacity(stale ? 0.55 : 1)
        }.accessibilityHidden(true)
    }
}

enum ProviderArtwork {
    private static let assets: [String: NSImage] = Dictionary(uniqueKeysWithValues: ["openai", "claude", "opencode"].compactMap { name in
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"), let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true; return (name, image)
    })
    static func image(_ kind: ProviderKind) -> NSImage? {
        switch kind {
        case .codex, .openaiAPI: return assets["openai"]
        case .claude, .anthropicAPI: return assets["claude"]
        case .opencodeGo, .opencodeZen: return assets["opencode"]
        default: return nil
        }
    }
}

struct JuiceSegments<Selection: Hashable>: View {
    let title: String
    @Binding var selection: Selection
    let options: [(String, Selection)]
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        HStack(spacing: 3) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index], selected = option.1 == selection
                Button { selection = option.1 } label: {
                    Text(option.0).font(.system(size: 11, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Palette.accent : Color.secondary)
                        .frame(maxWidth: .infinity).padding(.horizontal, 9).padding(.vertical, 7)
                        .background(selected ? Palette.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Palette.accent.opacity(0.22) : Color.clear))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            }
        }.padding(3).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .opacity(enabled ? 1 : 0.4).accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}

struct JuiceMenuPicker<Selection: Hashable>: View {
    let title: String
    @Binding var selection: Selection
    let options: [(String, Selection)]
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13))
            Spacer(minLength: 8)
            Menu {
                ForEach(options.indices, id: \.self) { index in
                    Button { selection = options[index].1 } label: {
                        if selection == options[index].1 { Label(options[index].0, systemImage: "checkmark") }
                        else { Text(options[index].0) }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Text(options.first { $0.1 == selection }?.0 ?? tr("Auswählen")).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 11).padding(.vertical, 8)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.1)))
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).frame(maxWidth: 245)
                .accessibilityLabel(title).accessibilityValue(options.first { $0.1 == selection }?.0 ?? tr("Auswählen"))
        }.opacity(enabled ? 1 : 0.4)
    }
}

import SwiftUI
import JuicebarCore

enum Palette {
    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
    private static func adaptive(_ light: NSColor, _ dark: NSColor) -> Color { Color(nsColor: dynamic(light, dark)) }
    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor { NSColor(red: red, green: green, blue: blue, alpha: 1) }
    static let accent = adaptive(rgb(0.69, 0.29, 0.07), rgb(1, 0.66, 0.36))
    // Amber, not orange: Claude's brand colour must never read as a warning.
    static let warningColor = dynamic(rgb(0.62, 0.42, 0), rgb(1, 0.8, 0.25))
    static let criticalColor = NSColor.systemRed
    static let warning = Color(nsColor: warningColor)
    static let critical = Color(nsColor: criticalColor)
    static let green = adaptive(rgb(0.16, 0.48, 0.36), rgb(0.4, 0.78, 0.62))
    static let sidebar = adaptive(rgb(0.95, 0.94, 0.92), rgb(0.14, 0.15, 0.15))
    static func providerColor(_ kind: ProviderKind) -> NSColor {
        switch kind {
        case .codex: return dynamic(rgb(0.16, 0.39, 0.78), rgb(0.42, 0.66, 1))
        case .claude: return dynamic(rgb(0.73, 0.38, 0.26), rgb(0.93, 0.62, 0.45))
        case .opencodeGo, .opencodeZen: return dynamic(NSColor(white: 0.38, alpha: 1), NSColor(white: 0.75, alpha: 1))
        case .openaiAPI: return dynamic(rgb(0.05, 0.5, 0.45), rgb(0.35, 0.8, 0.72))
        case .anthropicAPI: return dynamic(rgb(0.45, 0.33, 0.72), rgb(0.7, 0.6, 0.95))
        case .openrouter: return dynamic(rgb(0.66, 0.24, 0.5), rgb(0.93, 0.55, 0.78))
        }
    }
    static func provider(_ kind: ProviderKind) -> Color { Color(nsColor: providerColor(kind)) }
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
            Text(subtitle).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.bottom, 12)
    }
}

struct QuotaBar: View {
    let window: QuotaWindow
    let color: Color
    let now: Date
    var compact = false
    var status: QuotaStatus = .unavailable
    var reach: WeeklyReach?
    var workPlan: WorkPlanTarget?
    @State private var showingDetails = false
    @FocusState private var detailsFocused: Bool
    @Environment(\.quotaDisplay) private var mode
    private var displayed: Double { mode.value(used: window.usedPercent) }
    private var expired: Bool { window.resetsAt.map { $0 <= now } ?? false }
    private var weeklyTarget: WeeklyReach? { reach.flatMap { !expired && $0.shortWindowID == window.id ? $0 : nil } }
    private var weeklyReach: WeeklyReach? { reach.flatMap { !expired && $0.longWindowID == window.id ? $0 : nil } }
    private var workRemaining: Double? {
        guard !expired, let workPlan else { return nil }
        return workPlan.longWindowID == window.id ? workPlan.targetRemainingLong : workPlan.targetRemainingShort
    }
    private var workWeek: WorkPlanTarget? { workPlan.flatMap { !expired && $0.longWindowID == window.id ? $0 : nil } }
    private var barHeight: CGFloat { workRemaining == nil ? (compact ? 13 : 18) : (compact ? 18 : 23) }
    private var weeklyTargetPointsRight: Bool {
        guard let weeklyTarget, let ideal = window.idealPercent(at: now) else { return mode == .used }
        let target = mode.value(used: 100 - weeklyTarget.targetRemainingShort)
        return target == mode.value(used: ideal) ? mode == .used : target > mode.value(used: ideal)
    }
    private var barY: CGFloat { compact ? 7 : 12 }
    /// The vertical centerline, shared by the full diamond's tips and the half diamond's cut edge.
    private func markerX(used: Double, width: CGFloat) -> CGFloat {
        width * mode.value(used: used) / 100 - 5
    }
    var body: some View {
        Button { showingDetails.toggle() } label: {
            VStack(alignment: .leading, spacing: compact ? 4 : 10) {
                titleRow
                quotaTrack
                captions
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($detailsFocused)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(detailsFocused ? Palette.accent : .clear, lineWidth: 2).padding(-4))
        .popover(isPresented: $showingDetails, arrowEdge: .bottom) { details.font(.subheadline).padding(12) }
        .help(detailText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("{0}, {1} Prozent {2}{3}", window.title, Int(displayed.rounded()), mode == .remaining ? tr("übrig") : tr("verbraucht"), expired ? tr(", Wert abgelaufen") : "")
                            + (reachTitle.isEmpty ? "" : ". \(reachTitle)"))
        .accessibilityValue(([statusTitle] + detailRows.map { "\($0.0): \($0.1)" } + [detailExplanation]).filter { !$0.isEmpty }.joined(separator: ". "))
    }
    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(tr(window.title)).font((compact ? Font.callout : .body).weight(.medium))
            Spacer()
            Text(expired ? "—" : "\(Int(displayed.rounded()))")
                .font(.system(size: compact ? 18 : 27, weight: .medium, design: .rounded)).monospacedDigit()
            if !expired { Text(mode == .remaining ? tr("% übrig") : tr("% verbraucht")).font(compact ? .caption : .subheadline).foregroundStyle(.secondary) }
        }
    }
    private var quotaTrack: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Capsule().fill(color.opacity(0.12)).frame(height: 6).offset(y: compact ? 7 : 12)
                Capsule().fill(expired ? Color.secondary : color)
                    .frame(width: max(0, proxy.size.width * min(displayed, 100) / 100), height: 6)
                    .offset(y: compact ? 7 : 12)
                if !expired, let ideal = window.idealPercent(at: now), window.usedPercent - ideal > 1 {
                    // Usage ahead of the even pace, between fill end and diamond in either display mode.
                    let edges = [displayed, mode.value(used: ideal)].map { proxy.size.width * min(max($0, 0), 100) / 100 }
                    Hatch().stroke(Color.primary.opacity(0.5), lineWidth: 1).clipShape(Capsule())
                        .frame(width: edges.max()! - edges.min()!, height: 6)
                        .offset(x: edges.min()!, y: compact ? 7 : 12)
                }
                if let weeklyReach, weeklyReach.expiring >= 0.5 {
                    // What stays unused at the reset: the start of the fill when remaining, the end of the track when used.
                    let edges = [mode.value(used: 100), mode.value(used: 100 - weeklyReach.expiring)].map { proxy.size.width * min(max($0, 0), 100) / 100 }
                    ExpiryPattern(range: edges.min()!...edges.max()!).frame(width: proxy.size.width, height: 6)
                        .clipShape(Capsule()).offset(y: barY)
                }
                if let weeklyTarget {
                    WeeklyTargetMarker(height: 10, pointsRight: weeklyTargetPointsRight)
                        // The lower corner anchors x; both diamonds share the same vertical center.
                        .offset(x: markerX(used: 100 - weeklyTarget.targetRemainingShort, width: proxy.size.width),
                                y: barY - 5)
                }
                if let workRemaining {
                    WorkPlanMarker()
                        .offset(x: markerX(used: 100 - workRemaining, width: proxy.size.width),
                                y: barY + 1)
                }
                if !expired, let ideal = window.idealPercent(at: now) {
                    QuotaDiamond()
                        // Half of the diamond overlaps the bar: center at its upper edge, y = 12.
                        .offset(x: markerX(used: ideal, width: proxy.size.width), y: barY - 5)
                }
            }
            .frame(height: barHeight, alignment: .topLeading)
        }.frame(height: barHeight)
    }
    private var captions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                resetLabel.fixedSize()
                Spacer(minLength: 0)
                statusLabel.fixedSize()
                reachLabel.fixedSize()
            }
            VStack(alignment: .leading, spacing: 3) {
                resetLabel
                statusLabel
                reachLabel
            }
        }.font(.subheadline)
    }
    private var resetLabel: some View {
        HStack(spacing: 4) {
            if let reset = window.resetsAt {
                Image(systemName: "arrow.clockwise").font(.caption2).foregroundStyle(.secondary)
                Text(expired ? tr("Reset erreicht · warte auf neuen Stand") : tr("Reset {0}", relativeTime(reset, now: now)))
                    .foregroundStyle(expired ? .secondary : .primary)
            } else if window.duration.map({ abs($0 - 18000) <= 1800 }) == true, window.usedPercent == 0 {
                Text(tr("Startet bei Nutzung")).foregroundStyle(.secondary)
            } else { Text(tr("Resetzeit nicht verfügbar")).foregroundStyle(.secondary) }
        }
    }
    @ViewBuilder private var statusLabel: some View {
        if status != .unavailable, !expired {
            HStack(spacing: 3) {
                if status == .exhausted { Image(systemName: "exclamationmark.circle.fill") }
                else { Image(systemName: "exclamationmark.triangle") }
                Text(statusTitle)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(status == .exhausted ? Palette.critical : Palette.warning)
        }
    }
    @ViewBuilder private var reachLabel: some View {
        if workRemaining == nil, weeklyReach != nil, !reachTitle.isEmpty {
            let expiring = (weeklyReach?.expiring ?? 0) >= 0.5
            HStack(spacing: 4) {
                if expiring { ExpiryPattern.swatch }
                Text(reachTitle)
            }
            .font(expiring ? .subheadline.weight(.medium) : .subheadline)
            .foregroundStyle(expiring ? Palette.warning : .secondary)
        }
    }
    private var targetValue: String {
        guard let target = weeklyTarget else { return "" }
        let left = Int(target.targetRemainingShort.rounded())
        guard left >= 1 else { return tr("voll nutzen") }
        return mode == .remaining ? tr("≈ {0} % übrig", left) : tr("≈ {0} % verbraucht", 100 - left)
    }
    private var reachTitle: String {
        if let plan = workWeek {
            let amount = Int(plan.todayRemaining.rounded())
            return plan.isWorkday ? tr("Heute noch ≈ {0} %", amount) : tr("Puffer: ≈ {0} %", amount)
        }
        if let workRemaining {
            if workPlan?.isWorkday == false {
                return tr("Puffer: ≈ {0} %", Int(max(0, 100 - window.usedPercent - workRemaining).rounded()))
            }
            let value = Int(mode.value(used: 100 - workRemaining).rounded())
            return mode == .remaining ? tr("Tagesziel: ≈ {0} % übrig", value) : tr("Tagesziel: ≈ {0} % verbraucht", value)
        }
        if weeklyTarget != nil { return tr("Wochenziel: {0}", targetValue) }
        guard let reach = weeklyReach else { return "" }
        let expiring = Int(reach.expiring.rounded())
        if expiring >= 1 { return tr("≈ {0} % verfallen", expiring) }
        return tr("Braucht {0} von {1} Fenstern", windowCount(reach.windowsNeeded), windowCount(reach.windowsAvailable))
    }
    private func windowCount(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)).locale(Localization.locale))
    }
    private func outsideWorkText(_ value: Double) -> String {
        let count = value.formatted(.number.precision(.fractionLength(0...1)).locale(Localization.locale))
        return (value * 10).rounded() == 10 ? tr("≈ 1 Kontingent außerhalb der Arbeitszeit") : tr("≈ {0} Kontingente außerhalb der Arbeitszeit", count)
    }
    private var detailRows: [(String, String)] {
        var rows: [(String, String)] = []
        if !expired, let ideal = window.idealPercent(at: now) {
            rows.append((tr("Bei gleichmäßigem Verbrauch"), tr("{0} %", Int(mode.value(used: ideal).rounded()))))
            if let recovery = window.paceRecovery(at: now) {
                rows.append((tr("Ohne weitere Nutzung im Soll"), pointInTime(recovery)))
            } else {
                rows.append((tr("Puffer zum Soll"), tr("{0} Prozentpunkte", Int((ideal - window.usedPercent).rounded()))))
            }
        }
        if weeklyTarget != nil { rows.append((tr("Wochenziel"), targetValue)) }
        if let workRemaining {
            rows.append((tr("Arbeitsplan"), mode == .remaining ? tr("≈ {0} % übrig", Int(workRemaining.rounded())) : tr("≈ {0} % verbraucht", Int((100 - workRemaining).rounded()))))
            if let plan = workWeek {
                rows.append((plan.isWorkday ? tr("Heute noch") : tr("Puffer"), tr("≈ {0} %", Int(plan.todayRemaining.rounded()))))
                if let additional = plan.additionalWindows, additional >= 0.05 { rows.append((tr("Außerhalb der Arbeitszeit"), outsideWorkText(additional))) }
            }
        }
        if let reach = weeklyReach {
            let share = (100 * reach.ratio).formatted(.number.precision(.fractionLength(0...1)).locale(Localization.locale))
            rows.append((tr("Ein volles 5-Stunden-Fenster"), tr("≈ {0} % dieses Limits", share)))
            rows.append((tr("Nutzbare Fenster bis Reset"), windowCount(reach.windowsAvailable)))
            rows.append((tr("Benötigte Fenster"), windowCount(reach.windowsNeeded)))
            rows.append((tr("Geschätzt noch nutzbar"), tr("≈ {0} % dieses Limits", Int(min(reach.remainingLong, reach.capacity).rounded()))))
            if reach.expiring >= 0.5 { rows.append((tr("Verfällt trotz voller Nutzung"), tr("≈ {0} %", Int(reach.expiring.rounded())))) }
        }
        switch status {
        case .projectedPaceCrossing(let date) where !expired: rows.append((tr("Soll erreicht voraussichtlich"), pointInTime(date)))
        case .projectedExhaustion(let date) where !expired: rows.append((tr("Limit erreicht voraussichtlich"), pointInTime(date)))
        default: break
        }
        rows.append((tr("Reset"), window.resetsAt.map(pointInTime) ?? tr("Resetzeit nicht verfügbar")))
        return rows
    }
    private var detailExplanation: String {
        [window.supportsPace ? "" : tr("Kein Sollwert: Der Anbieter nennt keinen Fensterbeginn."), expired ? "" : statusHelp,
         weeklyTarget == nil && weeklyReach == nil ? "" : tr("Das Wochenziel verteilt den Wochenrest auf die verbleibenden nutzbaren 5-Stunden-Fenster. Wie viel ein volles Fenster vom Wochenlimit verbraucht, wird aus den gemeldeten Limitständen geschätzt. Ein verfallender Rest bleibt rechnerisch selbst bei voller Nutzung dieser Fenster übrig. Andere Nutzungszeiten können das Ergebnis ändern. Ein letztes verkürztes Fenster zählt nur anteilig.")]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
    private var detailText: String {
        (detailRows.map { "\($0.0): \($0.1)" } + [detailExplanation]).filter { !$0.isEmpty }.joined(separator: "\n")
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(detailRows.indices, id: \.self) { index in
                detail(detailRows[index].0, detailRows[index].1)
            }
            if !detailExplanation.isEmpty {
                Text(detailExplanation).foregroundStyle(.secondary)
                    .frame(width: 260, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func detail(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).monospacedDigit()
        }.frame(width: 260)
    }
    private var statusTitle: String { expired ? "" : status.title(now: now) }
    private var statusHelp: String {
        switch status {
        case .unavailable: return ""
        case .projectedPaceCrossing:
            return tr("Bei deinem zuletzt gemessenen Tempo erreichst du voraussichtlich den Sollstand. Die Bewegung der Raute ist eingerechnet. Danach verbrauchst du mehr als gleichmäßig vorgesehen, das Kontingent ist aber noch nicht leer.")
        case .exhausted:
            return tr("Das gemeldete Kontingent ist ausgeschöpft. Warte auf den Reset oder löse eine verfügbare Reset-Gutschrift ein.")
        case .projectedExhaustion:
            return tr("Bei deinem zuletzt gemessenen Tempo ist das Kontingent voraussichtlich vor dem Reset aufgebraucht. Die Schätzung ändert sich mit deiner Nutzung.")
        }
    }
}

extension QuotaStatus {
    /// Shared by the quota bars and the menu bar's VoiceOver summary.
    func title(now: Date) -> String {
        switch self {
        case .unavailable: return ""
        case .exhausted: return tr("Limit erreicht")
        case .projectedPaceCrossing(let date):
            return tr("Über Soll in {0}", durationText(date.timeIntervalSince(now)))
        case .projectedExhaustion(let date):
            return tr("Limit in {0}", durationText(date.timeIntervalSince(now)))
        }
    }
    var isAlert: Bool {
        switch self { case .exhausted, .projectedExhaustion: return true; default: return false }
    }
}

private struct Hatch: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for x in stride(from: rect.minX - rect.height, to: rect.maxX, by: 3) {
            path.move(to: CGPoint(x: x, y: rect.maxY)); path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
        }
        return path
    }
}

struct QuotaDiamond: View {
    var size: CGFloat = 10
    var body: some View {
        Image(systemName: "diamond.fill")
            .font(.system(size: size, weight: .semibold)).foregroundStyle(.primary)
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct WorkPlanMarker: View {
    var body: some View {
        Image(systemName: "diamond.fill").font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Palette.green).frame(width: 10, height: 10).accessibilityHidden(true)
    }
}

struct QuotaLegend: View {
    var weekly: Bool = false
    var expiring: Bool = false
    var workPlan: Bool = false
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { entries }
            VStack(alignment: .leading, spacing: 6) { entries }
        }
    }
    @ViewBuilder private var entries: some View {
        Label { Text(tr("Zeit-Soll")) } icon: { QuotaDiamond(size: 9) }
        if weekly { Label { Text(tr("Wochenziel")) } icon: { WeeklyTargetMarker(height: 11) } }
        if workPlan { Label { Text(tr("Arbeitsplan")) } icon: { WorkPlanMarker() } }
        if expiring { Label { Text(tr("Verfällt trotz voller Nutzung")) } icon: { ExpiryPattern.swatch } }
    }
}

/// The same pace diamond, clipped at its center. Its lower corner anchors the weekly target horizontally.
struct WeeklyTargetMarker: View {
    var height: CGFloat
    var pointsRight = false
    var body: some View {
        QuotaDiamond(size: height)
            .mask(alignment: pointsRight ? .trailing : .leading) {
                UnevenRoundedRectangle(
                    topLeadingRadius: pointsRight ? height * 0.12 : 0,
                    bottomLeadingRadius: pointsRight ? height * 0.12 : 0,
                    bottomTrailingRadius: pointsRight ? 0 : height * 0.12,
                    topTrailingRadius: pointsRight ? 0 : height * 0.12,
                    style: .circular
                ).frame(width: height / 2, height: height)
            }
    }
}

/// Segmented amber stripes for weekly quota that expires even with full use; diagonal hatching means ahead of pace.
struct ExpiryPattern: View {
    var range: ClosedRange<CGFloat>
    static var swatch: some View {
        ExpiryPattern(range: 0...14).frame(width: 14, height: 6).clipShape(Capsule()).accessibilityHidden(true)
    }
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(x: range.lowerBound, y: 0, width: range.upperBound - range.lowerBound, height: size.height)
            context.fill(Path(rect), with: .color(Color(nsColor: .textBackgroundColor)))
            for x in stride(from: rect.minX + 0.5, to: rect.maxX, by: 3) {
                context.fill(Path(CGRect(x: x, y: 0, width: min(1.5, rect.maxX - x), height: size.height)), with: .color(Palette.warning))
            }
        }
    }
}

func pointInTime(_ date: Date) -> String {
    date.formatted(Date.FormatStyle(locale: Localization.locale).weekday(.abbreviated).day().month(.abbreviated).hour().minute())
}

func relativeTime(_ date: Date, now: Date = Date()) -> String {
    let delta = date.timeIntervalSince(now)
    return delta <= 0 ? tr("jetzt") : tr("in {0}", durationText(delta))
}

func updatedText(_ date: Date?, now: Date) -> String {
    guard let date else { return tr("Noch nicht abgerufen") }
    let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
    if minutes < 1 { return tr("Gerade aktualisiert") }
    if minutes < 60 { return tr("Stand vor {0} Min.", minutes) }
    return tr("Stand {0}", date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Localization.locale)))
}

func moneyText(_ metric: MoneyMetric) -> String {
    metric.currency == "Credits" ? "\(metric.amount.formatted(.number.precision(.fractionLength(0)).locale(Localization.locale))) Credits"
        : metric.amount.formatted(.currency(code: metric.currency).locale(Localization.locale))
}

/// A stale value shows its age; "last value" alone does not say whether it is minutes or days old.
func lastValueText(_ date: Date, now: Date) -> String {
    now.timeIntervalSince(date) < 60 ? tr("Letzter Stand") : updatedText(date, now: now)
}

/// Keeps a refresh error next to its account and offers the next step.
struct AccountFailureView: View {
    let store: AppStore
    let account: AccountConfiguration
    let failure: String
    @State private var copied = false
    private var loginCommand: String? {
        failure == ProviderFailure.authentication.localizedDescription ? CLISetupHelp.loginCommand(for: account.provider) : nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning).accessibilityHidden(true)
                Text(failure).fixedSize(horizontal: false, vertical: true)
            }
            if let loginCommand {
                Text(tr("Im Terminal anmelden: {0}", loginCommand)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack(spacing: 6) {
                if let loginCommand {
                    Button(copied ? tr("Kopiert") : tr("Kopieren")) {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(loginCommand, forType: .string); copied = true
                    }.accessibilityLabel(tr("Befehl kopieren"))
                }
                Button(tr("Einrichten")) { DashboardWindow.shared.show(store: store, page: .accounts, editing: account.id) }
                Button(tr("Deaktivieren")) {
                    var disabled = account; disabled.enabled = false
                    do { try store.saveAccount(disabled, secret: "") } catch { store.storageError = error.localizedDescription }
                }.help(tr("Verbrauch für dieses Konto nicht mehr abrufen"))
            }.buttonStyle(JuiceButtonStyle())
        }
        .font(.subheadline)
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(Palette.accent)
            Text(title).font(.title2.weight(.semibold))
            Text(message).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 410)
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
            Label(count == 1 ? tr("1 Reset-Gutschrift verfügbar") : tr("{0} Reset-Gutschriften verfügbar", count), systemImage: "arrow.counterclockwise")
                .foregroundStyle(Palette.warning)
            if let expiry {
                Text(expiry <= now ? tr("Ablauf erreicht · neuer Stand ausstehend") :
                     "\(count == 1 ? tr("Läuft") : tr("Nächster Ablauf")) \(relativeTime(expiry, now: now))\(count == 1 ? tr(" ab") : "") · \(expiry.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Localization.locale)))")
                    .foregroundStyle(.secondary)
                    .help(expiry.formatted(Date.FormatStyle(date: .complete, time: .shortened).locale(Localization.locale)))
            } else {
                Text(tr("Ablaufdatum nicht verfügbar")).foregroundStyle(.secondary)
            }
        }.font(.subheadline).fixedSize(horizontal: false, vertical: true)
    }
}

import AppKit
import SwiftUI
import JuicebarCore

/// Fixed-width limit slots preserve their positions as values change or a reset passes.
enum MenuLimitImage {
    /// Without an explicit appearance, colours resolve against the status button that draws the image.
    static func make(meters: [TrayMeter], statuses: [QuotaStatus] = [], mode: QuotaDisplay, appearance: NSAppearance? = nil,
                     expiring: Bool, showsValue: Bool = false) -> NSImage {
        var positions: [CGFloat] = []
        var x: CGFloat = 3
        for index in meters.indices {
            if index > 0 { x += meters[index - 1].account.id == meters[index].account.id ? 3 : 9 }
            positions.append(x); x += 4
        }
        // Exhausted quota is an expected state; only forecasts need an outline.
        let alerts: [NSColor?] = meters.indices.map { index in
            guard statuses.indices.contains(index) else { return nil }
            switch statuses[index] {
            case .projectedPaceCrossing, .projectedExhaustion: return Palette.warningColor
            case .unavailable, .exhausted: return nil
            }
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let value: String? = showsValue && meters.count == 1 ? meters[0].window.flatMap { window in
            meters[0].expired ? nil : (mode.value(used: window.usedPercent) / 100).formatted(.percent.precision(.fractionLength(0)).locale(Localization.locale))
        } : nil
        let valueX = x + 4
        if let value { x = valueX + ceil((value as NSString).size(withAttributes: [.font: font]).width) }
        let width = max(16, x + 3 + (expiring ? 6 : 0))
        let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
            let draw = {
                if meters.isEmpty { drawLine(x: 6, value: nil, color: .secondaryLabelColor, stale: false, alert: nil) }
                for (index, meter) in meters.enumerated() {
                    let value = meter.expired ? nil : meter.window.map { mode.value(used: $0.usedPercent) / 100 }
                    drawLine(x: positions[index], value: value, color: Palette.providerColor(meter.account.provider),
                             stale: !meter.fresh, alert: alerts[index])
                }
                if let value {
                    let color = meters[0].fresh ? NSColor.labelColor : NSColor.secondaryLabelColor
                    (value as NSString).draw(at: NSPoint(x: valueX, y: 3.5), withAttributes: [.font: font, .foregroundColor: color])
                }
                if expiring {
                    NSColor.labelColor.setFill()
                    NSBezierPath(ovalIn: NSRect(x: width - 4, y: 17, width: 3, height: 3)).fill()
                }
            }
            if let appearance { appearance.performAsCurrentDrawingAppearance(draw) } else { draw() }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = tr("Kontingente")
        return image
    }

    private static func drawLine(x: CGFloat, value: Double?, color: NSColor, stale: Bool, alert: NSColor?) {
        let rect = NSRect(x: x, y: 2, width: 4, height: 18)
        let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        defer {
            // Forecasts stand apart from every provider colour.
            if let alert {
                let outline = NSBezierPath(roundedRect: rect.insetBy(dx: -0.75, dy: -0.75), xRadius: 2.75, yRadius: 2.75)
                alert.setStroke(); outline.lineWidth = 1.5; outline.stroke()
            }
        }
        guard let value, value.isFinite else {
            color.withAlphaComponent(0.85).setStroke()
            path.lineWidth = 1
            path.setLineDash([2, 2], count: 2, phase: 0)
            path.stroke()
            return
        }
        color.withAlphaComponent(value <= 0 ? 0.18 : 0.22).setFill(); path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        color.withAlphaComponent(stale ? 0.45 : 1).setFill()
        let height = 18 * max(0, min(1, value))
        if height > 0 {
            NSBezierPath(roundedRect: NSRect(x: x, y: 2, width: 4, height: height),
                         xRadius: min(2, height / 2), yRadius: min(2, height / 2)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        if stale {
            NSColor.labelColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: x + 1, y: 20, width: 2, height: 2)).fill()
        }
    }
}

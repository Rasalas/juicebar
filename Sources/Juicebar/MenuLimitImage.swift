import AppKit
import SwiftUI
import JuicebarCore

/// Fixed-width limit slots preserve their positions as values change or a reset passes.
enum MenuLimitImage {
    static func make(meters: [TrayMeter], mode: QuotaDisplay, dark: Bool, expiring: Bool) -> NSImage {
        var positions: [CGFloat] = []
        var x: CGFloat = 3
        for index in meters.indices {
            if index > 0 { x += meters[index - 1].account.id == meters[index].account.id ? 3 : 9 }
            positions.append(x); x += 4
        }
        let width = max(16, x + 3 + (expiring ? 6 : 0))
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
            appearance.performAsCurrentDrawingAppearance {
                if meters.isEmpty { drawLine(x: 6, value: nil, color: .secondaryLabelColor, stale: false) }
                for (index, meter) in meters.enumerated() {
                    let value = meter.expired ? nil : meter.window.map { mode.value(used: $0.usedPercent) / 100 }
                    drawLine(x: positions[index], value: value,
                             color: NSColor(Palette.provider(meter.account.provider)), stale: !meter.fresh)
                }
                if expiring {
                    NSColor.labelColor.setFill()
                    NSBezierPath(ovalIn: NSRect(x: width - 4, y: 17, width: 3, height: 3)).fill()
                }
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Kontingente"
        return image
    }

    private static func drawLine(x: CGFloat, value: Double?, color: NSColor, stale: Bool) {
        let rect = NSRect(x: x, y: 2, width: 4, height: 18)
        let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        guard let value, value.isFinite else {
            color.withAlphaComponent(0.85).setStroke()
            path.lineWidth = 1
            path.setLineDash([2, 2], count: 2, phase: 0)
            path.stroke()
            return
        }
        color.withAlphaComponent(0.22).setFill(); path.fill()
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

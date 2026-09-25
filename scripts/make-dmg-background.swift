import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
for scale in [1, 2] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640 * scale, pixelsHigh: 400 * scale,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform(); transform.scale(by: CGFloat(scale)); transform.concat()
    NSColor(srgbRed: 0.96, green: 0.95, blue: 0.92, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 640, height: 400).fill()
    func text(_ value: String, y: CGFloat, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        let string = value as NSString
        let width = string.size(withAttributes: attributes).width
        string.draw(at: NSPoint(x: (640 - width) / 2, y: y), withAttributes: attributes)
    }
    let ink = NSColor(srgbRed: 0.14, green: 0.16, blue: 0.14, alpha: 1)
    text("Juicebar", y: 322, size: 30, color: ink, weight: .semibold)
    text("Drag Juicebar to Applications to install.", y: 287, size: 15, color: ink)
    NSColor(srgbRed: 0.67, green: 0.43, blue: 0.18, alpha: 1).setStroke()
    let arrow = NSBezierPath(); arrow.lineWidth = 3; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 295, y: 200)); arrow.line(to: NSPoint(x: 345, y: 200))
    arrow.move(to: NSPoint(x: 335, y: 210)); arrow.line(to: NSPoint(x: 345, y: 200)); arrow.line(to: NSPoint(x: 335, y: 190)); arrow.stroke()
    text("macOS 14 or later · Apple Silicon", y: 48, size: 12, color: ink.withAlphaComponent(0.65))
    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "background.png" : "background@2x.png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}

import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
// Shared geometry for the website SVG, in-app PNG and macOS icon sizes.
let bars: [(x: Double, fill: Double, hex: String)] = [
    (13, 0.75, "6BA8FF"), (27, 0.40, "ED9E73"), (41, 0.90, "B3A3DF")
]
let updateAssets = CommandLine.arguments.contains("--update-assets")
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
if updateAssets {
    var svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 64 64\">\n  <rect width=\"64\" height=\"64\" rx=\"15\" fill=\"#242824\"/>\n"
    for bar in bars {
        svg += "  <g fill=\"#\(bar.hex)\">\n    <rect x=\"\(bar.x)\" y=\"11\" width=\"10\" height=\"42\" rx=\"5\" opacity=\".2\"/>\n"
        svg += "    <rect x=\"\(bar.x)\" y=\"\(53 - 42 * bar.fill)\" width=\"10\" height=\"\(42 * bar.fill)\" rx=\"5\"/>\n  </g>\n"
    }
    svg += "</svg>\n"
    for path in ["assets/juicebar.svg", "site/assets/juicebar.svg"] {
        try svg.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }
}
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("juicebar-\(UUID()).iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let s = CGFloat(pixels)
        let transform = NSAffineTransform()
        transform.translateX(by: s * 0.06, yBy: s * 0.94)
        transform.scaleX(by: s * 0.88 / 64, yBy: -s * 0.88 / 64)
        transform.concat()
        NSColor(srgbRed: 36 / 255, green: 40 / 255, blue: 36 / 255, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 64, height: 64), xRadius: 15, yRadius: 15).fill()
        for bar in bars {
            let rgb = UInt32(bar.hex, radix: 16)!
            let color = NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                                green: CGFloat((rgb >> 8) & 255) / 255,
                                blue: CGFloat(rgb & 255) / 255, alpha: 1)
            color.withAlphaComponent(0.2).setFill()
            NSBezierPath(roundedRect: NSRect(x: bar.x, y: 11, width: 10, height: 42), xRadius: 5, yRadius: 5).fill()
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: bar.x, y: 53 - 42 * bar.fill, width: 10, height: 42 * bar.fill), xRadius: 5, yRadius: 5).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        let png = bitmap.representation(using: .png, properties: [:])!
        try png.write(to: directory.appendingPathComponent(name))
        if pixels == 1024 {
            try png.write(to: destination.appendingPathComponent("Juicebar.png"))
            if updateAssets {
                try png.write(to: root.appendingPathComponent("Sources/Juicebar/Resources/juicebar.png"))
            }
        }
    }
}
let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", directory.path, "-o", destination.appendingPathComponent("Juicebar.icns").path]
try process.run(); process.waitUntilExit()
if process.terminationStatus != 0 { exit(process.terminationStatus) }

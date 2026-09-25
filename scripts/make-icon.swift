import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
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
        // The same segmented droplet as assets/juicebar.svg, in a macOS icon canvas.
        let transform = NSAffineTransform()
        transform.translateX(by: s * 0.06, yBy: s * 0.94)
        transform.scaleX(by: s * 0.88 / 64, yBy: -s * 0.88 / 64)
        transform.concat()
        NSColor(srgbRed: 36 / 255, green: 40 / 255, blue: 36 / 255, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 64, height: 64), xRadius: 15, yRadius: 15).fill()
        let drop = NSBezierPath()
        drop.move(to: NSPoint(x: 32, y: 9))
        drop.curve(to: NSPoint(x: 16, y: 38), controlPoint1: NSPoint(x: 28, y: 17), controlPoint2: NSPoint(x: 16, y: 27))
        drop.curve(to: NSPoint(x: 32, y: 54), controlPoint1: NSPoint(x: 16, y: 46.8366), controlPoint2: NSPoint(x: 23.1634, y: 54))
        drop.curve(to: NSPoint(x: 48, y: 38), controlPoint1: NSPoint(x: 40.8366, y: 54), controlPoint2: NSPoint(x: 48, y: 46.8366))
        drop.curve(to: NSPoint(x: 32, y: 9), controlPoint1: NSPoint(x: 48, y: 27), controlPoint2: NSPoint(x: 36, y: 17))
        drop.close()
        drop.addClip()
        NSColor(srgbRed: 1, green: 178 / 255, blue: 97 / 255, alpha: 1).setFill()
        for (y, height) in [(7.0, 21.0), (32.0, 8.0), (44.0, 12.0)] {
            NSBezierPath(rect: NSRect(x: 12, y: y, width: 40, height: height)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        let png = bitmap.representation(using: .png, properties: [:])!
        try png.write(to: directory.appendingPathComponent(name))
        if pixels == 1024 {
            try png.write(to: destination.appendingPathComponent("Juicebar.png"))
        }
    }
}
let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", directory.path, "-o", destination.appendingPathComponent("Juicebar.icns").path]
try process.run(); process.waitUntilExit()
if process.terminationStatus != 0 { exit(process.terminationStatus) }

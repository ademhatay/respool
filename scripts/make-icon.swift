// Draws the app icon and writes Support/AppIcon.icns.
// Usage: swift scripts/make-icon.swift
import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
    )
}

func drawIcon(in context: CGContext) {
    // The rounded tile, on the standard macOS icon grid.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, alpha: 0.28))
    context.addPath(tilePath)
    context.setFillColor(color(0x24262B))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(0x34373E), color(0x1D1F23)] as CFArray, locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient, start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: tile.minY), options: []
    )
    context.restoreGState()

    // The spool: two flanges with thread wound between them.
    let thread = color(0xF2683C)
    let threadShade = color(0xD4532B)
    let flange = color(0xF4EFE6)

    let wound = CGRect(x: 352, y: 352, width: 320, height: 320)
    context.addPath(CGPath(roundedRect: wound, cornerWidth: 26, cornerHeight: 26, transform: nil))
    context.setFillColor(thread)
    context.fillPath()

    // Windings: evenly spaced, slightly slanted lines across the thread.
    context.saveGState()
    context.addPath(CGPath(roundedRect: wound, cornerWidth: 26, cornerHeight: 26, transform: nil))
    context.clip()
    context.setStrokeColor(threadShade)
    context.setLineWidth(9)
    var y = wound.minY - 20
    while y < wound.maxY + 20 {
        context.move(to: CGPoint(x: wound.minX - 10, y: y))
        context.addLine(to: CGPoint(x: wound.maxX + 10, y: y + 26))
        y += 40
    }
    context.strokePath()
    context.restoreGState()

    for flangeY in [wound.maxY - 4, wound.minY - 68] as [CGFloat] {
        let rect = CGRect(x: 272, y: flangeY, width: 480, height: 72)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 36, cornerHeight: 36, transform: nil))
        context.setFillColor(flange)
        context.fillPath()
    }

    // The loose end of the thread, running off toward the edge of the screen.
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    context.setStrokeColor(thread)
    context.setLineWidth(20)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: wound.maxX - 4, y: 430))
    context.addCurve(
        to: CGPoint(x: 950, y: 250),
        control1: CGPoint(x: 790, y: 430), control2: CGPoint(x: 800, y: 250)
    )
    context.strokePath()
    context.restoreGState()
}

func render(pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    drawIcon(in: context)
    return bitmap.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    try render(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Support/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "wrote Support/AppIcon.icns" : "iconutil failed")

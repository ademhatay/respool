import AppKit
import SwiftUI

/// Developer tool: renders the panel to a PNG without showing a window, for checking the design.
enum Snapshot {
    static func render(library: Library, to path: String, dark: Bool, height: CGFloat) -> Bool {
        let size = NSSize(width: Metrics.panelWidth, height: height)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        let root = PanelView(library: library, close: {})
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.95, alpha: 1)))
            .clipShape(RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous))
            .padding(20)
            .background(Color(nsColor: dark ? NSColor(white: 0.08, alpha: 1) : NSColor(white: 0.80, alpha: 1)))

        let hosting = NSHostingView(rootView: root)
        hosting.appearance = appearance
        let frame = NSRect(x: 0, y: 0, width: size.width + 40, height: size.height + 40)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = hosting
        hosting.frame = frame
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        hosting.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(frame.width * scale), pixelsHigh: Int(frame.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return false }
        bitmap.size = frame.size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}

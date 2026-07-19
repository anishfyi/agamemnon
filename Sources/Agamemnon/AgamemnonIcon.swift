import AppKit
import SwiftUI

enum AgamemnonIcon {
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.addRepresentation(renderHelmet(pixels: 18))
        image.addRepresentation(renderHelmet(pixels: 36))
        image.isTemplate = true
        return image
    }

    private static func renderHelmet(pixels: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        NSColor.clear.setFill()
        rect.fill()
        NSColor.black.setFill()
        helmetPath(in: rect).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func helmetPath(in rect: NSRect) -> NSBezierPath {
        let w = rect.width
        let h = rect.height
        let path = NSBezierPath()

        // Crest
        path.move(to: NSPoint(x: w * 0.50, y: h * 0.96))
        path.line(to: NSPoint(x: w * 0.43, y: h * 0.76))
        path.line(to: NSPoint(x: w * 0.57, y: h * 0.76))
        path.close()

        // Dome + cheek guards (single silhouette)
        path.move(to: NSPoint(x: w * 0.16, y: h * 0.70))
        path.curve(
            to: NSPoint(x: w * 0.84, y: h * 0.70),
            controlPoint1: NSPoint(x: w * 0.16, y: h * 0.98),
            controlPoint2: NSPoint(x: w * 0.84, y: h * 0.98)
        )
        path.line(to: NSPoint(x: w * 0.98, y: h * 0.28))
        path.line(to: NSPoint(x: w * 0.82, y: h * 0.18))
        path.line(to: NSPoint(x: w * 0.70, y: h * 0.40))
        path.line(to: NSPoint(x: w * 0.62, y: h * 0.52))
        path.line(to: NSPoint(x: w * 0.38, y: h * 0.52))
        path.line(to: NSPoint(x: w * 0.30, y: h * 0.40))
        path.line(to: NSPoint(x: w * 0.18, y: h * 0.18))
        path.line(to: NSPoint(x: w * 0.02, y: h * 0.28))
        path.close()

        // Face opening cutout
        let face = NSBezierPath()
        face.move(to: NSPoint(x: w * 0.36, y: h * 0.52))
        face.line(to: NSPoint(x: w * 0.64, y: h * 0.52))
        face.line(to: NSPoint(x: w * 0.56, y: h * 0.22))
        face.line(to: NSPoint(x: w * 0.44, y: h * 0.22))
        face.close()
        path.append(face)
        path.windingRule = .evenOdd

        return path
    }
}

struct MenuBarIconView: View {
    var body: some View {
        Image(nsImage: AgamemnonIcon.menuBarImage())
            .renderingMode(.template)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

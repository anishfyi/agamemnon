import AppKit
import SwiftUI

enum AgamemnonIcon {
    /// The menu-bar mark, drawn rather than loaded from the logo PNG.
    ///
    /// macOS renders a menu-bar icon from its alpha channel and tints it for the current
    /// appearance, which requires a template image. The bundled logo is a fully opaque
    /// 1024x1024 square with no transparency, so using it here produced a muddy colored
    /// block that ignored dark mode and blurred at 16pt. A vector Corinthian helmet
    /// stays crisp at any size and tints correctly.
    static func menuBarImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            helmetPath(in: rect).fill()
            return true
        }
        // Template mode is what lets the menu bar recolor it for light and dark and for
        // the highlighted state when the menu is open.
        image.isTemplate = true
        return image
    }

    /// The full-colour mark, for in-window use where the logo art is appropriate.
    static func logoImage(size: CGFloat = 96) -> NSImage {
        // The bundled asset has been called both `agamemnon.png` and
        // `agamemnon-logo.png` across renames; try both before falling back to the
        // drawn mark so a rename never silently blanks the logo.
        if let image = loadImage(named: "agamemnon") ?? loadImage(named: "agamemnon-logo") {
            image.size = NSSize(width: size, height: size)
            return image
        }
        let rect = NSSize(width: size, height: size)
        let drawn = NSImage(size: rect, flipped: false) { r in
            NSColor.labelColor.setFill()
            helmetPath(in: r).fill()
            return true
        }
        return drawn
    }

    /// A forward-facing Corinthian helmet: dome, crest, and a T-shaped face opening
    /// split by the nose guard. Built in a normalised 100x100 space and scaled to fit,
    /// so it renders identically at 16pt in the menu bar and at 1024pt for the app icon.
    static func helmetPath(in rect: NSRect) -> NSBezierPath {
        let s = min(rect.width, rect.height) / 100.0
        let dx = rect.minX + (rect.width - 100 * s) / 2
        let dy = rect.minY + (rect.height - 100 * s) / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: dx + x * s, y: dy + y * s)
        }

        let path = NSBezierPath()

        // Crest: a plume arcing back over the dome.
        path.move(to: p(38, 82))
        path.curve(to: p(72, 92), controlPoint1: p(44, 96), controlPoint2: p(60, 98))
        path.curve(to: p(84, 74), controlPoint1: p(82, 88), controlPoint2: p(86, 82))
        path.curve(to: p(70, 78), controlPoint1: p(80, 76), controlPoint2: p(75, 77))
        path.curve(to: p(46, 74), controlPoint1: p(62, 79), controlPoint2: p(52, 78))
        path.close()

        // Helmet shell.
        path.move(to: p(26, 6))
        path.line(to: p(26, 50))
        path.curve(to: p(50, 84), controlPoint1: p(26, 70), controlPoint2: p(36, 84))
        path.curve(to: p(74, 50), controlPoint1: p(64, 84), controlPoint2: p(74, 70))
        path.line(to: p(74, 6))
        path.line(to: p(64, 6))
        path.line(to: p(64, 44))
        path.curve(to: p(50, 56), controlPoint1: p(64, 52), controlPoint2: p(58, 56))
        path.curve(to: p(36, 44), controlPoint1: p(42, 56), controlPoint2: p(36, 52))
        path.line(to: p(36, 6))
        path.close()

        // Face opening, then the nose guard put back inside it. With the even-odd rule
        // the opening subtracts from the shell and the guard adds back, so the classic
        // T-shaped slot appears without any path arithmetic.
        path.appendOval(in: NSRect(x: dx + 33 * s, y: dy + 46 * s, width: 34 * s, height: 22 * s))
        path.append(NSBezierPath(rect: NSRect(x: dx + 46 * s, y: dy + 30 * s, width: 8 * s, height: 32 * s)))

        path.windingRule = .evenOdd
        return path
    }

    private static func loadImage(named: String) -> NSImage? {
        let bundles: [Bundle] = [.main, Bundle.module]
        for bundle in bundles {
            if let url = bundle.url(forResource: named, withExtension: "png") {
                return NSImage(contentsOf: url)
            }
            if let url = bundle.url(forResource: named, withExtension: "png", subdirectory: "assets") {
                return NSImage(contentsOf: url)
            }
        }
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("assets/\(named).png"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/\(named).png"),
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return NSImage(contentsOf: url)
        }
        return nil
    }
}

struct MenuBarIconView: View {
    var body: some View {
        Image(nsImage: AgamemnonIcon.menuBarImage())
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

import AppKit
import SwiftUI

enum AgamemnonIcon {
    static func menuBarImage() -> NSImage {
        if let image = loadImage(named: "agamemnon-logo") {
            image.size = NSSize(width: 16, height: 16)
            return image
        }
        return fallbackImage()
    }

    static func logoImage(size: CGFloat = 96) -> NSImage {
        let image = loadImage(named: "agamemnon-logo") ?? fallbackImage()
        image.size = NSSize(width: size, height: size)
        return image
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

    private static func fallbackImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        NSColor.labelColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 12, height: 12)).fill()
        image.unlockFocus()
        image.isTemplate = true
        return image
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

// A standalone window for manual OCR/update testing. This is not part of the shipped app.
// Compile into an app bundle and use its buttons through normal UI interaction.
import AppKit

@MainActor
final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var secondaryWindow: NSWindow?
    private let page = NSTextField(labelWithString: "Page 123")
    private let backgroundMark = NSView(frame: CGRect(x: 650, y: 26, width: 6, height: 6))
    private var number = 123

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: CGRect(x: 80, y: 220, width: 720, height: 360),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "LineLens OCR QA"
        window.isReleasedWhenClosed = false
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 720, height: 360))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.white.cgColor
        let heading = NSTextField(labelWithString: "LineLens OCR test")
        heading.font = .systemFont(ofSize: 30, weight: .semibold)
        heading.textColor = .black
        heading.frame = CGRect(x: 40, y: 260, width: 600, height: 44)
        content.addSubview(heading)
        page.font = .systemFont(ofSize: 32)
        page.textColor = .black
        page.frame = CGRect(x: 40, y: 180, width: 600, height: 48)
        content.addSubview(page)
        let change = NSButton(title: "Change last digit", target: self, action: #selector(changeText))
        change.frame = CGRect(x: 40, y: 80, width: 180, height: 34)
        change.bezelStyle = .rounded
        content.addSubview(change)
        let background = NSButton(title: "Change background mark", target: self, action: #selector(changeBackground))
        background.frame = CGRect(x: 240, y: 80, width: 230, height: 34)
        background.bezelStyle = .rounded
        content.addSubview(background)
        backgroundMark.wantsLayer = true
        backgroundMark.layer?.backgroundColor = NSColor.white.cgColor
        content.addSubview(backgroundMark)
        window.contentView = content
        self.window = window
        if CommandLine.arguments.contains("--two-windows") {
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let secondary = NSWindow(contentRect: CGRect(x: 580, y: 150, width: 640, height: 320),
                                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
            secondary.title = "LineLens OCR QA · Secondary"
            secondary.isReleasedWhenClosed = false
            secondary.level = .floating
            secondary.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let label = NSTextField(labelWithString: "Secondary window only\nPage 987")
            label.font = .systemFont(ofSize: 28)
            label.textColor = .black
            label.frame = CGRect(x: 35, y: 150, width: 570, height: 100)
            let secondaryContent = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
            secondaryContent.wantsLayer = true
            secondaryContent.layer?.backgroundColor = NSColor.white.cgColor
            secondaryContent.addSubview(label)
            secondary.contentView = secondaryContent
            secondary.orderFront(nil)
            secondaryWindow = secondary
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func changeText() {
        number += 1
        page.stringValue = "Page \(number)"
    }

    @objc private func changeBackground() {
        backgroundMark.layer?.backgroundColor = backgroundMark.layer?.backgroundColor == NSColor.white.cgColor
            ? NSColor.black.cgColor : NSColor.white.cgColor
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
enum FixtureApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = FixtureDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

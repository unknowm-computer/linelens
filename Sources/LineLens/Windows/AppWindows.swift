import AppKit
import SwiftUI

@MainActor
final class AppWindows: NSObject, NSWindowDelegate {
    private unowned let model: AppModel
    let selection = RegionSelectionController()
    let windowSelection = WindowSelectionController()
    let overlay = TranslationOverlayController()
    private var results: NSPanel?
    private var settings: NSWindow?
    private var picker: NSWindow?
    private var welcome: NSWindow?
    private var closingPicker = false

    init(model: AppModel) {
        self.model = model
        super.init()
        // Keep the SwiftUI translation task hosted for overlay-only operation as well.
        let panel = ResultsPanel(contentRect: CGRect(x: 0, y: 0, width: 460, height: 600),
                                 styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.title = "LineLens · 인식 결과"
        panel.contentViewController = NSHostingController(rootView: ResultsView(model: model))
        panel.minSize = NSSize(width: 380, height: 360)
        panel.setContentSize(NSSize(width: 460, height: 600))
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.center()
        results = panel
        updateResultLevel()
    }

    func showResults() { results?.orderFrontRegardless() }
    func hideResults() { results?.orderOut(nil) }
    func updateResultLevel() { results?.level = model.settings.pinResults ? .floating : .normal }

    func showSettings() {
        if settings == nil {
            settings = makeWindow(title: "LineLens 설정", size: NSSize(width: 540, height: 650),
                                  view: SettingsView(model: model))
        }
        present(settings)
    }

    func showWelcome() {
        if welcome == nil {
            welcome = makeWindow(title: "LineLens 시작하기", size: NSSize(width: 460, height: 560),
                                 view: WelcomeView(model: model))
        }
        present(welcome)
    }

    func dismissWelcome() { welcome?.close() }

    func showWindowPicker() {
        closeWindowPicker()
        picker = makeWindow(title: "인식할 프로그램 창 선택", size: NSSize(width: 560, height: 460),
                            view: WindowPickerView(model: model) { [weak self] in self?.closeWindowPicker() })
        picker?.delegate = self
        present(picker)
    }

    func closeWindowPicker() {
        closingPicker = true
        picker?.close()
        picker = nil
        closingPicker = false
    }

    func prepareForSelection() {
        closeWindowPicker()
        let windows: [NSWindow?] = [results, settings, welcome]
        windows.forEach { $0?.orderOut(nil) }
    }

    func windowWillClose(_ notification: Notification) {
        guard !closingPicker, let window = notification.object as? NSWindow, window === picker else { return }
        picker = nil
        model.cancelSelection()
    }

    private func makeWindow<Content: View>(title: String, size: NSSize, view: Content) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(size)
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private final class ResultsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

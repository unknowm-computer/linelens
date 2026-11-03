import AppKit
import LineLensCore
import Observation
import SwiftUI

@MainActor
final class WindowSelectionController {
    private var panels: [NSPanel] = []
    private var views: [WindowSelectionView] = []
    private var candidates: [CGWindowID: WindowChoice] = [:]
    private var timer: Timer?
    private var screenObserver: (any NSObjectProtocol)?
    private var state = WindowSelectionState()
    private var onSelect: ((WindowChoice, Bool) -> Void)?
    private var onCancel: (() -> Void)?
    private var onShowList: (() -> Void)?

    func begin(windows: [WindowChoice], onSelect: @escaping (WindowChoice, Bool) -> Void,
               onCancel: @escaping () -> Void, onShowList: @escaping () -> Void) {
        cancel()
        candidates = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        state = WindowSelectionState()
        self.onSelect = onSelect
        self.onCancel = onCancel
        self.onShowList = onShowList
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        for screen in NSScreen.screens {
            let screenFrame = CaptureGeometry.flipScreenRect(screen.frame, mainDisplayHeight: mainHeight)
            let view = WindowSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size),
                                           screenFrame: screenFrame)
            let toolbar = NSHostingView(rootView: WindowSelectionToolbar(state: state,
                cancel: { [weak self] in self?.finishCancellation() },
                showList: { [weak self] in self?.finishWithList() }))
            let toolbarWidth = min(620, max(300, screen.frame.width - 48))
            let topInset = max(16, screen.frame.maxY - screen.visibleFrame.maxY + 12)
            toolbar.frame = CGRect(x: (view.bounds.width - toolbarWidth) / 2,
                                   y: topInset, width: toolbarWidth, height: 112)
            view.addSubview(toolbar)
            view.toolbarFrame = toolbar.frame
            view.onClick = { [weak self] point in self?.select(at: point) }
            let panel = WindowSelectionPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                            backing: .buffered, defer: false)
            panel.title = "LineLens · 클릭으로 창 선택"
            panel.isReleasedWhenClosed = false
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.acceptsMouseMovedEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = view
            panel.orderFrontRegardless()
            panels.append(panel)
            views.append(view)
        }
        updateHover()
        // Poll only during selection so a moving/closing window updates even
        // when the pointer is stationary. No global input monitor is needed.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishCancellation() }
        }
    }

    private func candidate(at point: CGPoint) -> WindowChoice? {
        guard let panel = panels.first(where: { $0.frame.contains(point) }),
              let view = panel.contentView as? WindowSelectionView else { return nil }
        let local = view.convert(panel.convertPoint(fromScreen: point), from: nil)
        guard !view.toolbarFrame.contains(local) else { return nil }
        // WindowServer hit testing respects the actual frontmost window. An
        // unsupported panel must not select an unrelated window behind it.
        var below = panel.windowNumber
        let ownWindows = Set(NSApp.windows.map(\.windowNumber))
        for _ in 0...ownWindows.count {
            let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: below)
            guard number > 0 else { return nil }
            if ownWindows.contains(number) { below = number; continue }
            guard let choice = candidates[CGWindowID(number)],
                  let frame = ScreenCaptureService.windowFrame(id: choice.id) else { return nil }
            return WindowChoice(id: choice.id, processID: choice.processID,
                                application: choice.application, title: choice.title, frame: frame)
        }
        return nil
    }

    private func updateHover() {
        let choice = candidate(at: NSEvent.mouseLocation)
        guard state.hovered != choice else { return }
        state.hovered = choice
        for view in views { view.highlight = choice?.frame }
    }

    private func select(at point: CGPoint) {
        // Resolve again at mouse-up rather than committing a stale hover target.
        guard let choice = candidate(at: point) else { return }
        let completion = onSelect
        let crop = state.crop
        cancel()
        completion?(choice, crop)
    }

    private func finishCancellation() {
        let completion = onCancel
        cancel()
        completion?()
    }

    private func finishWithList() {
        let completion = onShowList
        cancel()
        completion?()
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        panels.forEach { $0.orderOut(nil); $0.close() }
        panels.removeAll()
        views.removeAll()
        candidates.removeAll()
        onSelect = nil
        onCancel = nil
        onShowList = nil
    }
}

@MainActor @Observable
private final class WindowSelectionState {
    var hovered: WindowChoice?
    var crop = false
}

private final class WindowSelectionPanel: NSPanel {
    // Keep keyboard focus in the current app while choosing with the pointer.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct WindowSelectionToolbar: View {
    @Bindable var state: WindowSelectionState
    let cancel: () -> Void
    let showList: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("인식할 창을 클릭하세요", systemImage: "cursorarrow.click.2").font(.headline)
                Spacer()
                Button("목록에서 선택", action: showList)
                Button("취소", action: cancel)
            }
            HStack {
                Picker("인식 범위", selection: $state.crop) {
                    Text("전체 창").tag(false)
                    Text("창 내부 영역").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 230)
                Text(state.hovered?.label ?? "선택할 창에 마우스를 올리세요")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
    }
}

@MainActor
final class WindowSelectionView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    let screenFrame: CGRect
    var toolbarFrame = CGRect.zero
    var highlight: CGRect? { didSet { if highlight != oldValue { needsDisplay = true } } }
    var onClick: ((CGPoint) -> Void)?
    private var pressed = false

    init(frame: CGRect, screenFrame: CGRect) {
        self.screenFrame = screenFrame
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.18).setFill()
        bounds.fill()
        guard let highlight else { return }
        let local = highlight.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        // A zero-alpha hole is click-through at the WindowServer level, before
        // NSView can receive mouseDown/mouseUp. Keep faint coverage so hovering
        // a window never makes its selection click reach the app underneath.
        NSColor.black.withAlphaComponent(0.02).setFill()
        local.fill(using: .copy)
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(roundedRect: local.insetBy(dx: 1.5, dy: 1.5), xRadius: 8, yRadius: 8)
        outline.lineWidth = 3
        outline.stroke()
    }

    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        guard pressed, let window else { return }
        pressed = false
        onClick?(window.convertPoint(toScreen: event.locationInWindow))
    }
}

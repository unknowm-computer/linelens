import AppKit
import LineLensCore

@MainActor
final class RegionSelectionController {
    private var windows: [NSWindow] = []

    func begin(restrictingTo bounds: CGRect? = nil, completion: @escaping (CGRect, CGDirectDisplayID) -> Void) {
        cancel()
        for screen in NSScreen.screens {
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { continue }
            let screenFrame = CaptureGeometry.flipScreenRect(screen.frame, mainDisplayHeight: mainDisplayHeight)
            if let bounds, !bounds.intersects(screenFrame) { continue }
            let allowedGlobal = bounds?.intersection(screenFrame) ?? screenFrame
            let allowedLocal = allowedGlobal.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size),
                                     allowed: allowedLocal, initial: nil, editing: false)
            view.onFinish = { [weak self] local in
                let global = local.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY)
                self?.cancel()
                completion(global, id)
            }
            addWindow(on: screen, view: view)
        }
    }

    func edit(rect: CGRect, displayID: CGDirectDisplayID, completion: @escaping (CGRect, CGDirectDisplayID) -> Void) {
        cancel()
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { return }
        let screenFrame = CaptureGeometry.flipScreenRect(screen.frame, mainDisplayHeight: mainDisplayHeight)
        let bounds = CGRect(origin: .zero, size: screenFrame.size)
        let view = SelectionView(frame: bounds, allowed: bounds,
                                 initial: rect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY), editing: true)
        view.onFinish = { [weak self] local in
            self?.cancel()
            completion(local.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY), displayID)
        }
        addWindow(on: screen, view: view)
    }

    private var mainDisplayHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    private func addWindow(on screen: NSScreen, view: SelectionView) {
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = view
        window.orderFrontRegardless()
        windows.append(window)
    }

    func cancel() {
        windows.forEach { $0.orderOut(nil); $0.close() }
        windows.removeAll()
    }
}

@MainActor
private final class SelectionView: NSView {
    override var isFlipped: Bool { true }
    private let allowed: CGRect
    private let editing: Bool
    private var selection: CGRect?
    private var start: CGPoint?
    private var original: CGRect?
    private var resizing = false
    var onFinish: ((CGRect) -> Void)?

    init(frame: CGRect, allowed: CGRect, initial: CGRect?, editing: Bool) {
        self.allowed = allowed
        self.selection = initial
        self.editing = editing
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        if editing, let selection {
            addCursorRect(selection, cursor: .openHand)
            addCursorRect(CGRect(x: selection.maxX - 14, y: selection.maxY - 14, width: 28, height: 28), cursor: .crosshair)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.32).setFill()
        bounds.fill()
        if let selection {
            NSColor.clear.setFill()
            selection.fill(using: .copy)
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: selection.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            path.stroke()
            if editing {
                NSColor.controlAccentColor.setFill()
                CGRect(x: selection.maxX - 5, y: selection.maxY - 5, width: 10, height: 10).fill()
            }
            let label = "\(Int(selection.width)) × \(Int(selection.height))"
            drawLabel(label, at: CGPoint(x: selection.minX, y: min(selection.maxY + 8, bounds.maxY - 35)))
        }
        let text = editing ? "영역 안을 드래그해 이동 · 오른쪽 아래를 드래그해 크기 변경 · 놓으면 적용 · 취소는 메뉴에서"
            : "인식할 영역을 드래그하세요 · 취소는 메뉴 막대의 ‘선택 취소’"
        drawLabel(text, at: CGPoint(x: max(24, allowed.minX + 16), y: max(52, allowed.minY + 16)))
    }

    private func drawLabel(_ text: String, at point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: CGRect(x: point.x - 8, y: point.y - 5, width: size.width + 16, height: size.height + 10), xRadius: 7, yRadius: 7).fill()
        (text as NSString).draw(at: point, withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard allowed.contains(point) else { return }
        start = point
        if editing, let selection, selection.insetBy(dx: -14, dy: -14).contains(point) {
            original = selection
            resizing = abs(point.x - selection.maxX) < 18 && abs(point.y - selection.maxY) < 18
        } else {
            original = nil
            selection = CGRect(origin: point, size: .zero)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let raw = convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: min(max(raw.x, allowed.minX), allowed.maxX), y: min(max(raw.y, allowed.minY), allowed.maxY))
        if let original {
            if resizing {
                selection = CGRect(x: original.minX, y: original.minY,
                                   width: max(8, point.x - original.minX), height: max(8, point.y - original.minY)).intersection(allowed)
            } else {
                let x = min(max(original.minX + point.x - start.x, allowed.minX), allowed.maxX - original.width)
                let y = min(max(original.minY + point.y - start.y, allowed.minY), allowed.maxY - original.height)
                selection = CGRect(origin: CGPoint(x: x, y: y), size: original.size)
            }
        } else {
            selection = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                               width: abs(start.x - point.x), height: abs(start.y - point.y))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        start = nil
        guard let selection, selection.width >= 8, selection.height >= 8 else { return }
        onFinish?(selection)
    }
}

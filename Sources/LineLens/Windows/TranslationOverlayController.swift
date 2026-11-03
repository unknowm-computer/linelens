import AppKit
import LineLensCore

@MainActor
final class TranslationOverlayController {
    private(set) var window: NSWindow?
    private let content = OverlayView()
    private var liveSurface: CapturedSurface?
    private var livePreview = false

    var patchLayerCount: Int { content.patchLayerCount }
    var backgroundContents: Any? { content.background.contents }

    func updateBackground(_ surface: CapturedSurface) {
        liveSurface = surface
        guard livePreview, window?.isVisible == true else { return }
        content.setBackground(surface.surface)
    }

    func show(rect: CGRect, presentation: OverlayPresentation, livePreview: Bool, level: NSWindow.Level = .floating, topInset: CGFloat = 0) {
        ensureWindow()
        self.livePreview = livePreview && presentation.coversSource
        if window?.level != level { window?.level = level }
        let frame = CaptureGeometry.flipScreenRect(rect, mainDisplayHeight: NSScreen.screens.first?.frame.height ?? 0)
        if window?.frame != frame { window?.setFrame(frame, display: false) }
        content.install(presentation, topInset: topInset)
        if presentation.coversSource {
            if self.livePreview, let liveSurface { content.setBackground(liveSurface.surface) }
            else { content.setBackground(presentation.source) }
        } else { content.setBackground(nil) }
        if window?.isVisible != true { window?.orderFrontRegardless() }
    }

    func show(rect: CGRect, image: CGImage, level: NSWindow.Level = .floating, topInset: CGFloat = 0) {
        show(rect: rect, presentation: OverlayPresentation(source: image, patches: [], coversSource: true),
             livePreview: false, level: level, topInset: topInset)
    }

    private func ensureWindow() {
        guard window == nil else { return }
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = content
        window = panel
    }

    func hide() { window?.orderOut(nil) }

    func clear() {
        hide()
        liveSurface = nil
        livePreview = false
        content.clear()
    }
}

@MainActor
private final class OverlayView: NSView {
    let background = CALayer()
    private let clip = CALayer()
    private var patches: [UUID: CALayer] = [:]
    private var patchImages: [UUID: CGImage] = [:]
    private var patchRects: [UUID: CGRect] = [:]
    private var topInset: CGFloat = 0
    var patchLayerCount: Int { patches.count }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.mask = clip
        background.contentsGravity = .resize
        background.minificationFilter = .nearest
        background.magnificationFilter = .nearest
        layer?.addSublayer(background)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setBackground(_ contents: Any?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.contents = contents
        CATransaction.commit()
    }

    func install(_ presentation: OverlayPresentation, topInset: CGFloat) {
        self.topInset = topInset
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let ids = Set(presentation.patches.map(\.id))
        for id in Array(patches.keys) where !ids.contains(id) {
            patches.removeValue(forKey: id)?.removeFromSuperlayer()
            patchRects.removeValue(forKey: id)
            patchImages.removeValue(forKey: id)
        }
        for (index, patch) in presentation.patches.enumerated() {
            let patchLayer: CALayer
            if let existing = patches[patch.id] { patchLayer = existing }
            else {
                patchLayer = CALayer()
                patchLayer.contentsGravity = .resize
                patchLayer.minificationFilter = .nearest
                patchLayer.magnificationFilter = .nearest
                layer?.addSublayer(patchLayer)
                patches[patch.id] = patchLayer
            }
            if patchImages[patch.id] !== patch.image {
                patchLayer.contents = patch.image
                patchImages[patch.id] = patch.image
            }
            patchLayer.zPosition = CGFloat(index + 1)
            patchRects[patch.id] = patch.rect
        }
        updateFrames()
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateFrames()
        CATransaction.commit()
    }

    private func updateFrames() {
        background.frame = bounds
        clip.backgroundColor = NSColor.black.cgColor
        clip.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - topInset))
        for (id, rect) in patchRects {
            let box = CaptureGeometry.resolve(rect, in: bounds)
            patches[id]?.frame = CGRect(x: box.minX, y: bounds.height - box.maxY, width: box.width, height: box.height)
        }
    }

    func clear() {
        setBackground(nil)
        for patch in patches.values { patch.removeFromSuperlayer() }
        patches.removeAll()
        patchImages.removeAll()
        patchRects.removeAll()
    }
}

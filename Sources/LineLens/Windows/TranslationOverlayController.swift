import AppKit
import LineLensCore

@MainActor
final class TranslationOverlayController {
    private(set) var window: NSWindow?
    private let content = OverlayView()
    private var liveSurface: CapturedSurface?
    private var livePreview = false
    private var scrollSuppressed = false
    private var orderedBelowWindow: Int?
    private var fadeTask: Task<Void, Never>?
    private var fadeID = UUID()

    var patchLayerCount: Int { content.patchLayerCount }
    var backgroundContents: Any? { content.background.contents }
    var patchOpacity: Float { content.patchOpacity }

    func updateBackground(_ surface: CapturedSurface) {
        // Keep only the current capture for restoration. It must not be painted
        // while scrolling, or replaced by an older OCR snapshot on fade-in.
        liveSurface = surface
        guard !scrollSuppressed else { return }
        guard livePreview, window?.isVisible == true else { return }
        content.setBackground(surface.surface)
    }

    func show(rect: CGRect, presentation: OverlayPresentation, livePreview: Bool, level: NSWindow.Level = .floating,
              topInset: CGFloat = 0, fadeIn: Bool = false, below windowNumber: Int? = nil, excluding exclusions: [CGRect] = []) {
        guard !scrollSuppressed || fadeIn else { return }
        cancelFade()
        scrollSuppressed = false
        ensureWindow()
        let needsOrdering = window?.isVisible != true || window?.level != level || orderedBelowWindow != windowNumber
        self.livePreview = livePreview && presentation.coversSource
        // Install geometry, contents and initial opacity in a single transaction.
        // A newly attached patch must never flash at full opacity before fading.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if window?.level != level { window?.level = level }
        let frame = CaptureGeometry.flipScreenRect(rect, mainDisplayHeight: NSScreen.screens.first?.frame.height ?? 0)
        if window?.frame != frame { window?.setFrame(frame, display: false, animate: false) }
        content.layoutSubtreeIfNeeded()
        let localExclusions = exclusions.map { rectInScreen in
            CGRect(x: rectInScreen.minX - rect.minX, y: rect.maxY - rectInScreen.maxY,
                   width: rectInScreen.width, height: rectInScreen.height)
        }
        content.install(presentation, topInset: topInset, excluding: localExclusions)
        if presentation.coversSource {
            if self.livePreview, let liveSurface { content.setBackground(liveSurface.surface) }
            else { content.setBackground(presentation.source) }
        } else { content.setBackground(nil) }
        if fadeIn { content.fadePatches(from: 0, to: 1, duration: 0.1) }
        CATransaction.commit()
        if needsOrdering {
            if let windowNumber { window?.order(.below, relativeTo: windowNumber) }
            else if window?.isVisible != true { window?.orderFrontRegardless() }
            orderedBelowWindow = windowNumber
        }
    }

    func fadeOutAndDiscard(duration: TimeInterval = 0.08) {
        cancelFade()
        scrollSuppressed = true
        livePreview = false
        liveSurface = nil
        // Reveal the actual app immediately. Only translation patches fade;
        // a captured background must not remain frozen over the scrolling app.
        content.setBackground(nil)
        guard window?.isVisible == true, duration > 0 else {
            content.clear()
            return
        }
        content.fadePatches(to: 0, duration: duration)
        let token = fadeID
        fadeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self, self.fadeID == token else { return }
            // Keep the same transparent, click-through window mapped. Ordering
            // it out/in can add AppKit's own zoom/fade and expose an empty frame.
            self.content.clear()
            self.fadeTask = nil
        }
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
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = content
        window = panel
    }

    func hide() { window?.orderOut(nil) }

    func clear() {
        cancelFade()
        scrollSuppressed = false
        hide()
        liveSurface = nil
        livePreview = false
        content.clear()
    }

    private func cancelFade() {
        fadeTask?.cancel()
        fadeTask = nil
        fadeID = UUID()
    }
}

@MainActor
private final class OverlayView: NSView {
    let background = CALayer()
    private let patchRoot = CALayer()
    private let clip = CAShapeLayer()
    private var patches: [UUID: CALayer] = [:]
    private var patchImages: [UUID: CGImage] = [:]
    private var patchRects: [UUID: CGRect] = [:]
    private var topInset: CGFloat = 0
    private var exclusions: [CGRect] = []
    var patchLayerCount: Int { patches.count }
    var patchOpacity: Float { patchRoot.opacity }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clip.fillColor = NSColor.black.cgColor
        layer?.mask = clip
        background.contentsGravity = .resize
        background.minificationFilter = .nearest
        background.magnificationFilter = .nearest
        layer?.addSublayer(background)
        layer?.addSublayer(patchRoot)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setBackground(_ contents: Any?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.contents = contents
        CATransaction.commit()
    }

    func fadePatches(from explicitStart: Float? = nil, to opacity: Float, duration: TimeInterval) {
        let start = explicitStart ?? patchRoot.presentation()?.opacity ?? patchRoot.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        patchRoot.removeAnimation(forKey: "scrollOpacity")
        patchRoot.opacity = opacity
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = start
        animation.toValue = opacity
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        patchRoot.add(animation, forKey: "scrollOpacity")
        CATransaction.commit()
    }

    func install(_ presentation: OverlayPresentation, topInset: CGFloat, excluding exclusions: [CGRect]) {
        self.topInset = topInset
        let exclusionsChanged = self.exclusions != exclusions
        self.exclusions = exclusions
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
                patchRoot.addSublayer(patchLayer)
                patches[patch.id] = patchLayer
            }
            if patchImages[patch.id] !== patch.image {
                patchLayer.contents = patch.image
                patchImages[patch.id] = patch.image
            }
            patchLayer.zPosition = CGFloat(index + 1)
            patchRects[patch.id] = patch.rect
        }
        updateFrames(updateMask: exclusionsChanged)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateFrames()
        CATransaction.commit()
    }

    private func updateFrames(updateMask: Bool = false) {
        background.frame = bounds
        patchRoot.frame = bounds
        let visibleFrame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - topInset))
        if updateMask || clip.frame != visibleFrame || clip.path == nil {
            clip.frame = visibleFrame
            let visibleArea = CGPath(rect: CGRect(origin: .zero, size: visibleFrame.size), transform: nil)
            if exclusions.isEmpty {
                clip.path = visibleArea
            } else {
                let coveredArea = CGMutablePath()
                coveredArea.addRects(exclusions)
                clip.path = visibleArea.subtracting(coveredArea)
            }
        }
        for (id, rect) in patchRects {
            let box = CaptureGeometry.resolve(rect, in: bounds)
            patches[id]?.frame = CGRect(x: box.minX, y: bounds.height - box.maxY, width: box.width, height: box.height)
        }
    }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setBackground(nil)
        patchRoot.removeAllAnimations()
        patchRoot.opacity = 1
        for patch in patches.values { patch.removeFromSuperlayer() }
        patches.removeAll()
        patchImages.removeAll()
        patchRects.removeAll()
        CATransaction.commit()
    }
}

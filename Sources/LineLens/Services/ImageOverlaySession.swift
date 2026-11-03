import AppKit
import LineLensCore

struct OverlayPresentation {
    let source: CGImage
    let patches: [OverlayPatch]
    let coversSource: Bool
}

/// Keep the current screen visible until fresh OCR can provide a new layout.
/// Pending text is masked in the renderer so translation latency cannot freeze UI feedback.
@MainActor
final class ImageOverlaySession {
    private let renderer = OverlayImageRenderer()
    private let matcher = OverlayFrameMatcher()
    private var state = OverlayFrameState()
    private var source: CapturedImage?
    private var sourceBlocks: [TextBlock] = []
    private var sourceTopInset: CGFloat = 0
    private var latestFrame: CapturedFrame?
    private var lifetime = UUID()
    private var validationTask: Task<Void, Never>?
    private var task: Task<Void, Never>?
    private var requested: RenderKey?
    private(set) var presentation: OverlayPresentation?
    private var snapshot: CGImage?
    var hasPresentation: Bool { presentation != nil }
    // Used by export/tests only. Live UI presents independent layers.
    var image: CGImage? {
        if let snapshot { return snapshot }
        guard let presentation else { return nil }
        snapshot = OverlaySnapshotComposer.compose(source: presentation.source, patches: presentation.patches)
        return snapshot
    }
    var didRender: (() -> Void)?
    var didInvalidate: (() -> Void)?
    var needsRecognition: (() -> Void)?

    private struct RenderKey: Equatable {
        let revision: UUID
        let blocks: [TextBlock]
        let style: OverlayStyle
        let pointSize: CGSize
    }

    func observe(_ frame: CapturedFrame) {
        guard latestFrame?.fingerprint != frame.fingerprint else { return }
        latestFrame = frame
        validationTask?.cancel()
        guard let source else {
            state.observe(frame.fingerprint)
            return
        }
        let token = lifetime
        let revision = state.revision
        let regions = comparisonRegions(sourceBlocks, size: source.screenRect.size, topInset: sourceTopInset)
        validationTask = Task { [weak self, matcher] in
            let matches = (try? await matcher.matches(frame.image, baseline: source.image, regions: regions,
                pixels: frame.pixels, sourcePixels: source.pixels)) ?? false
            guard !Task.isCancelled, let self, self.lifetime == token, self.state.revision == revision,
                  self.latestFrame?.fingerprint == frame.fingerprint else { return }
            if !matches {
                self.state.observe(frame.fingerprint)
                self.source = nil
                self.cancelPendingRender()
                self.needsRecognition?()
            }
        }
    }

    /// Background animation during OCR is acceptable, provided the recognized text
    /// pixels still match. Scrolled/edited text and results from an old target are rejected.
    @discardableResult
    func accept(_ captured: CapturedImage, blocks: [TextBlock], topInset: CGFloat = 0) async -> Bool {
        guard let current = latestFrame else { return false }
        let token = lifetime
        let matches = (try? await matcher.matches(current.image, baseline: captured.image,
            regions: comparisonRegions(blocks, size: captured.screenRect.size, topInset: topInset),
            pixels: current.pixels, sourcePixels: captured.pixels)) ?? false
        guard !Task.isCancelled, lifetime == token,
              latestFrame?.fingerprint == current.fingerprint, matches else { return false }
        validationTask?.cancel()
        validationTask = nil
        state.observe(captured.fingerprint)
        state.acceptRecognition(captured.fingerprint)
        source = captured
        sourceBlocks = blocks
        sourceTopInset = topInset
        return true
    }

    func prepare(blocks: [TextBlock], settings: AppSettings) {
        guard settings.translationEnabled else {
            invalidateImage()
            return
        }
        guard state.canPresent, let source else { return }
        sourceBlocks = blocks
        let key = RenderKey(revision: state.revision, blocks: blocks, style: settings.overlayStyle, pointSize: source.screenRect.size)
        guard requested != key else { return }
        // Publish fresh layout atomically, then replace its pending labels as translations arrive.
        task?.cancel()
        requested = key
        task = Task { [weak self, renderer] in
            let result = try? await renderer.renderPatches(image: source.image, pointSize: key.pointSize, blocks: blocks, style: key.style)
            guard !Task.isCancelled, let self, self.requested == key, self.state.revision == key.revision,
                  self.state.canPresent else { return }
            if let result {
                self.presentation = OverlayPresentation(source: source.image, patches: result, coversSource: key.style == .cover)
                self.snapshot = nil
            }
            self.task = nil
            self.didRender?()
        }
    }

    func suspend() {
        lifetime = UUID()
        state = OverlayFrameState()
        source = nil
        sourceBlocks = []
        sourceTopInset = 0
        latestFrame = nil
        validationTask?.cancel()
        validationTask = nil
        cancelPendingRender()
    }

    func reset() {
        suspend()
        invalidateImage()
    }

    private func comparisonRegions(_ blocks: [TextBlock], size: CGSize, topInset: CGFloat) -> [CGRect] {
        let content = CGRect(x: 0, y: topInset / max(size.height, 1), width: 1,
                             height: max(0, 1 - topInset / max(size.height, 1)))
        let regions = blocks.compactMap { block -> CGRect? in
            let rect = block.rect.insetBy(dx: -1 / max(size.width, 1), dy: -1 / max(size.height, 1)).intersection(content)
            return rect.isNull || rect.isEmpty ? nil : rect
        }
        return regions.isEmpty ? [content] : regions
    }

    private func cancelPendingRender() {
        task?.cancel()
        task = nil
        requested = nil
    }

    private func invalidateImage() {
        cancelPendingRender()
        if presentation != nil {
            presentation = nil
            snapshot = nil
            didInvalidate?()
        }
    }
}

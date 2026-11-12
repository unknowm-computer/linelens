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
    private var renderer = OverlayImageRenderer()
    private var matcher: OverlayFrameMatcher
    private(set) var stabilizer: OCRFrameStabilizer
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
    var canRender: Bool { state.canPresent && source != nil }
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

    init(stabilizer: OCRFrameStabilizer = OCRFrameStabilizer()) {
        self.stabilizer = stabilizer
        matcher = OverlayFrameMatcher(stabilizer: stabilizer)
    }

    private struct RenderKey: Equatable {
        let revision: UUID
        let blocks: [TextBlock]
        let style: OverlayStyle
        let pointSize: CGSize
    }

    func observe(_ frame: CapturedFrame) {
        if let latestFrame, frame.sequence > 0, latestFrame.sequence > frame.sequence { return }
        guard latestFrame?.fingerprint != frame.fingerprint else {
            latestFrame = frame
            return
        }
        latestFrame = frame
        validationTask?.cancel()
        let source = canRender ? source : nil
        if source == nil { state.observe(frame.fingerprint) }
        let token = lifetime
        let revision = state.revision
        let regions = source.map { comparisonRegions(sourceBlocks, size: $0.screenRect.size, topInset: sourceTopInset) } ?? []
        let hasText = !sourceBlocks.isEmpty
        validationTask = Task { [weak self, matcher, stabilizer] in
            await stabilizer.observe(frame)
            guard !Task.isCancelled, let source else { return }
            let matches = (try? await matcher.matches(frame.image, baseline: source.image, regions: regions,
                pixels: frame.pixels, sourcePixels: source.pixels, allowColorChanges: hasText)) ?? false
            guard !Task.isCancelled, let self, self.lifetime == token, self.state.revision == revision,
                  self.latestFrame?.fingerprint == frame.fingerprint else { return }
            if !matches {
                self.state.observe(frame.fingerprint)
                // Keep the last accepted capture for checking missing paragraphs.
                self.cancelPendingRender()
                self.needsRecognition?()
            }
        }
    }

    /// Recover text that is still visible, then verify the resulting layout against the latest frame.
    func accept(_ captured: CapturedImage, blocks incoming: [TextBlock], topInset: CGFloat = 0) async -> [TextBlock]? {
        let token = lifetime
        let previous = source
        let previousBlocks = previous?.screenRect.size == captured.screenRect.size ? sourceBlocks : []
        let pixelSize = CGSize(width: captured.image.width, height: captured.image.height)
        for _ in 0..<3 {
            guard !Task.isCancelled, lifetime == token, let current = latestFrame else { return nil }
            let blocks: [TextBlock]
            if let previous, !previousBlocks.isEmpty {
                blocks = await matcher.retainingVisibleText(incoming, previous: previousBlocks, before: previous, after: current)
            } else {
                blocks = incoming
            }
            // On a deletion, check where the old text was. Motion outside those
            // boxes must not prevent an otherwise current empty result.
            let matches = (try? await matcher.matches(current.image, baseline: captured.image,
                regions: comparisonRegions(blocks.isEmpty ? previousBlocks : blocks, size: captured.screenRect.size, topInset: topInset),
                pixels: current.pixels, sourcePixels: captured.pixels, allowColorChanges: !blocks.isEmpty)) ?? false
            guard !Task.isCancelled, lifetime == token else { return nil }
            if !matches {
                if latestFrame?.fingerprint != current.fingerprint { continue }
                return nil
            }
            await stabilizer.track(blocks, pixelSize: pixelSize)
            guard !Task.isCancelled, lifetime == token, let newest = latestFrame else { return nil }
            if newest.fingerprint != current.fingerprint {
                // Another frame can arrive while validation is suspended. Check
                // both accepted and omitted text boxes before using its pixels.
                let textRegions = comparisonRegions(blocks + previousBlocks, size: captured.screenRect.size, topInset: topInset)
                guard let checked = current.pixels, let latest = newest.pixels,
                      checked.hasSamePixels(as: latest, in: textRegions) else { continue }
            }

            validationTask?.cancel()
            validationTask = nil
            state.observe(newest.fingerprint)
            state.acceptRecognition(newest.fingerprint)
            // Use the newest verified pixels for the translated patches.
            source = CapturedImage(image: newest.image, screenRect: captured.screenRect,
                fingerprint: newest.fingerprint, pixels: newest.pixels, sequence: newest.sequence)
            sourceBlocks = blocks
            sourceTopInset = topInset
            return blocks
        }
        return nil
    }

    func prepare(blocks: [TextBlock], settings: AppSettings) {
        guard settings.translationEnabled else {
            invalidateImage()
            return
        }
        guard state.canPresent, let source else { return }
        let key = RenderKey(revision: state.revision, blocks: blocks, style: settings.overlayStyle, pointSize: source.screenRect.size)
        guard requested != key else { return }
        // Publish fresh layout atomically, then replace its pending labels as translations arrive.
        task?.cancel()
        requested = key
        task = Task { [weak self, renderer] in
            let result = try? await renderer.renderPatches(image: source.image, pointSize: key.pointSize, blocks: blocks, style: key.style, pixels: source.pixels)
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
        latestFrame = nil
        validationTask?.cancel()
        validationTask = nil
        cancelPendingRender()
    }

    func reset() {
        suspend()
        source = nil
        sourceBlocks = []
        sourceTopInset = 0
        invalidateImage()
        // A new screen must not reuse images or comparison pixels belonging to
        // a pre-scroll layout. TranslationEngine's text-only cache is separate.
        renderer = OverlayImageRenderer()
        stabilizer = OCRFrameStabilizer()
        matcher = OverlayFrameMatcher(stabilizer: stabilizer)
    }

    private func comparisonRegions(_ blocks: [TextBlock], size: CGSize, topInset: CGFloat) -> [CGRect] {
        let content = CGRect(x: 0, y: topInset / max(size.height, 1), width: 1,
                             height: max(0, 1 - topInset / max(size.height, 1)))
        let lines = blocks.flatMap { $0.lines.isEmpty ? [$0.rect] : $0.lines.map(\.rect) }
        let regions = lines.compactMap { line -> CGRect? in
            let rect = line.insetBy(dx: -1 / max(size.width, 1), dy: -1 / max(size.height, 1)).intersection(content)
            return rect.isNull || rect.isEmpty ? nil : rect
        }
        return regions.isEmpty ? [content] : regions
    }

    private func cancelPendingRender() {
        task?.cancel()
        task = nil
        requested = nil
    }

    func invalidateImage() {
        cancelPendingRender()
        if presentation != nil {
            presentation = nil
            snapshot = nil
            didInvalidate?()
        }
    }
}

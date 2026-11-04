import CoreGraphics
import Foundation
import LineLensCore
import Vision

actor OCRService {
    typealias LineRecognizer = @Sendable (CGImage, String, OCRMode) throws -> [TextLine]
    struct Result: Sendable {
        let fingerprint: UInt64
        let blocks: [TextBlock]?
        let processedRegions: [CGRect]
        let effectiveMode: OCRMode
    }

    private var previousPixels: ImagePixels?
    private var previousBlocks: [TextBlock] = []
    private var previousLanguage: String?
    private var previousMode: OCRMode?
    private var cachedFingerprint: UInt64?
    private var lastEffectiveMode: OCRMode = .accurate
    private let stabilizer: OCRFrameStabilizer
    private let recognizer: LineRecognizer?

    init(stabilizer: OCRFrameStabilizer = OCRFrameStabilizer(), recognizer: LineRecognizer? = nil) {
        self.stabilizer = stabilizer
        self.recognizer = recognizer
    }

    func supportedLanguages() throws -> [String] {
        try VNRecognizeTextRequest().supportedRecognitionLanguages().sorted()
    }

    func recognize(_ image: CGImage, language: String, previousFingerprint: UInt64?, fingerprint knownFingerprint: UInt64? = nil,
                   mode: OCRMode = .accurate, pixels knownPixels: ImagePixels? = nil, sequence: UInt64 = 0) async throws -> Result {
        try Task.checkCancellation()
        let rawPixels = knownPixels ?? ImagePixels(image)
        let rawFingerprint = knownFingerprint ?? rawPixels?.fingerprint ?? ImageFingerprint.make(image)
        await stabilizer.observe(CapturedFrame(image: image, fingerprint: rawFingerprint, pixels: rawPixels, sequence: sequence))
        let normalized = await stabilizer.normalized(image, pixels: rawPixels)
        try Task.checkCancellation()
        let fingerprint = normalized.image === image ? rawFingerprint : normalized.pixels?.fingerprint ?? ImageFingerprint.make(normalized.image)
        let image = normalized.image
        let pixels = normalized.pixels
        let configurationMatches = previousLanguage == language && previousMode == mode
        if fingerprint == previousFingerprint && fingerprint == cachedFingerprint && configurationMatches {
            return Result(fingerprint: fingerprint, blocks: nil, processedRegions: [], effectiveMode: lastEffectiveMode)
        }
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        var regions = [full]
        if previousFingerprint != nil, configurationMatches, let pixels, let previousPixels {
            regions = DirtyRegionPlanner.regions(changes: pixels.changedTiles(from: previousPixels), previous: previousBlocks,
                pixelSize: CGSize(width: image.width, height: image.height))
        }
        let regionMode = effectiveMode(mode, language: language)
        var usedMode = regionMode
        var replacement: [TextBlock] = []
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        for region in regions {
            try Task.checkCancellation()
            let pixelRect = CaptureGeometry.resolve(region, in: imageBounds).integral.intersection(imageBounds)
            guard let crop = image.cropping(to: pixelRect) else { continue }
            let normalized = CGRect(x: pixelRect.minX / imageBounds.width, y: pixelRect.minY / imageBounds.height,
                                    width: pixelRect.width / imageBounds.width, height: pixelRect.height / imageBounds.height)
            var lines = try recognizeLines(crop, language: language, mode: regionMode)
            // Fast Vision supports fewer scripts. Auto language can return no text
            // or weak Latin guesses for other scripts; retry those regions accurately.
            // Fast Vision commonly reports 0.5 even for clean English text;
            // an accurate-mode threshold would silently make every request slow.
            if regionMode == .fast {
                let needsFallback = lines.isEmpty ? try containsText(crop)
                    : lines.map(\.confidence).reduce(0, +) / Float(lines.count) < 0.3
                if needsFallback {
                    lines = try recognizeLines(crop, language: language, mode: .accurate)
                    usedMode = .accurate
                }
            }
            let mapped = lines.map { line in
                TextLine(text: line.text, rect: CGRect(x: normalized.minX + line.rect.minX * normalized.width,
                    y: normalized.minY + line.rect.minY * normalized.height,
                    width: line.rect.width * normalized.width, height: line.rect.height * normalized.height), confidence: line.confidence)
            }
            replacement += TextLayout.paragraphs(from: mapped)
        }
        let kept = previousBlocks.filter { block in !regions.contains(where: { $0.intersects(block.rect) }) }
        var blocks = (kept + replacement).sorted { $0.rect.minY == $1.rect.minY ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY }
        if configurationMatches, let before = previousPixels, let pixels {
            blocks = OCRTextStability.retainingVisibleText(blocks, previous: previousBlocks, before: before, after: pixels, regions: regions)
        }
        try Task.checkCancellation()
        await stabilizer.track(blocks, pixelSize: CGSize(width: image.width, height: image.height))
        try Task.checkCancellation()
        previousPixels = pixels
        previousBlocks = blocks
        previousLanguage = language
        previousMode = mode
        cachedFingerprint = fingerprint
        lastEffectiveMode = usedMode
        return Result(fingerprint: fingerprint, blocks: blocks, processedRegions: regions, effectiveMode: usedMode)
    }

    private func effectiveMode(_ requested: OCRMode, language: String) -> OCRMode {
        guard requested == .fast, language != "auto" else { return requested }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        return (try? request.supportedRecognitionLanguages().contains(language)) == true ? .fast : .accurate
    }

    private func containsText(_ image: CGImage) throws -> Bool {
        let request = VNDetectTextRectanglesRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        try Task.checkCancellation()
        return !(request.results ?? []).isEmpty
    }

    private func recognizeLines(_ image: CGImage, language: String, mode: OCRMode) throws -> [TextLine] {
        if let recognizer { return try recognizer(image, language, mode) }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = mode == .fast ? .fast : .accurate
        request.usesLanguageCorrection = mode == .accurate
        if language == "auto" { request.automaticallyDetectsLanguage = true }
        else {
            guard try request.supportedRecognitionLanguages().contains(language) else { throw LineLensError.unsupportedOCR }
            request.recognitionLanguages = [language]
        }
        try VNImageRequestHandler(cgImage: image).perform([request])
        try Task.checkCancellation()
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return TextLine(text: text.string, rect: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height), confidence: text.confidence)
        }
    }
}

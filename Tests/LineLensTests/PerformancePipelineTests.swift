import AppKit
import CoreVideo
import XCTest
import LineLensCore
@preconcurrency import Translation
@testable import LineLens

final class PerformancePipelineTests: XCTestCase {
    func testNewDefaultsAndMigrationPreserveExistingPreferences() throws {
        let defaults = AppSettings()
        XCTAssertEqual(defaults.ocrMode, .fast)
        XCTAssertEqual(defaults.translationQuality, .speed)
        XCTAssertEqual(defaults.recognitionSource, .automatic)
        XCTAssertTrue(defaults.livePreview)
        let old = Data(#"{"ocrLanguage":"ja-JP","targetLanguage":"en","refreshInterval":5,"presentation":"both","captureShortcut":null}"#.utf8)
        let migrated = try JSONDecoder().decode(AppSettings.self, from: old)
        XCTAssertEqual(migrated.ocrLanguage, "ja-JP")
        XCTAssertEqual(migrated.targetLanguage, "en")
        XCTAssertEqual(migrated.refreshInterval, 5)
        XCTAssertEqual(migrated.presentation, .both)
        XCTAssertFalse(migrated.excludeBrowserLinkStatus)
        XCTAssertFalse(migrated.alwaysShowResults)
        XCTAssertNil(migrated.captureShortcut)
        XCTAssertEqual(migrated.ocrMode, .fast)
        XCTAssertEqual(migrated.translationQuality, .speed)
        var customized = migrated
        customized.ocrMode = .accurate
        customized.translationQuality = .quality
        customized.recognitionSource = .ocr
        customized.livePreview = false
        customized.excludeBrowserLinkStatus = true
        customized.alwaysShowResults = true
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(customized)), customized)
        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(customized)) as? [String: Any])
        legacyObject.removeValue(forKey: "captureShortcut")
        let omittedNil = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: legacyObject))
        XCTAssertNil(omittedNil.captureShortcut, "Legacy encoders omitted intentionally removed shortcuts")
    }

    func testAlwaysShowResultsAlsoOpensThePanelInOverlayMode() {
        var settings = AppSettings()
        for presentation in ResultPresentation.allCases {
            settings.presentation = presentation
            settings.alwaysShowResults = false
            XCTAssertEqual(settings.showsResultsOnSelection, presentation != .overlay)
            settings.alwaysShowResults = true
            XCTAssertTrue(settings.showsResultsOnSelection)
        }
    }

    func testUnknownNewPreferencesFallBackIndependently() throws {
        let data = Data(#"{"ocrMode":"future","translationQuality":"future","recognitionSource":"future","targetLanguage":"ja"}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(settings.ocrMode, .fast)
        XCTAssertEqual(settings.translationQuality, .speed)
        XCTAssertEqual(settings.recognitionSource, .automatic)
        XCTAssertEqual(settings.targetLanguage, "ja")
        XCTAssertEqual(settings.captureShortcut, .capture)
    }

    @MainActor
    private func fixture(number: Int? = 123) throws -> CGImage {
        let image = NSImage(size: CGSize(width: 900, height: 540), flipped: true) { bounds in
            NSColor.white.setFill(); bounds.fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black]
            if let number { ("Page \(number)" as NSString).draw(at: CGPoint(x: 40, y: 45), withAttributes: attributes) }
            ("Keep this label" as NSString).draw(at: CGPoint(x: 540, y: 420), withAttributes: attributes)
            return true
        }
        return try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    @MainActor
    func testDeltaOCRRecognizesOnlyEditedRegionAndRemovesErasedText() async throws {
        let service = OCRService()
        let initial = try await service.recognize(fixture(), language: "en-US", previousFingerprint: nil)
        let initialBlocks = try XCTUnwrap(initial.blocks)
        let stable = try XCTUnwrap(initialBlocks.first { $0.source.contains("Keep") })
        let next = try await service.recognize(fixture(number: 124), language: "en-US", previousFingerprint: initial.fingerprint)
        XCTAssertFalse(next.processedRegions.isEmpty)
        XCTAssertLessThan(next.processedRegions.reduce(0) { $0 + $1.width * $1.height }, 0.45)
        XCTAssertTrue(next.blocks?.contains { $0.source.contains("124") } == true)
        XCTAssertEqual(next.blocks?.first { $0.source.contains("Keep") }, stable)
        let erased = try await service.recognize(fixture(number: nil), language: "en-US", previousFingerprint: next.fingerprint)
        XCTAssertEqual(erased.blocks?.map(\.source), [stable.source])
        let forced = try await service.recognize(fixture(number: nil), language: "en-US", previousFingerprint: nil)
        XCTAssertEqual(forced.processedRegions, [CGRect(x: 0, y: 0, width: 1, height: 1)])
    }

    @MainActor
    func testFastOCRAndUnsupportedLanguageFallback() async throws {
        let service = OCRService()
        let fast = try await service.recognize(fixture(), language: "en-US", previousFingerprint: nil, mode: .fast)
        XCTAssertEqual(fast.effectiveMode, .fast)
        XCTAssertTrue(fast.blocks?.contains { $0.source.contains("Page") } == true)
        let blankEdit = try await service.recognize(fixture(number: nil), language: "en-US", previousFingerprint: fast.fingerprint, mode: .fast)
        XCTAssertEqual(blankEdit.effectiveMode, .fast, "An erased label must not send blank pixels to accurate OCR")
        XCTAssertEqual(blankEdit.blocks?.count, 1)
        let accurate = try await service.recognize(fixture(), language: "en-US", previousFingerprint: fast.fingerprint, mode: .accurate)
        XCTAssertNotNil(accurate.blocks, "Changing OCR mode must re-recognize an identical frame")
        let fallback = try await service.recognize(fixture(), language: "ko-KR", previousFingerprint: nil, mode: .fast)
        XCTAssertEqual(fallback.effectiveMode, .accurate)
        XCTAssertNotNil(fallback.blocks)
    }

    @MainActor
    func testUncachedServiceDoesNotTrustAnExternalUnchangedFingerprint() async throws {
        let image = try fixture()
        let result = try await OCRService().recognize(image, language: "en-US", previousFingerprint: ImageFingerprint.make(image))
        XCTAssertNotNil(result.blocks)
    }

    @MainActor
    func testPatchesReuseUnchangedLabelsAndOnlyRebuildChangedTranslation() async throws {
        let source = try fixture()
        var first = TextBlock(source: "Page 123", rect: CGRect(x: 0.04, y: 0.08, width: 0.25, height: 0.09), confidence: 1)
        first.translation = "123페이지"
        var second = TextBlock(source: "Keep this label", rect: CGRect(x: 0.59, y: 0.77, width: 0.35, height: 0.09), confidence: 1)
        second.translation = "이 문구 유지"
        let renderer = OverlayImageRenderer()
        let initial = try await renderer.renderPatches(image: source, pointSize: CGSize(width: 900, height: 540), blocks: [first, second], style: .cover)
        XCTAssertEqual(initial.count, 2)
        XCTAssertTrue(initial.allSatisfy { $0.image.width < source.width && $0.image.height < source.height })
        first.translation = "새 번역"
        let updated = try await renderer.renderPatches(image: source, pointSize: CGSize(width: 900, height: 540), blocks: [first, second], style: .cover)
        XCTAssertFalse(initial[0].image === updated[0].image)
        XCTAssertTrue(initial[1].image === updated[1].image)
        let renderedCount = await renderer.renderedPatchCount
        let cacheHits = await renderer.cacheHitCount
        XCTAssertEqual(renderedCount, 3)
        XCTAssertEqual(cacheHits, 1)
        let composed = try XCTUnwrap(OverlaySnapshotComposer.compose(source: source, patches: updated))
        let before = try XCTUnwrap(ImagePixels(source)), after = try XCTUnwrap(ImagePixels(composed))
        let center = (270 * before.width + 450) * 4
        XCTAssertEqual(Array(before.bytes[center..<center + 4]), Array(after.bytes[center..<center + 4]))
        let recognized = try await OCRService().recognize(composed, language: "en-US", previousFingerprint: nil)
        XCTAssertFalse((recognized.blocks ?? []).contains { $0.source.contains("Page") || $0.source.contains("Keep") })
    }

    @MainActor
    func testLiveSurfaceUpdatesIndependentlyAndSnapshotModeKeepsCapturedBackground() throws {
        let source = try fixture()
        let patch = OverlayPatch(id: UUID(), rect: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.1), image: source)
        let presentation = OverlayPresentation(source: source, patches: [patch], coversSource: true)
        let controller = TranslationOverlayController()
        defer { controller.clear() }
        let rect = CGRect(x: 40, y: 60, width: 900, height: 540)
        controller.show(rect: rect, presentation: presentation, livePreview: true)
        let window = try XCTUnwrap(controller.window)
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 900, 540, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer), kCVReturnSuccess)
        let surface = try XCTUnwrap(CapturedSurface(buffer: XCTUnwrap(buffer)))
        controller.updateBackground(surface)
        XCTAssertTrue((controller.backgroundContents as AnyObject?) === surface.surface)
        XCTAssertEqual(controller.patchLayerCount, 1)
        XCTAssertTrue(window.ignoresMouseEvents)
        controller.show(rect: rect, presentation: presentation, livePreview: false)
        controller.updateBackground(surface)
        XCTAssertTrue((controller.backgroundContents as AnyObject?) === source)
        controller.show(rect: rect, presentation: OverlayPresentation(source: source, patches: [], coversSource: true), livePreview: false)
        XCTAssertEqual(controller.patchLayerCount, 0)
        XCTAssertTrue(controller.window === window)
    }

    @MainActor
    func testNativePatchLayerUsesTheSameCoordinatesAsSnapshotComposition() throws {
        let source = try fixture()
        let black = NSImage(size: CGSize(width: 20, height: 20), flipped: false) { bounds in
            NSColor.black.setFill(); bounds.fill(); return true
        }
        let image = try XCTUnwrap(black.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let patch = OverlayPatch(id: UUID(), rect: CGRect(x: 0.4, y: 0.2, width: 0.1, height: 0.1), image: image)
        let controller = TranslationOverlayController()
        defer { controller.clear() }
        controller.show(rect: CGRect(x: 40, y: 60, width: 900, height: 540),
            presentation: OverlayPresentation(source: source, patches: [patch], coversSource: true), livePreview: false)
        let view = try XCTUnwrap(controller.window?.contentView)
        view.layoutSubtreeIfNeeded()
        let context = try XCTUnwrap(CGContext(data: nil, width: source.width, height: source.height, bitsPerComponent: 8, bytesPerRow: source.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        let sx = CGFloat(source.width) / 900, sy = CGFloat(source.height) / 540
        context.scaleBy(x: sx, y: sy)
        try XCTUnwrap(view.layer).render(in: context)
        let actual = try XCTUnwrap(ImagePixels(XCTUnwrap(context.makeImage())))
        let expected = try XCTUnwrap(ImagePixels(XCTUnwrap(OverlaySnapshotComposer.compose(source: source, patches: [patch]))))
        for (x, y) in [(400, 125), (400, 400), (450, 270)] {
            let offset = (Int(CGFloat(y) * sy) * source.width + Int(CGFloat(x) * sx)) * 4
            XCTAssertEqual(Array(actual.bytes[offset..<offset + 4]), Array(expected.bytes[offset..<offset + 4]), "Layer position at \(x),\(y)")
        }
    }

    func testAccessibleTextCropsDeduplicatesAndRejectsSecureOrEmptyElements() {
        let rect = CGRect(x: 100, y: 100, width: 400, height: 300)
        let candidates = [
            AccessibleTextCandidate(text: " Open ", rect: CGRect(x: 120, y: 120, width: 100, height: 30), isControl: true),
            AccessibleTextCandidate(text: "Open", rect: CGRect(x: 125, y: 125, width: 80, height: 20), isControl: false),
            AccessibleTextCandidate(text: "Partial", rect: CGRect(x: 80, y: 200, width: 100, height: 25), isControl: false),
            AccessibleTextCandidate(text: "password", rect: CGRect(x: 150, y: 250, width: 100, height: 20), isControl: true, isSecure: true),
            AccessibleTextCandidate(text: "", rect: rect, isControl: false),
            AccessibleTextCandidate(text: "tiny", rect: CGRect(x: 130, y: 150, width: 3, height: 3), isControl: true),
            AccessibleTextCandidate(text: "outside", rect: CGRect(x: 700, y: 700, width: 100, height: 20), isControl: false),
        ]
        let blocks = AccessibilityTextExtractor.blocks(from: candidates, captureRect: rect)
        XCTAssertEqual(blocks.map(\.source), ["Open", "Partial"])
        XCTAssertEqual(blocks[0].rect.minX, 25.0 / 400, accuracy: 0.0001)
        XCTAssertEqual(blocks[1].rect.minX, 0)
        XCTAssertEqual(blocks[1].rect.width, 80.0 / 400, accuracy: 0.0001)
        XCTAssertNotNil(blocks[0].fontSizeHint)
    }

    @MainActor
    func testQualityChangesStrategyWithoutReusingOldConfiguration() throws {
        guard #available(macOS 26.4, *) else { throw XCTSkip("Strategy selection requires macOS 26.4") }
        let engine = TranslationEngine()
        let block = TextBlock(source: "Open application settings", rect: .zero, confidence: 1)
        var settings = AppSettings()
        engine.submit(blocks: [block], settings: settings) { _ in }
        XCTAssertEqual(engine.configuration?.preferredStrategy, .lowLatency)
        settings.translationQuality = .quality
        engine.submit(blocks: [block], settings: settings) { _ in }
        XCTAssertEqual(engine.configuration?.preferredStrategy, .highFidelity)
        engine.cancel()
    }
}

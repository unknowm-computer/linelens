import Foundation
import XCTest
import LineLensCore
@testable import LineLens

@MainActor
final class OCRStabilityTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 0
        func read() -> TimeInterval { lock.withLock { value } }
        func set(_ time: TimeInterval) { lock.withLock { value = time } }
    }

    private func block(_ text: String = "Page 123") -> TextBlock {
        let line = TextLine(text: text, rect: CGRect(x: 20.0 / 320, y: 30.0 / 100, width: 200.0 / 320, height: 28.0 / 100), confidence: 1)
        var block = TextBlock(source: text, rect: line.rect, confidence: 1, lines: [line])
        block.translation = "기존 번역"
        return block
    }

    private func frame(caret: Int? = nil, edit: Bool = false, addition: Bool = false, erased: Bool = false, sequence: UInt64 = 0) throws -> CapturedFrame {
        var bytes = [UInt8](repeating: 255, count: 320 * 100 * 4)
        func fill(_ rect: CGRect, color: [UInt8] = [0, 0, 0]) {
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    let offset = (y * 320 + x) * 4
                    for channel in 0..<3 { bytes[offset + channel] = color[channel] }
                }
            }
        }
        if !erased {
            for x in stride(from: 22, to: 180, by: 20) { fill(CGRect(x: x, y: 33, width: 8, height: 20)) }
            if edit { fill(CGRect(x: 162, y: 33, width: 3, height: 8), color: [255, 255, 255]) }
            if addition { fill(CGRect(x: 112, y: 36, width: 4, height: 4)) }
        }
        if let caret {
            let rects = [CGRect(x: 198, y: 28, width: 3, height: 30),
                         CGRect(x: 194, y: 54, width: 23, height: 3),
                         CGRect(x: 194, y: 30, width: 20, height: 28)]
            fill(rects[caret], color: [240, 0, 0])
        }
        let pixels = ImagePixels(width: 320, height: 100, bytes: bytes)
        return CapturedFrame(image: try XCTUnwrap(pixels.makeImage()), fingerprint: pixels.fingerprint, pixels: pixels, sequence: sequence)
    }

    private func learn(_ stabilizer: OCRFrameStabilizer, clock: Clock, caret: Int) async throws {
        await stabilizer.track([block()], pixelSize: CGSize(width: 320, height: 100))
        clock.set(0); await stabilizer.observe(try frame(sequence: 1))
        clock.set(0.2); await stabilizer.observe(try frame(caret: caret, sequence: 2))
        clock.set(0.7); await stabilizer.observe(try frame(sequence: 3))
        clock.set(1.2); await stabilizer.observe(try frame(caret: caret, sequence: 4))
    }

    func testRepeatedPixelCyclesAreNormalizedForDifferentCaretShapes() async throws {
        for caret in 0...2 {
            let clock = Clock()
            let stabilizer = OCRFrameStabilizer(now: { clock.read() })
            try await learn(stabilizer, clock: clock, caret: caret)
            let on = try frame(caret: caret, sequence: 4)
            let off = try frame()
            let stable = await stabilizer.normalized(on.image, pixels: on.pixels)
            XCTAssertEqual(stable.pixels?.bytes, off.pixels?.bytes)
            XCTAssertEqual(ImagePixels(stable.image)?.bytes, stable.pixels?.bytes, "Normalized images must preserve pixel orientation")
            let matcher = OverlayFrameMatcher(stabilizer: stabilizer)
            let matches = try await matcher.matches(on.image, baseline: off.image, regions: [block().rect], pixels: on.pixels, sourcePixels: off.pixels)
            XCTAssertTrue(matches)
        }
    }

    func testActualDigitEditAndDeletionInvalidateLearnedCyclesImmediately() async throws {
        for erased in [false, true] {
            let clock = Clock()
            let stabilizer = OCRFrameStabilizer(now: { clock.read() })
            try await learn(stabilizer, clock: clock, caret: 0)
            clock.set(1.4)
            let edited = try frame(caret: 0, edit: !erased, erased: erased, sequence: 5)
            await stabilizer.observe(edited)
            let stable = await stabilizer.normalized(edited.image, pixels: edited.pixels)
            XCTAssertEqual(stable.pixels?.bytes, edited.pixels?.bytes, "Edits must not wait for another frame or OCR pass")
            let matcher = OverlayFrameMatcher(stabilizer: stabilizer)
            let off = try frame()
            let matches = try await matcher.matches(edited.image, baseline: off.image, regions: [block().rect])
            XCTAssertFalse(matches)
        }
    }

    func testIdenticalSamplesDoNotInventABlinkAndStoppedCyclesExpire() async throws {
        let clock = Clock()
        let stabilizer = OCRFrameStabilizer(now: { clock.read() })
        await stabilizer.track([block()], pixelSize: CGSize(width: 320, height: 100))
        await stabilizer.observe(try frame(sequence: 1))
        for index in 2...8 {
            clock.set(Double(index) * 0.1)
            await stabilizer.observe(try frame(caret: 0, sequence: UInt64(index)))
        }
        let on = try frame(caret: 0)
        let unchanged = await stabilizer.normalized(on.image, pixels: on.pixels)
        XCTAssertEqual(unchanged.pixels?.bytes, on.pixels?.bytes)
        let learned = OCRFrameStabilizer(now: { clock.read() })
        try await learn(learned, clock: clock, caret: 0)
        clock.set(3)
        let expired = await learned.normalized(on.image, pixels: on.pixels)
        XCTAssertEqual(expired.pixels?.bytes, on.pixels?.bytes)
    }

    func testConfirmedTextChangeDiscardsCycleAndResizeCannotReuseOldPixelBounds() async throws {
        let clock = Clock()
        let stabilizer = OCRFrameStabilizer(now: { clock.read() })
        try await learn(stabilizer, clock: clock, caret: 2)
        await stabilizer.track([block("Page 124")], pixelSize: CGSize(width: 320, height: 100))
        let on = try frame(caret: 2)
        let changed = await stabilizer.normalized(on.image, pixels: on.pixels)
        XCTAssertEqual(changed.pixels?.bytes, on.pixels?.bytes)
        let small = ImagePixels(width: 40, height: 20, bytes: [UInt8](repeating: 255, count: 40 * 20 * 4))
        let image = try XCTUnwrap(small.makeImage())
        await stabilizer.observe(CapturedFrame(image: image, fingerprint: small.fingerprint, pixels: small, sequence: 5))
        let other = ImagePixels(width: 40, height: 20, bytes: [UInt8](repeating: 0, count: 40 * 20 * 4))
        await stabilizer.observe(CapturedFrame(image: try XCTUnwrap(other.makeImage()), fingerprint: other.fingerprint, pixels: other, sequence: 6))
        let resized = await stabilizer.normalized(image, pixels: small)
        XCTAssertEqual(resized.pixels?.bytes, small.bytes)
    }

    func testMissingOrMisreadOCRKeepsVisibleGlyphsButNotEditedOrDeletedText() throws {
        let before = try XCTUnwrap(frame().pixels)
        let cursor = try XCTUnwrap(frame(caret: 2).pixels)
        let regions = [CGRect(x: 0, y: 0, width: 1, height: 1)]
        let old = block()
        let missing = OCRTextStability.retainingVisibleText([], previous: [old], before: before, after: cursor, regions: regions)
        XCTAssertEqual(missing, [old])
        let misread = OCRTextStability.retainingVisibleText([block("Page")], previous: [old], before: before, after: cursor, regions: regions)
        XCTAssertEqual(misread, [old])
        let edited = OCRTextStability.retainingVisibleText([block("Page 124")], previous: [old], before: before,
            after: try XCTUnwrap(frame(edit: true).pixels), regions: regions)
        XCTAssertEqual(edited.map(\.source), ["Page 124"])
        let addedStroke = OCRTextStability.retainingVisibleText([block("Page 128")], previous: [old], before: before,
            after: try XCTUnwrap(frame(addition: true).pixels), regions: regions)
        XCTAssertEqual(addedStroke.map(\.source), ["Page 128"], "Added glyph strokes must not be mistaken for a caret")
        let erased = OCRTextStability.retainingVisibleText([], previous: [old], before: before,
            after: try XCTUnwrap(frame(erased: true).pixels), regions: regions)
        XCTAssertTrue(erased.isEmpty)
        let appended = OCRTextStability.retainingVisibleText([block("Page 1234")], previous: [old], before: before, after: cursor, regions: regions)
        XCTAssertEqual(appended.map(\.source), ["Page 1234"])
    }

    func testOCRPipelineRetainsTranslationOnFirstMissAndAcceptsImmediateDeletion() async throws {
        let service = OCRService(recognizer: { image, _, _ in
            guard let pixels = ImagePixels(image) else { return [] }
            let hasRed = stride(from: 0, to: pixels.bytes.count, by: 4).contains { pixels.bytes[$0] > 200 && pixels.bytes[$0 + 1] < 50 }
            let hasInk = stride(from: 0, to: pixels.bytes.count, by: 4).contains { pixels.bytes[$0] < 20 }
            guard !hasRed, hasInk else { return [] }
            return [TextLine(text: "Page 123", rect: CGRect(x: 20.0 / 320, y: 0.3, width: 200.0 / 320, height: 0.28), confidence: 1)]
        })
        let firstFrame = try frame()
        let initial = try await service.recognize(firstFrame.image, language: "en-US", previousFingerprint: nil)
        var translated = try XCTUnwrap(initial.blocks)
        translated[0].translation = "기존 번역"
        let cursor = try frame(caret: 1)
        let missed = try await service.recognize(cursor.image, language: "en-US", previousFingerprint: initial.fingerprint)
        let reconciled = TextSnapshot.reconcile(try XCTUnwrap(missed.blocks), previous: translated, pixelSize: CGSize(width: 320, height: 100))
        XCTAssertEqual(reconciled, translated)
        let forced = try await service.recognize(cursor.image, language: "en-US", previousFingerprint: nil)
        XCTAssertEqual(forced.blocks?.map(\.source), translated.map(\.source), "Manual refresh must also keep glyphs that remain visible")
        let deleted = try frame(erased: true)
        let deletion = try await service.recognize(deleted.image, language: "en-US", previousFingerprint: missed.fingerprint)
        XCTAssertEqual(deletion.blocks, [])
    }

    func testPendingCursorCandidateKeepsTranslatedPixelsButActualEditDoesNot() async throws {
        let renderer = OverlayImageRenderer()
        let size = CGSize(width: 320, height: 100)
        let off = try frame()
        _ = try await renderer.renderPatches(image: off.image, pointSize: size, blocks: [block()], style: .cover, pixels: off.pixels)
        let on = try frame(caret: 0)
        var candidate = block("Page 123I")
        candidate.translation = nil
        let retained = try await renderer.renderPatches(image: on.image, pointSize: size, blocks: [candidate], style: .cover, pixels: on.pixels)
        var expectedBlock = candidate
        expectedBlock.translation = "기존 번역"
        let expected = try await OverlayImageRenderer().renderPatches(image: on.image, pointSize: size, blocks: [expectedBlock], style: .cover)
        XCTAssertEqual(retained.map { ImageFingerprint.make($0.image) }, expected.map { ImageFingerprint.make($0.image) })
        let edited = try frame(caret: 0, addition: true)
        var newText = block("Page 128")
        newText.translation = nil
        let updated = try await renderer.renderPatches(image: edited.image, pointSize: size, blocks: [newText], style: .cover, pixels: edited.pixels)
        let pending = try await OverlayImageRenderer().renderPatches(image: edited.image, pointSize: size, blocks: [newText], style: .cover)
        XCTAssertEqual(updated.map { ImageFingerprint.make($0.image) }, pending.map { ImageFingerprint.make($0.image) })
        let deleted = try frame(erased: true)
        let cleared = try await renderer.renderPatches(image: deleted.image, pointSize: size, blocks: [], style: .cover)
        XCTAssertTrue(cleared.isEmpty)
    }

    @MainActor
    func testOverlayAcceptsOCRAcrossBlinkPhasesAndRejectsARealEdit() async throws {
        let clock = Clock()
        let stabilizer = OCRFrameStabilizer(now: { clock.read() })
        try await learn(stabilizer, clock: clock, caret: 2)
        let session = ImageOverlaySession(stabilizer: stabilizer)
        defer { session.reset() }
        let off = try frame(sequence: 3), on = try frame(caret: 2, sequence: 4)
        session.observe(on)
        let captured = CapturedImage(image: off.image, screenRect: CGRect(x: 0, y: 0, width: 320, height: 100),
            fingerprint: off.fingerprint, pixels: off.pixels, sequence: off.sequence)
        let accepted = await session.accept(captured, blocks: [block()])
        XCTAssertTrue(accepted)
        let rendered = expectation(description: "Translation remains available across cursor phases")
        session.didRender = { rendered.fulfill() }
        session.prepare(blocks: [block()], settings: AppSettings())
        await fulfillment(of: [rendered], timeout: 5)
        session.didRender = nil
        XCTAssertEqual(session.presentation?.patches.count, 1)
        clock.set(1.4)
        let edit = try frame(caret: 2, edit: true, sequence: 5)
        await stabilizer.observe(edit)
        session.observe(edit)
        let stale = await session.accept(captured, blocks: [block()])
        XCTAssertFalse(stale)
        XCTAssertEqual(session.presentation?.patches.count, 1, "Keep the last completed translation during fresh OCR")
    }
}

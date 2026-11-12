import AppKit
import Synchronization
import XCTest
import LineLensCore
@testable import LineLens

final class ImageOverlaySessionTests: XCTestCase {
    @MainActor
    private func frame(number: Int = 123, animation: Int = 0, noise: Bool = false, hasText: Bool = true,
                       highlighted: Bool = false, secondLine: String? = nil) throws -> CapturedFrame {
        let image = NSImage(size: NSSize(width: 500, height: 300), flipped: true) { bounds in
            NSColor.white.setFill()
            bounds.fill()
            if highlighted {
                NSColor(srgbRed: 0.14, green: 0.32, blue: 0.60, alpha: 1).setFill()
                CGRect(x: 44, y: 57, width: 265, height: 44).fill()
            }
            if hasText {
                ("Page \(number)" as NSString).draw(at: CGPoint(x: 50, y: 60), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 24), .foregroundColor: highlighted ? NSColor.white : .black,
                ])
            }
            if let secondLine {
                (secondLine as NSString).draw(at: CGPoint(x: 50, y: 108), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black,
                ])
            }
            NSColor(srgbRed: CGFloat(animation % 10) / 10, green: 0.3, blue: 0.5, alpha: 1).setFill()
            CGRect(x: 400, y: 250, width: 80, height: 30).fill()
            if noise {
                NSColor(calibratedWhite: 0.98, alpha: 1).setFill()
                CGRect(x: 220, y: 65, width: 1, height: 1).fill()
            }
            return true
        }
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let pixels = try XCTUnwrap(ImagePixels(cgImage))
        return CapturedFrame(image: cgImage, fingerprint: pixels.fingerprint, pixels: pixels)
    }

    private func block(number: Int = 123) -> TextBlock {
        var block = TextBlock(source: "Page \(number)", rect: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.12), confidence: 1)
        block.translation = "\(number)페이지"
        return block
    }

    private func captured(_ frame: CapturedFrame) -> CapturedImage {
        CapturedImage(image: frame.image, screenRect: CGRect(x: 0, y: 0, width: 500, height: 300),
            fingerprint: frame.fingerprint, pixels: frame.pixels, sequence: frame.sequence)
    }

    @MainActor
    func testInPlaceStyleClearsTheCapturedBackgroundAndKeepsLineGapsTransparent() async throws {
        let session = ImageOverlaySession()
        let controller = TranslationOverlayController()
        defer { controller.clear() }
        let frame = try frame()
        let capture = captured(frame)
        let lines = [
            TextLine(text: "Page 123", rect: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.08), confidence: 1),
            TextLine(text: "Continue", rect: CGRect(x: 0.1, y: 0.4, width: 0.5, height: 0.08), confidence: 1),
        ]
        var block = TextBlock(source: "Page 123 Continue", rect: lines[0].rect.union(lines[1].rect), confidence: 1, lines: lines)
        block.translation = "다음"
        session.observe(frame)
        let accepted = await session.accept(capture, blocks: [block])
        XCTAssertNotNil(accepted)

        var settings = AppSettings()
        for style in [OverlayStyle.cover, .inPlace, .cover] {
            settings.overlayStyle = style
            session.invalidateImage()
            let rendered = expectation(description: "Rendered \(style.rawValue)")
            session.didRender = { rendered.fulfill() }
            session.prepare(blocks: [block], settings: settings)
            await fulfillment(of: [rendered], timeout: 5)
            let presentation = try XCTUnwrap(session.presentation)
            controller.show(rect: capture.screenRect, presentation: presentation, livePreview: false)
            if style == .cover {
                XCTAssertTrue((controller.backgroundContents as AnyObject?) === frame.image)
                continue
            }
            XCTAssertNil(controller.backgroundContents)
            XCTAssertEqual(controller.patchLayerCount, 1)
            XCTAssertTrue(try XCTUnwrap(controller.window).ignoresMouseEvents)
            let patch = try XCTUnwrap(presentation.patches.first)
            let pixels = try XCTUnwrap(ImagePixels(patch.image))
            func alpha(atY y: CGFloat) -> UInt8 {
                let x = Int((0.55 - patch.rect.minX) / patch.rect.width * CGFloat(pixels.width))
                let row = Int((y - patch.rect.minY) / patch.rect.height * CGFloat(pixels.height))
                return pixels.bytes[(row * pixels.width + x) * 4 + 3]
            }
            XCTAssertEqual(alpha(atY: 0.24), 255, "First original line is covered")
            XCTAssertEqual(alpha(atY: 0.34), 0, "The real screen shows through the unused gap")
            XCTAssertEqual(alpha(atY: 0.44), 255, "Second original line is covered")
        }
    }

    @MainActor
    func testBackgroundAnimationAndPeriodicRefreshKeepTranslationVisible() async throws {
        let session = ImageOverlaySession()
        let first = try frame()
        let blocks = [block()]
        session.observe(first)
        let accepted = await session.accept(captured(first), blocks: blocks)
        XCTAssertNotNil(accepted)
        let rendered = expectation(description: "Initial translation rendered")
        session.didRender = { rendered.fulfill() }
        session.prepare(blocks: blocks, settings: AppSettings())
        await fulfillment(of: [rendered], timeout: 5)
        session.didRender = nil
        XCTAssertNotNil(session.image)
        var invalidations = 0
        session.didInvalidate = { invalidations += 1 }

        for index in 1...8 {
            let next = try frame(animation: index, noise: true)
            session.observe(next)
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertNotNil(session.image, "Animation outside text must not hide its translation")
        }
        let next = try frame(animation: 8, noise: true)
        let refreshed = await session.accept(captured(next), blocks: blocks)
        XCTAssertNotNil(refreshed)
        let replaced = expectation(description: "Replacement rendered without clearing current image")
        session.didRender = { replaced.fulfill() }
        let previousImage = session.image
        session.prepare(blocks: blocks, settings: AppSettings())
        XCTAssertTrue(session.image === previousImage)
        await fulfillment(of: [replaced], timeout: 5)
        XCTAssertNotNil(session.image)
        XCTAssertEqual(invalidations, 0)
        session.reset()
    }

    @MainActor
    func testActualDigitEditPublishesFreshMaskedLayoutBeforeTranslationFinishes() async throws {
        let session = ImageOverlaySession()
        let first = try frame()
        session.observe(first)
        let accepted = await session.accept(captured(first), blocks: [block()])
        XCTAssertNotNil(accepted)
        let rendered = expectation(description: "Initial screen rendered")
        session.didRender = { rendered.fulfill() }
        session.prepare(blocks: [block()], settings: AppSettings())
        await fulfillment(of: [rendered], timeout: 5)
        session.didRender = nil
        let previousImage = try XCTUnwrap(session.image)
        var invalidations = 0
        session.didInvalidate = { invalidations += 1 }
        let refresh = expectation(description: "Changed text requests OCR")
        session.needsRecognition = { refresh.fulfill() }
        let next = try frame(number: 124)
        session.observe(next)
        await fulfillment(of: [refresh], timeout: 5)
        session.prepare(blocks: [block()], settings: AppSettings())
        XCTAssertTrue(session.image === previousImage, "Source changes must not reveal the original screen")
        let staleAccepted = await session.accept(captured(first), blocks: [block()])
        XCTAssertNil(staleAccepted)
        var pending = block(number: 124)
        pending.translation = nil
        let nextAccepted = await session.accept(captured(next), blocks: [pending])
        XCTAssertNotNil(nextAccepted)
        let previewed = expectation(description: "Fresh layout published before translation finishes")
        session.didRender = { previewed.fulfill() }
        session.prepare(blocks: [pending], settings: AppSettings())
        await fulfillment(of: [previewed], timeout: 5)
        let previewImage = try XCTUnwrap(session.image)
        XCTAssertFalse(previewImage === previousImage, "Interaction feedback must not wait for every translation")
        let recognized = try await OCRService().recognize(previewImage, language: "en-US", previousFingerprint: nil)
        XCTAssertFalse((recognized.blocks ?? []).contains { $0.source.contains("Page") }, "Pending source labels must be masked")
        let replaced = expectation(description: "Complete translated screen swapped")
        session.didRender = { replaced.fulfill() }
        session.prepare(blocks: [block(number: 124)], settings: AppSettings())
        XCTAssertTrue(session.image === previewImage)
        await fulfillment(of: [replaced], timeout: 5)
        XCTAssertNotNil(session.image)
        XCTAssertFalse(session.image === previousImage)
        XCTAssertEqual(invalidations, 0)
        session.reset()
    }

    @MainActor
    func testPartialTranslationUpdatesLayoutAndMasksOnlyPendingLabels() async throws {
        let session = ImageOverlaySession()
        let first = try frame()
        session.observe(first)
        let accepted = await session.accept(captured(first), blocks: [block()])
        XCTAssertNotNil(accepted)
        let rendered = expectation(description: "Initial render")
        session.didRender = { rendered.fulfill() }
        session.prepare(blocks: [block()], settings: AppSettings())
        await fulfillment(of: [rendered], timeout: 5)
        session.didRender = nil
        let previousImage = session.image
        var pending = TextBlock(source: "New paragraph", rect: CGRect(x: 0.1, y: 0.5, width: 0.5, height: 0.1), confidence: 1)
        let previewed = expectation(description: "Partial translations published")
        session.didRender = { previewed.fulfill() }
        session.prepare(blocks: [block(), pending], settings: AppSettings())
        await fulfillment(of: [previewed], timeout: 5)
        XCTAssertNotNil(session.image)
        XCTAssertFalse(session.image === previousImage)
        let replaced = expectation(description: "All paragraphs translated")
        session.didRender = { replaced.fulfill() }
        pending.translation = "새 문단"
        session.prepare(blocks: [block(), pending], settings: AppSettings())
        await fulfillment(of: [replaced], timeout: 5)
        XCTAssertFalse(session.image === previousImage)
        session.reset()
    }

    @MainActor
    func testTemporaryCaptureSuspensionKeepsLastScreenAndRejectsOldWork() async throws {
        let session = ImageOverlaySession()
        let first = try frame()
        session.observe(first)
        let accepted = await session.accept(captured(first), blocks: [block()])
        XCTAssertNotNil(accepted)
        let rendered = expectation(description: "Initial render")
        session.didRender = { rendered.fulfill() }
        session.prepare(blocks: [block()], settings: AppSettings())
        await fulfillment(of: [rendered], timeout: 5)
        let previousImage = session.image
        session.suspend()
        session.prepare(blocks: [block()], settings: AppSettings())
        XCTAssertTrue(session.image === previousImage)
        let staleAccepted = await session.accept(captured(first), blocks: [block()])
        XCTAssertNil(staleAccepted)
        session.reset()
        XCTAssertNil(session.image)
    }

    @MainActor
    func testChangeDuringTranslationCancelsNewWorkWithoutClearingCompletedScreen() async throws {
        let session = ImageOverlaySession()
        let first = try frame()
        session.observe(first)
        let accepted = await session.accept(captured(first), blocks: [block()])
        XCTAssertNotNil(accepted)
        let rendered = expectation(description: "Initial render")
        session.didRender = { rendered.fulfill() }
        session.prepare(blocks: [block()], settings: AppSettings())
        await fulfillment(of: [rendered], timeout: 5)
        session.didRender = nil
        let previousImage = session.image
        let second = try frame(number: 124)
        session.observe(second)
        var pending = block(number: 124)
        pending.translation = nil
        let secondAccepted = await session.accept(captured(second), blocks: [pending])
        XCTAssertNotNil(secondAccepted)
        let previewed = expectation(description: "Pending layout published")
        session.didRender = { previewed.fulfill() }
        session.prepare(blocks: [pending], settings: AppSettings())
        await fulfillment(of: [previewed], timeout: 5)
        session.didRender = nil
        let previewImage = session.image
        let refresh = expectation(description: "Untranslated source still checked for further changes")
        session.needsRecognition = { refresh.fulfill() }
        session.observe(try frame(number: 125))
        await fulfillment(of: [refresh], timeout: 5)
        session.prepare(blocks: [block(number: 124)], settings: AppSettings())
        XCTAssertTrue(session.image === previewImage)
        XCTAssertFalse(session.image === previousImage)
        session.reset()
    }

    @MainActor
    func testTextFreeFrameReplacesOldTranslationWithCompletedEmptyScreen() async throws {
        let session = ImageOverlaySession()
        let first = try frame()
        session.observe(first)
        let accepted = await session.accept(captured(first), blocks: [block()])
        XCTAssertNotNil(accepted)
        let rendered = expectation(description: "Initial render")
        session.didRender = { rendered.fulfill() }
        session.prepare(blocks: [block()], settings: AppSettings())
        await fulfillment(of: [rendered], timeout: 5)
        session.didRender = nil
        let empty = try frame(hasText: false)
        session.observe(empty)
        let emptyAccepted = await session.accept(captured(empty), blocks: [])
        XCTAssertNotNil(emptyAccepted)
        let replaced = expectation(description: "Text-free screen published")
        session.didRender = { replaced.fulfill() }
        session.prepare(blocks: [], settings: AppSettings())
        await fulfillment(of: [replaced], timeout: 5)
        let image = try XCTUnwrap(session.image)
        XCTAssertEqual(ImageFingerprint.make(image), empty.fingerprint)
        session.reset()
    }

    @MainActor
    func testNativeWindowStaysVisibleThroughContentChangesAndResizing() async throws {
        let session = ImageOverlaySession()
        let controller = TranslationOverlayController()
        defer { controller.clear(); session.reset() }
        var rect = CGRect(x: 40, y: 70, width: 500, height: 300)
        session.didInvalidate = { controller.clear() }
        let first = try frame()
        session.observe(first)
        let accepted = await session.accept(captured(first), blocks: [block()])
        XCTAssertNotNil(accepted)
        let rendered = expectation(description: "Native window shown")
        session.didRender = {
            if let image = session.image { controller.show(rect: rect, image: image) }
            rendered.fulfill()
        }
        session.prepare(blocks: [block()], settings: AppSettings())
        await fulfillment(of: [rendered], timeout: 5)
        session.didRender = nil
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.isVisible)
        let refresh = expectation(description: "Content changed")
        session.needsRecognition = { refresh.fulfill() }
        session.observe(try frame(number: 124))
        await fulfillment(of: [refresh], timeout: 5)
        session.prepare(blocks: [block(number: 124)], settings: AppSettings())
        XCTAssertTrue(window.isVisible)
        rect.size = CGSize(width: 650, height: 400)
        controller.show(rect: rect, image: try XCTUnwrap(session.image))
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.frame.size, rect.size)
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertTrue(controller.window === window)
    }

    @MainActor
    func testOCRCanFinishWhileUnrelatedBackgroundChanged() async throws {
        let session = ImageOverlaySession()
        let first = try frame()
        session.observe(first)
        session.observe(try frame(animation: 3))
        let accepted = await session.accept(captured(first), blocks: [block()])
        XCTAssertNotNil(accepted, "Background updates during OCR must not starve recognition")
        session.reset()
    }

    @MainActor
    func testBackgroundFramesArrivingDuringValidationDoNotPreventFirstTranslation() async throws {
        let onComparison = Mutex<(@Sendable () -> Void)?>(nil)
        let stabilizer = OCRFrameStabilizer(now: {
            onComparison.withLock { $0 }?()
            return 0
        })
        let session = ImageOverlaySession(stabilizer: stabilizer)
        defer {
            onComparison.withLock { $0 = nil }
            session.reset()
        }
        let original = try frame()
        var seed = original
        // Trigger the clock on frame comparison, independent of cursor tracking.
        seed.sequence = .max
        await stabilizer.observe(seed)
        let backgrounds = try (1...4).map { index in
            var next = try frame(animation: index)
            next.sequence = UInt64(index)
            return next
        }
        session.observe(backgrounds[0])
        let remaining = Mutex(backgrounds.dropFirst())
        onComparison.withLock { callback in
            callback = {
                guard let next = remaining.withLock({ $0.popFirst() }) else { return }
                let advanced = DispatchSemaphore(value: 0)
                Task { @MainActor in
                    session.observe(next)
                    advanced.signal()
                }
                XCTAssertEqual(advanced.wait(timeout: .now() + 2), .success)
            }
        }

        let translated = block()
        let accepted = await session.accept(captured(original), blocks: [translated])
        await render(try XCTUnwrap(accepted), session: session, settings: AppSettings())
        XCTAssertEqual(session.presentation?.patches.map(\.id), [translated.id])

        var edited = try frame(number: 124, animation: 5)
        edited.sequence = 5
        remaining.withLock { $0 = [edited][...] }
        let stale = await session.accept(captured(original), blocks: [translated])
        XCTAssertNil(stale, "A newer frame with edited text must reject the old recognition")
    }

    @MainActor
    func testRecoloredTextCanPublishInEveryOverlayStyleButAnEditedDigitRejectsOldOCR() async throws {
        let original = try frame()
        let highlighted = try frame(highlighted: true)
        let edited = try frame(number: 124, highlighted: true)
        for style in OverlayStyle.allCases {
            let session = ImageOverlaySession()
            session.observe(original)
            session.observe(highlighted)
            let accepted = await session.accept(captured(original), blocks: [block()])
            XCTAssertNotNil(accepted, "A selection highlight must not block recognition in \(style)")

            let rendered = expectation(description: "Translation becomes visible in \(style)")
            session.didRender = { rendered.fulfill() }
            var settings = AppSettings()
            settings.overlayStyle = style
            session.prepare(blocks: [block()], settings: settings)
            await fulfillment(of: [rendered], timeout: 5)
            XCTAssertEqual(session.presentation?.patches.count, 1)
            XCTAssertTrue(session.presentation?.source === highlighted.image, "Render with the newest verified colors")
            session.didRender = nil

            session.observe(edited)
            let stale = await session.accept(captured(original), blocks: [block()])
            XCTAssertNil(stale, "Color tolerance must not hide a digit change")
            let fresh = await session.accept(captured(edited), blocks: [block(number: 124)])
            XCTAssertNotNil(fresh)
            session.reset()
        }
    }

    @MainActor
    func testRecognitionMissKeepsThePreviousTranslationUntilVisibleTextChanges() async throws {
        let original = try frame()
        let highlighted = try frame(highlighted: true)
        let edited = try frame(number: 124, highlighted: true)
        let empty = try frame(hasText: false)
        let animatedEmpty = try frame(animation: 1, hasText: false)

        for style in OverlayStyle.allCases {
            let session = ImageOverlaySession()
            var settings = AppSettings()
            settings.overlayStyle = style
            let previous = block()
            var recognized = previous
            recognized.translation = nil
            session.observe(original)
            let accepted = await session.accept(captured(original), blocks: [recognized])
            XCTAssertEqual(accepted, [recognized])
            await render([previous], session: session, settings: settings)

            session.observe(highlighted)
            let missed = await session.accept(captured(highlighted), blocks: [])
            let retained = TextSnapshot.reconcile(try XCTUnwrap(missed), previous: [previous], pixelSize: CGSize(width: 500, height: 300))
            XCTAssertEqual(retained, [previous])
            await render(retained, session: session, settings: settings)
            XCTAssertEqual(session.presentation?.patches.map(\.id), [previous.id])

            session.observe(edited)
            let replaced = await session.accept(captured(edited), blocks: [block(number: 124)])
            XCTAssertEqual(replaced?.map(\.source), ["Page 124"])
            await render(try XCTUnwrap(replaced), session: session, settings: settings)
            XCTAssertEqual(session.presentation?.patches.map(\.id), replaced?.map(\.id))

            session.observe(animatedEmpty)
            let removed = await session.accept(captured(empty), blocks: [])
            XCTAssertEqual(removed, [])
            await render(try XCTUnwrap(removed), session: session, settings: settings)
            XCTAssertTrue(try XCTUnwrap(session.presentation).patches.isEmpty)
            session.reset()
        }
    }

    @MainActor
    func testMergedOCRKeepsTheUnchangedParagraphAndUpdatesTheAdjacentLine() async throws {
        let session = ImageOverlaySession()
        defer { session.reset() }
        let original = try frame(secondLine: "Next 123")
        let edited = try frame(highlighted: true, secondLine: "Next 124")
        var first = block()
        let firstLine = TextLine(text: first.source, rect: first.rect, confidence: 1)
        first.lines = [firstLine]
        let secondRect = first.rect.offsetBy(dx: 0, dy: 0.16)
        let oldLine = TextLine(text: "Next 123", rect: secondRect, confidence: 1)
        let second = TextBlock(source: oldLine.text, rect: oldLine.rect, confidence: 1, lines: [oldLine])
        session.observe(original)
        let accepted = await session.accept(captured(original), blocks: [first, second])
        XCTAssertEqual(accepted, [first, second])

        let refresh = expectation(description: "Edited line invalidates the accepted frame")
        session.needsRecognition = { refresh.fulfill() }
        session.observe(edited)
        await fulfillment(of: [refresh], timeout: 5)
        let editedLine = TextLine(text: "Next 124", rect: secondRect, confidence: 1)
        let merged = TextBlock(source: "Page 123 Next 124", rect: first.rect.union(secondRect),
            confidence: 1, lines: [firstLine, editedLine])
        let result = await session.accept(captured(edited), blocks: [merged])
        let updated = try XCTUnwrap(result)
        XCTAssertEqual(updated.map(\.source), [first.source, editedLine.text])
        XCTAssertEqual(updated.first, first)
        XCTAssertEqual(updated.last?.lines, [editedLine])
    }

    @MainActor
    private func render(_ blocks: [TextBlock], session: ImageOverlaySession, settings: AppSettings) async {
        let rendered = expectation(description: "Translation patches rendered")
        session.didRender = { rendered.fulfill() }
        session.prepare(blocks: blocks, settings: settings)
        await fulfillment(of: [rendered], timeout: 5)
        session.didRender = nil
    }

    @MainActor
    func testOlderCapturedFrameCannotReplaceTheLatestScreenAfterScroll() async throws {
        let session = ImageOverlaySession()
        defer { session.reset() }
        var first = try frame(number: 123)
        first.sequence = 10
        var old = try frame(number: 124)
        old.sequence = 15
        var current = try frame(number: 123)
        current.sequence = 20
        session.observe(first)
        session.observe(current)
        // AppModel also feeds the capture used by OCR into the session. A
        // delayed capture must not rewind a newer continuous-capture frame.
        session.observe(old)
        let stale = await session.accept(captured(old), blocks: [block(number: 124)])
        XCTAssertNil(stale)
        let fresh = await session.accept(captured(current), blocks: [block(number: 123)])
        XCTAssertNotNil(fresh)
    }

    @MainActor
    func testResetCancelsPendingComposition() async throws {
        let session = ImageOverlaySession()
        let first = try frame()
        session.observe(first)
        let accepted = await session.accept(captured(first), blocks: [block()])
        XCTAssertNotNil(accepted)
        session.prepare(blocks: [block()], settings: AppSettings())
        session.reset()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(session.image)
        let staleAccepted = await session.accept(captured(first), blocks: [block()])
        XCTAssertNil(staleAccepted)
    }

    @MainActor
    func testTranslationOffClearsAnAlreadyVisibleOverlay() async throws {
        let session = ImageOverlaySession()
        let first = try frame()
        session.observe(first)
        let accepted = await session.accept(captured(first), blocks: [block()])
        XCTAssertNotNil(accepted)
        let rendered = expectation(description: "Rendered")
        session.didRender = { rendered.fulfill() }
        session.prepare(blocks: [block()], settings: AppSettings())
        await fulfillment(of: [rendered], timeout: 5)
        XCTAssertNotNil(session.image)
        var settings = AppSettings()
        settings.translationEnabled = false
        session.prepare(blocks: [block()], settings: settings)
        XCTAssertNil(session.image)
        session.reset()
    }

    @MainActor
    func testMatcherRejectsResizeAndUsesLocalTextChangesRatherThanWholeImagePercentage() async throws {
        let matcher = OverlayFrameMatcher()
        let first = try frame()
        let second = try frame(number: 124)
        let sameText = try frame(animation: 4, noise: true)
        let regions = [block().rect]
        let unchanged = try await matcher.matches(sameText.image, baseline: first.image, regions: regions)
        XCTAssertTrue(unchanged)
        let changed = try await matcher.matches(second.image, baseline: first.image, regions: regions)
        XCTAssertFalse(changed)
        let cropped = try XCTUnwrap(first.image.cropping(to: CGRect(x: 0, y: 0, width: 40, height: 40)))
        let resized = try await matcher.matches(cropped, baseline: first.image, regions: regions)
        XCTAssertFalse(resized)
    }
}

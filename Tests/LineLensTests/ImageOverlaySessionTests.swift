import AppKit
import XCTest
import LineLensCore
@testable import LineLens

final class ImageOverlaySessionTests: XCTestCase {
    @MainActor
    private func frame(number: Int = 123, animation: Int = 0, noise: Bool = false, hasText: Bool = true) throws -> CapturedFrame {
        let image = NSImage(size: NSSize(width: 500, height: 300), flipped: true) { bounds in
            NSColor.white.setFill()
            bounds.fill()
            if hasText {
                ("Page \(number)" as NSString).draw(at: CGPoint(x: 50, y: 60), withAttributes: [
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
        return CapturedFrame(image: cgImage, fingerprint: ImageFingerprint.make(cgImage))
    }

    private func block(number: Int = 123) -> TextBlock {
        var block = TextBlock(source: "Page \(number)", rect: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.12), confidence: 1)
        block.translation = "\(number)페이지"
        return block
    }

    private func captured(_ frame: CapturedFrame) -> CapturedImage {
        CapturedImage(image: frame.image, screenRect: CGRect(x: 0, y: 0, width: 500, height: 300), fingerprint: frame.fingerprint)
    }

    @MainActor
    func testBackgroundAnimationAndPeriodicRefreshKeepTranslationVisible() async throws {
        let session = ImageOverlaySession()
        let first = try frame()
        let blocks = [block()]
        session.observe(first)
        let accepted = await session.accept(captured(first), blocks: blocks)
        XCTAssertTrue(accepted)
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
        XCTAssertTrue(refreshed)
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
        XCTAssertTrue(accepted)
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
        XCTAssertFalse(staleAccepted)
        var pending = block(number: 124)
        pending.translation = nil
        let nextAccepted = await session.accept(captured(next), blocks: [pending])
        XCTAssertTrue(nextAccepted)
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
        XCTAssertTrue(accepted)
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
        XCTAssertTrue(accepted)
        let rendered = expectation(description: "Initial render")
        session.didRender = { rendered.fulfill() }
        session.prepare(blocks: [block()], settings: AppSettings())
        await fulfillment(of: [rendered], timeout: 5)
        let previousImage = session.image
        session.suspend()
        session.prepare(blocks: [block()], settings: AppSettings())
        XCTAssertTrue(session.image === previousImage)
        let staleAccepted = await session.accept(captured(first), blocks: [block()])
        XCTAssertFalse(staleAccepted)
        session.reset()
        XCTAssertNil(session.image)
    }

    @MainActor
    func testChangeDuringTranslationCancelsNewWorkWithoutClearingCompletedScreen() async throws {
        let session = ImageOverlaySession()
        let first = try frame()
        session.observe(first)
        let accepted = await session.accept(captured(first), blocks: [block()])
        XCTAssertTrue(accepted)
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
        XCTAssertTrue(secondAccepted)
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
        XCTAssertTrue(accepted)
        let rendered = expectation(description: "Initial render")
        session.didRender = { rendered.fulfill() }
        session.prepare(blocks: [block()], settings: AppSettings())
        await fulfillment(of: [rendered], timeout: 5)
        session.didRender = nil
        let empty = try frame(hasText: false)
        session.observe(empty)
        let emptyAccepted = await session.accept(captured(empty), blocks: [])
        XCTAssertTrue(emptyAccepted)
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
        XCTAssertTrue(accepted)
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
        XCTAssertTrue(accepted, "Background updates during OCR must not starve recognition")
        session.reset()
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
        XCTAssertFalse(stale)
        let fresh = await session.accept(captured(current), blocks: [block(number: 123)])
        XCTAssertTrue(fresh)
    }

    @MainActor
    func testResetCancelsPendingComposition() async throws {
        let session = ImageOverlaySession()
        let first = try frame()
        session.observe(first)
        let accepted = await session.accept(captured(first), blocks: [block()])
        XCTAssertTrue(accepted)
        session.prepare(blocks: [block()], settings: AppSettings())
        session.reset()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(session.image)
        let staleAccepted = await session.accept(captured(first), blocks: [block()])
        XCTAssertFalse(staleAccepted)
    }

    @MainActor
    func testTranslationOffClearsAnAlreadyVisibleOverlay() async throws {
        let session = ImageOverlaySession()
        let first = try frame()
        session.observe(first)
        let accepted = await session.accept(captured(first), blocks: [block()])
        XCTAssertTrue(accepted)
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

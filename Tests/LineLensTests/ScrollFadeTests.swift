import AppKit
import CoreVideo
import XCTest
import LineLensCore
@testable import LineLens

final class ScrollFadeTests: XCTestCase {
    @MainActor
    private func frame() throws -> CapturedFrame {
        let context = try XCTUnwrap(CGContext(data: nil, width: 500, height: 300, bitsPerComponent: 8, bytesPerRow: 2000,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 500, height: 300))
        let image = try XCTUnwrap(context.makeImage())
        let pixels = try XCTUnwrap(ImagePixels(image))
        return CapturedFrame(image: image, fingerprint: pixels.fingerprint, pixels: pixels)
    }

    private func wheel() -> ScrollInteraction {
        ScrollInteraction(location: .zero, delta: CGPoint(x: 0, y: 12), isEnding: false, isMomentum: false, isBeginning: false)
    }

    @MainActor
    func testControllerCoalescesWheelInputsAndResetCancelsThePreviousTarget() async throws {
        let controller = ScrollActivityController()
        var starts = 0, finishes = 0
        controller.didStart = { starts += 1 }
        controller.didSettle = { finishes += 1 }
        controller.note(wheel())
        controller.note(wheel())
        XCTAssertTrue(controller.isScrolling)
        XCTAssertEqual(starts, 1)
        controller.reset()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(finishes, 0)
        let settled = expectation(description: "One refresh after the last wheel input")
        controller.didSettle = { finishes += 1; settled.fulfill() }
        controller.note(wheel())
        await fulfillment(of: [settled], timeout: 2)
        XCTAssertEqual(finishes, 1)
        XCTAssertFalse(controller.isScrolling)
    }

    @MainActor
    func testFadeRevealsTheSourceThenDiscardsImagesAndBlocksOldPresentation() async throws {
        let source = try frame().image
        let patch = OverlayPatch(id: UUID(), rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1), image: source)
        let presentation = OverlayPresentation(source: source, patches: [patch], coversSource: true)
        let controller = TranslationOverlayController()
        defer { controller.clear() }
        let rect = CGRect(x: 20, y: 40, width: 500, height: 300)
        controller.show(rect: rect, presentation: presentation, livePreview: true)
        let window = try XCTUnwrap(controller.window)
        let initialFrame = window.frame
        XCTAssertEqual(window.animationBehavior, .none)
        controller.fadeOutAndDiscard(duration: 0.04)
        XCTAssertNil(controller.backgroundContents, "The actual app must be visible during the fade")
        XCTAssertEqual(controller.patchOpacity, 0)
        controller.show(rect: rect, presentation: presentation, livePreview: true)
        XCTAssertNil(controller.backgroundContents, "A late response must not revive the old screenshot")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.patchLayerCount, 0)
        XCTAssertTrue(window.isVisible, "Scrolling keeps one empty transparent window instead of ordering it out/in")
        XCTAssertEqual(window.frame, initialFrame)
        XCTAssertTrue(window.ignoresMouseEvents)
        controller.show(rect: rect, presentation: presentation, livePreview: true)
        XCTAssertEqual(controller.patchLayerCount, 0, "Only an explicitly fresh result can restore the overlay")
    }

    @MainActor
    func testScrollRestorationUsesCurrentCaptureWithoutWindowResizeOrPixelFlash() async throws {
        let source = try frame().image
        let rect = CGRect(x: 20, y: 40, width: 500, height: 300)
        let controller = TranslationOverlayController()
        defer { controller.clear() }
        let presentation = OverlayPresentation(source: source, patches: [OverlayPatch(id: UUID(),
            rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1), image: source)], coversSource: true)
        controller.show(rect: rect, presentation: presentation, livePreview: true)
        let window = try XCTUnwrap(controller.window)
        let initialFrame = window.frame
        let number = window.windowNumber
        controller.fadeOutAndDiscard(duration: 0.03)
        try await Task.sleep(for: .milliseconds(80))
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let context = try XCTUnwrap(CGContext(data: nil, width: 500, height: 300, bitsPerComponent: 8, bytesPerRow: 2000,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: 500, height: 300))
        try XCTUnwrap(view.layer).render(in: context)
        let pixels = try XCTUnwrap(ImagePixels(XCTUnwrap(context.makeImage())))
        XCTAssertTrue(stride(from: 3, to: pixels.bytes.count, by: 4).allSatisfy { pixels.bytes[$0] == 0 },
            "After fade-out no source background or old patch pixels may flash")
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 500, 300, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &buffer), kCVReturnSuccess)
        let current = try XCTUnwrap(CapturedSurface(buffer: XCTUnwrap(buffer)))
        controller.updateBackground(current)
        XCTAssertNil(controller.backgroundContents)
        controller.show(rect: rect, presentation: presentation, livePreview: true, fadeIn: true)
        XCTAssertTrue((controller.backgroundContents as AnyObject?) === current.surface,
            "Restoration must not flash the older OCR source snapshot")
        XCTAssertEqual(window.windowNumber, number)
        XCTAssertEqual(window.frame, initialFrame)
        XCTAssertTrue(CATransform3DIsIdentity(try XCTUnwrap(view.layer).transform))
        for layer in view.layer?.sublayers ?? [] { XCTAssertTrue(CATransform3DIsIdentity(layer.transform)) }
        XCTAssertEqual(window.animationBehavior, .none)
    }

    @MainActor
    func testFreshLayoutSurvivesAnOlderFadeCompletionAndLaterReset() async throws {
        let source = try frame().image
        let old = OverlayPresentation(source: source, patches: [OverlayPatch(id: UUID(), rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1), image: source)], coversSource: true)
        let fresh = OverlayPresentation(source: source, patches: [OverlayPatch(id: UUID(), rect: CGRect(x: 0.5, y: 0.7, width: 0.2, height: 0.1), image: source)], coversSource: true)
        let controller = TranslationOverlayController()
        defer { controller.clear() }
        let rect = CGRect(x: 20, y: 40, width: 500, height: 300)
        controller.show(rect: rect, presentation: old, livePreview: true)
        controller.fadeOutAndDiscard(duration: 0.08)
        controller.show(rect: rect, presentation: fresh, livePreview: true, fadeIn: true)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(controller.window?.isVisible == true)
        XCTAssertEqual(controller.patchLayerCount, 1)
        XCTAssertEqual(controller.patchOpacity, 1)
        controller.fadeOutAndDiscard(duration: 0.08)
        controller.clear()
        controller.show(rect: rect, presentation: fresh, livePreview: false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(controller.window?.isVisible == true, "A previous target's fade must not hide a new target")
    }

    @MainActor
    func testSessionResetDropsPatchImageCacheAndRequiresFreshRecognition() async throws {
        let source = try frame()
        let capture = CapturedImage(image: source.image, screenRect: CGRect(x: 0, y: 0, width: 500, height: 300), fingerprint: source.fingerprint)
        var block = TextBlock(source: "Application settings", rect: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.1), confidence: 1)
        block.translation = "앱 설정"
        let session = ImageOverlaySession()
        defer { session.reset() }
        session.observe(source)
        let accepted = await session.accept(capture, blocks: [block])
        XCTAssertTrue(accepted)
        let firstRender = expectation(description: "Before scroll")
        session.didRender = { firstRender.fulfill() }
        session.prepare(blocks: [block], settings: AppSettings())
        await fulfillment(of: [firstRender], timeout: 5)
        let oldPatch = try XCTUnwrap(session.presentation?.patches.first?.image)
        session.reset()
        XCTAssertNil(session.presentation)
        let stale = await session.accept(capture, blocks: [block])
        XCTAssertFalse(stale)
        session.observe(source)
        let fresh = await session.accept(capture, blocks: [block])
        XCTAssertTrue(fresh)
        let secondRender = expectation(description: "After scroll, new image")
        session.didRender = { secondRender.fulfill() }
        session.prepare(blocks: [block], settings: AppSettings())
        await fulfillment(of: [secondRender], timeout: 5)
        XCTAssertFalse(try XCTUnwrap(session.presentation?.patches.first?.image) === oldPatch)
    }

    @MainActor
    func testScrollCancelsOldJobsDiscardsCoordinatesAndBlocksPeriodicRefresh() {
        let model = AppModel()
        let original = model.settings
        defer { model.stop(); model.settings = original }
        var settings = AppSettings()
        settings.translationEnabled = true
        settings.automaticRefresh = true
        model.settings = settings
        model.target = .region(displayID: 0, rect: CGRect(x: 0, y: 0, width: 500, height: 300))
        model.blocks = [TextBlock(source: "Application settings", rect: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.1), confidence: 1)]
        model.translateCurrentBlocks()
        XCTAssertTrue(model.translation.isWorking)
        model.beginScroll()
        XCTAssertTrue(model.isScrolling)
        XCTAssertTrue(model.isWaitingForScrollTranslation)
        XCTAssertTrue(model.blocks.isEmpty)
        XCTAssertFalse(model.translation.isWorking)
        XCTAssertNil(model.translation.configuration)
        model.requestRefresh(force: true)
        model.translateCurrentBlocks()
        XCTAssertFalse(model.isCapturing, "Neither polling nor manual refresh may start OCR during a scroll")
        XCTAssertFalse(model.translation.isWorking)
        model.stop()
        XCTAssertFalse(model.isScrolling)
        XCTAssertFalse(model.isWaitingForScrollTranslation)
        model.finishScroll()
        XCTAssertFalse(model.hasTarget)
        XCTAssertFalse(model.isCapturing)
    }
}

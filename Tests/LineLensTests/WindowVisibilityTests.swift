import AppKit
import LineLensCore
import XCTest
@testable import LineLens

final class WindowVisibilityTests: XCTestCase {
    private let targetID: CGWindowID = 42
    private let bounds = CGRect(x: 100, y: 100, width: 400, height: 300)

    private func window(_ id: CGWindowID, frame: CGRect, onScreen: Bool = true, pid: pid_t = 1) -> [String: Any] {
        [kCGWindowNumber as String: Int(id), kCGWindowOwnerPID as String: pid,
         kCGWindowBounds as String: frame.dictionaryRepresentation, kCGWindowIsOnscreen as String: onScreen,
         kCGWindowLayer as String: 0, kCGWindowAlpha as String: 1.0]
    }

    @MainActor
    private func service(_ windows: [[String: Any]], browserPID: pid_t? = nil) -> ScreenCaptureService {
        ScreenCaptureService(accessProbe: {}, windowInfoProvider: { options, id in
            if options.contains(.optionIncludingWindow) {
                return windows.filter { ($0[kCGWindowNumber as String] as? Int) == Int(id) }
            }
            return windows.filter { $0[kCGWindowIsOnscreen as String] as? Bool == true }
        }, isWebBrowser: { $0 == browserPID })
    }

    private var target: CaptureTarget { .window(id: targetID, processID: 1, title: "Background target", crop: nil) }

    @MainActor
    func testInactiveWindowBesideTheFrontWindowKeepsItsOverlayFrame() {
        let capture = service([
            window(9, frame: CGRect(x: 700, y: 100, width: 400, height: 300), pid: 2),
            window(targetID, frame: bounds),
        ])
        XCTAssertEqual(capture.visibleFrame(for: target), bounds)
        XCTAssertFalse(capture.isOccluded(target, rect: bounds, overlayWindowID: nil),
            "A higher window outside the target must not hide a visible background window")
    }

    @MainActor
    func testPartialAndCompleteOverlapStillHideTheTarget() {
        for cover in [CGRect(x: 450, y: 100, width: 200, height: 300), bounds] {
            let capture = service([window(9, frame: cover, pid: 2), window(targetID, frame: bounds)])
            XCTAssertEqual(capture.visibleFrame(for: target), bounds)
            XCTAssertTrue(capture.isOccluded(target, rect: bounds, overlayWindowID: nil))
        }
    }

    @MainActor
    func testOwnOverlayAndWindowsBehindTheTargetDoNotCountAsOcclusion() {
        let capture = service([
            window(99, frame: bounds, pid: ProcessInfo.processInfo.processIdentifier),
            window(targetID, frame: bounds),
            window(9, frame: bounds, pid: 2),
        ])
        XCTAssertFalse(capture.isOccluded(target, rect: bounds, overlayWindowID: 99))
        XCTAssertTrue(capture.isOccluded(target, rect: bounds, overlayWindowID: nil),
            "Other app-owned panels still count as real overlap")
    }

    @MainActor
    func testResultPanelCanStayInFrontWithoutHidingTheTranslationOverlay() throws {
        let model = AppModel()
        let originalSettings = model.settings
        let windows = AppWindows(model: model)
        defer {
            windows.overlay.clear()
            windows.hideResults()
            model.settings = originalSettings
        }
        model.settings.alwaysShowResults = true
        model.settings.pinResults = true
        windows.showResults()
        let results = try XCTUnwrap(windows.resultWindowAboveOverlay(at: .floating))
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let rect = CaptureGeometry.flipScreenRect(results.frame, mainDisplayHeight: NSScreen.screens.first?.frame.height ?? 0)
        windows.overlay.show(rect: rect, presentation: OverlayPresentation(source: image, patches: [], coversSource: true),
            livePreview: false, below: results.windowNumber)

        let overlay = try XCTUnwrap(windows.overlay.window)
        let ordered = try XCTUnwrap(NSWindow.windowNumbers(options: []))
        let resultIndex = try XCTUnwrap(ordered.firstIndex(of: NSNumber(value: results.windowNumber)))
        let overlayIndex = try XCTUnwrap(ordered.firstIndex(of: NSNumber(value: overlay.windowNumber)))
        XCTAssertLessThan(resultIndex, overlayIndex)

        let resultsInfo = window(90, frame: bounds, pid: ProcessInfo.processInfo.processIdentifier)
        let otherInfo = window(91, frame: bounds, pid: 2)
        let targetInfo = window(targetID, frame: bounds)
        let capture = service([resultsInfo, targetInfo])
        XCTAssertTrue(capture.isOccluded(target, rect: bounds, overlayWindowID: nil))
        XCTAssertFalse(capture.isOccluded(target, rect: bounds, overlayWindowID: nil, resultWindowID: 90))
        XCTAssertTrue(service([resultsInfo, otherInfo, targetInfo]).isOccluded(target, rect: bounds,
            overlayWindowID: nil, resultWindowID: 90))
    }

    @MainActor
    func testMinimizedClosedAndUnavailableWindowsStayHidden() {
        let minimized = service([window(targetID, frame: bounds, onScreen: false)])
        XCTAssertNil(minimized.visibleFrame(for: target))
        XCTAssertTrue(minimized.isOccluded(target, rect: bounds, overlayWindowID: nil))
        let closed = service([])
        XCTAssertNil(closed.visibleFrame(for: target))
        XCTAssertTrue(closed.isOccluded(target, rect: bounds, overlayWindowID: nil))
        let failed = ScreenCaptureService(accessProbe: {}, windowInfoProvider: { _, _ in nil })
        XCTAssertNil(failed.visibleFrame(for: target))
        XCTAssertTrue(failed.isOccluded(target, rect: bounds, overlayWindowID: nil))
    }

    @MainActor
    func testOnlyOverlapInsideTheSelectedCropHidesTheOverlay() throws {
        let capture = service([
            window(9, frame: CGRect(x: 100, y: 100, width: 150, height: 300), pid: 2),
            window(targetID, frame: bounds),
        ])
        let cropped = CaptureTarget.window(id: targetID, processID: 1, title: "Cropped background target",
            crop: CGRect(x: 0.5, y: 0.2, width: 0.4, height: 0.5))
        let frame = try XCTUnwrap(capture.visibleFrame(for: cropped))
        XCTAssertEqual(frame, CGRect(x: 300, y: 160, width: 160, height: 150))
        XCTAssertFalse(capture.isOccluded(cropped, rect: frame, overlayWindowID: nil))
        XCTAssertTrue(capture.isOccluded(target, rect: bounds, overlayWindowID: nil))
    }

    @MainActor
    func testNativeTooltipOverlapStillHidesWhileRegionCaptureKeepsItsExistingPolicy() {
        let tooltip = window(9, frame: CGRect(x: 200, y: 150, width: 120, height: 30))
        let capture = service([tooltip, window(targetID, frame: bounds)])
        XCTAssertTrue(capture.isOccluded(target, rect: bounds, overlayWindowID: nil),
            "A separate tooltip window really overlaps the target, even when owned by the same app")
        let region = CaptureTarget.region(displayID: 0, rect: bounds)
        XCTAssertFalse(capture.isOccluded(region, rect: bounds, overlayWindowID: nil),
            "Other apps are already included in a region capture")
        let ownPanel = service([window(99, frame: bounds, pid: ProcessInfo.processInfo.processIdentifier)])
        XCTAssertTrue(ownPanel.isOccluded(region, rect: bounds, overlayWindowID: nil))
    }

    @MainActor
    func testLinkStatusWindowOnlyMasksItsOverlapAndKeepsTheOverlayVisible() throws {
        let targetInfo = window(targetID, frame: bounds)
        let status = CGRect(x: bounds.minX - 1, y: bounds.maxY - 21, width: 230, height: 22)
        let capture = service([window(9, frame: status), targetInfo], browserPID: 1)
        XCTAssertNil(capture.overlayExclusions(for: target, rect: bounds, overlayWindowID: nil))
        XCTAssertNil(service([window(9, frame: status), targetInfo])
            .overlayExclusions(for: target, rect: bounds, overlayWindowID: nil, excludeBrowserLinkStatus: true))
        let exclusions = try XCTUnwrap(capture.overlayExclusions(for: target, rect: bounds, overlayWindowID: nil,
            excludeBrowserLinkStatus: true))
        XCTAssertEqual(exclusions, [status.intersection(bounds)])
        XCTAssertTrue(capture.isOccluded(target, rect: bounds, overlayWindowID: nil))
        XCTAssertNil(service([window(9, frame: status, pid: 2), targetInfo], browserPID: 1)
            .overlayExclusions(for: target, rect: bounds, overlayWindowID: nil, excludeBrowserLinkStatus: true))

        let controller = TranslationOverlayController()
        defer { controller.clear() }
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let presentation = OverlayPresentation(source: image, patches: [], coversSource: true)
        controller.show(rect: bounds, presentation: presentation, livePreview: false, topInset: 32, excluding: exclusions)
        let overlay = try XCTUnwrap(controller.window)
        let mask = try XCTUnwrap(overlay.contentView?.layer?.mask as? CAShapeLayer)
        XCTAssertTrue(overlay.isVisible)
        XCTAssertFalse(try XCTUnwrap(mask.path).contains(CGPoint(x: 10, y: 10)))
        XCTAssertTrue(try XCTUnwrap(mask.path).contains(CGPoint(x: 300, y: 10)))
        XCTAssertTrue(try XCTUnwrap(mask.path).contains(CGPoint(x: 10, y: 40)))
        XCTAssertFalse(try XCTUnwrap(mask.path).contains(CGPoint(x: 10, y: 280)))

        controller.show(rect: bounds, presentation: presentation, livePreview: false, topInset: 32)
        XCTAssertEqual(controller.window?.windowNumber, overlay.windowNumber)
        XCTAssertTrue(try XCTUnwrap(mask.path).contains(CGPoint(x: 10, y: 10)))
    }
}

import AppKit
import LineLensCore
import XCTest
@testable import LineLens

final class WindowCaptureModeTests: XCTestCase {
    private let targetID: CGWindowID = 42
    private let bounds = CGRect(x: 100, y: 100, width: 400, height: 300)
    private var target: CaptureTarget { .window(id: targetID, processID: 1, title: "Target", crop: nil) }

    private func window(_ id: CGWindowID, frame: CGRect, onScreen: Bool = true, pid: pid_t = 1) -> [String: Any] {
        [kCGWindowNumber as String: Int(id), kCGWindowOwnerPID as String: pid,
         kCGWindowBounds as String: frame.dictionaryRepresentation, kCGWindowIsOnscreen as String: onScreen,
         kCGWindowLayer as String: 0, kCGWindowAlpha as String: 1.0]
    }

    @MainActor
    private func service(_ windows: @escaping () -> [[String: Any]]) -> ScreenCaptureService {
        ScreenCaptureService(accessProbe: {}, windowInfoProvider: { options, id in
            if options.contains(.optionIncludingWindow) {
                return windows().filter { ($0[kCGWindowNumber as String] as? Int) == Int(id) }
            }
            return windows().filter { $0[kCGWindowIsOnscreen as String] as? Bool == true }
        }, displayFramesProvider: {
            [(id: CGDirectDisplayID(1), frame: CGRect(x: 0, y: 0, width: 1200, height: 900)),
             (id: CGDirectDisplayID(2), frame: CGRect(x: -1000, y: -200, width: 1000, height: 900))]
        })
    }

    @MainActor
    func testScreenRegionFollowsMoveResizeAndNormalizedWindowCrop() throws {
        var frame = bounds
        let capture = service { [self.window(self.targetID, frame: frame)] }
        let cropped = CaptureTarget.window(id: targetID, processID: 1, title: "Crop",
            crop: CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6))
        XCTAssertEqual(try capture.captureTarget(for: target, windowMode: .direct), target)
        XCTAssertEqual(try capture.captureTarget(for: target, windowMode: .screenRegion), .region(displayID: 1, rect: bounds))
        XCTAssertEqual(capture.visibleFrame(for: cropped, windowMode: .screenRegion),
                       CGRect(x: 200, y: 160, width: 200, height: 180))

        frame.origin = CGPoint(x: 400, y: 300)
        XCTAssertEqual(try capture.captureTarget(for: target, windowMode: .screenRegion), .region(displayID: 1, rect: frame),
                       "Moving without resizing must replace the old absolute display crop")
        frame.size = CGSize(width: 600, height: 500)
        XCTAssertEqual(capture.visibleFrame(for: cropped, windowMode: .screenRegion),
                       CGRect(x: 550, y: 400, width: 300, height: 300))
        XCTAssertEqual(capture.overlayTopInset(for: cropped, rect: try XCTUnwrap(capture.visibleFrame(for: cropped))), 0)
    }

    @MainActor
    func testCrossDisplayMovementChoosesLargestVisibleIntersectionAndClipsEdges() throws {
        var frame = CGRect(x: -300, y: -100, width: 400, height: 300)
        let capture = service { [self.window(self.targetID, frame: frame)] }
        XCTAssertEqual(try capture.captureTarget(for: target, windowMode: .screenRegion),
                       .region(displayID: 2, rect: CGRect(x: -300, y: -100, width: 300, height: 300)))
        frame = CGRect(x: -100, y: -100, width: 400, height: 300)
        let clipped = CGRect(x: 0, y: 0, width: 300, height: 200)
        XCTAssertEqual(try capture.captureTarget(for: target, windowMode: .screenRegion), .region(displayID: 1, rect: clipped))
        XCTAssertEqual(capture.visibleFrame(for: target, windowMode: .screenRegion), clipped)
        XCTAssertEqual(capture.overlayTopInset(for: target, rect: clipped), 0,
                       "A title bar above the display must not remove the first visible content row")
        frame = CGRect(x: 1500, y: 0, width: 400, height: 300)
        XCTAssertThrowsError(try capture.captureTarget(for: target, windowMode: .screenRegion))
        XCTAssertNil(capture.visibleFrame(for: target, windowMode: .screenRegion))
    }

    @MainActor
    func testMinimizedAndClosedWindowsCannotResolveToAnOldScreenRegion() throws {
        var windows = [window(targetID, frame: bounds)]
        let capture = service { windows }
        XCTAssertNotNil(capture.visibleFrame(for: target, windowMode: .screenRegion))
        windows = [window(targetID, frame: bounds, onScreen: false)]
        XCTAssertNil(capture.visibleFrame(for: target, windowMode: .screenRegion))
        XCTAssertNil(capture.overlayExclusions(for: target, rect: bounds, overlayWindowID: nil, windowMode: .screenRegion))
        windows = []
        XCTAssertThrowsError(try capture.captureTarget(for: target, windowMode: .screenRegion))
        windows = [window(targetID, frame: bounds)]
        XCTAssertNotNil(capture.visibleFrame(for: target, windowMode: .screenRegion))
    }

    @MainActor
    func testScreenRegionIncludesPopupsAndOverlappingAppsWithoutBrowserExceptions() {
        for pid: pid_t in [1, 2] {
            let capture = service { [self.window(9, frame: CGRect(x: 200, y: 200, width: 120, height: 50), pid: pid),
                                     self.window(self.targetID, frame: self.bounds)] }
            XCTAssertNil(capture.overlayExclusions(for: target, rect: bounds, overlayWindowID: nil))
            XCTAssertEqual(capture.overlayExclusions(for: target, rect: bounds, overlayWindowID: nil, windowMode: .screenRegion), [])
        }
        let capture = service { [self.window(99, frame: self.bounds, pid: ProcessInfo.processInfo.processIdentifier),
                                 self.window(self.targetID, frame: self.bounds)] }
        XCTAssertNil(capture.overlayExclusions(for: target, rect: bounds, overlayWindowID: nil, windowMode: .screenRegion))
        XCTAssertEqual(capture.overlayExclusions(for: target, rect: bounds, overlayWindowID: 99, windowMode: .screenRegion), [])
    }

    @MainActor
    func testFixedRegionSelectionDoesNotChangeWhenWindowModeChanges() throws {
        let capture = service { [] }
        let region = CaptureTarget.region(displayID: 1, rect: bounds)
        for mode in WindowCaptureMode.allCases {
            XCTAssertEqual(try capture.captureTarget(for: region, windowMode: mode), region)
        }
    }

    @MainActor
    func testResultPanelOnlyModeAlsoTracksWindowGeometryAndStopsWhenPaused() {
        let model = AppModel()
        let original = model.settings
        defer { model.stop(); model.settings = original }
        var settings = original
        settings.windowCaptureMode = .screenRegion
        settings.presentation = .panel
        settings.automaticRefresh = true
        settings.translationEnabled = false
        model.settings = settings
        model.target = target
        model.updateRecognitionMonitoring()
        XCTAssertTrue(model.usesWindowScreenRegion)
        XCTAssertTrue(model.isOverlayMonitoringActive, "Panel-only OCR must also follow movement before the slow OCR timer")
        model.togglePause()
        XCTAssertFalse(model.isOverlayMonitoringActive)
        XCTAssertFalse(model.isRefreshMonitoringActive)
        XCTAssertFalse(model.isInputMonitoringActive)
    }

    @MainActor
    func testMovingOrMinimizingDiscardsOldResultsAndRestoresTrackingWithoutReselection() {
        var frame = bounds
        var onScreen = true
        let capture = service { [self.window(self.targetID, frame: frame, onScreen: onScreen)] }
        let model = AppModel(capture: capture)
        let original = model.settings
        defer { model.stop(); model.settings = original }
        var settings = original
        settings.windowCaptureMode = .screenRegion
        settings.automaticRefresh = true
        settings.presentation = .panel
        model.settings = settings
        model.target = target
        model.updateOverlay()
        model.blocks = [TextBlock(source: "Old position", rect: .zero, confidence: 1)]
        frame.origin.x += 100
        model.updateOverlay()
        XCTAssertTrue(model.blocks.isEmpty)
        XCTAssertEqual(model.target, target)
        XCTAssertTrue(model.isCapturing)

        onScreen = false
        model.updateOverlay()
        XCTAssertFalse(model.isCapturing)
        XCTAssertTrue(model.isOverlayMonitoringActive, "Minimized windows must still be checked for restoration")
        onScreen = true
        model.updateOverlay()
        XCTAssertTrue(model.isCapturing)
        XCTAssertEqual(model.target, target)
        // This synchronous test cancels pending work before it reaches the system
        // capture API. Tests must not request screen-recording permission.
        model.stop()
        XCTAssertFalse(model.isOverlayMonitoringActive)
        XCTAssertFalse(model.isRefreshMonitoringActive)
    }
}

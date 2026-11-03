import AppKit
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
    private func service(_ windows: [[String: Any]]) -> ScreenCaptureService {
        ScreenCaptureService(accessProbe: {}, windowInfoProvider: { options, id in
            if options.contains(.optionIncludingWindow) {
                return windows.filter { ($0[kCGWindowNumber as String] as? Int) == Int(id) }
            }
            return windows.filter { $0[kCGWindowIsOnscreen as String] as? Bool == true }
        })
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
}

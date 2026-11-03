import XCTest
@testable import LineLensCore

final class CaptureGeometryTests: XCTestCase {
    func testMainScreenCoordinates() {
        let rect = CGRect(x: 100, y: 200, width: 300, height: 150)
        XCTAssertEqual(CaptureGeometry.flipScreenRect(rect, mainDisplayHeight: 900),
                       CGRect(x: 100, y: 550, width: 300, height: 150))
    }

    func testMonitorAboveMainDisplayAndNegativeOrigins() {
        let above = CGRect(x: -200, y: 1000, width: 300, height: 200)
        let converted = CaptureGeometry.flipScreenRect(above, mainDisplayHeight: 900)
        XCTAssertEqual(converted, CGRect(x: -200, y: -300, width: 300, height: 200))
        XCTAssertEqual(CaptureGeometry.flipScreenRect(converted, mainDisplayHeight: 900), above)
    }

    func testWindowCropFollowsMovementAndResize() {
        let original = CGRect(x: 100, y: 100, width: 800, height: 600)
        let selection = CGRect(x: 300, y: 400, width: 400, height: 150)
        let crop = CaptureGeometry.normalizedCrop(selection, in: original)!
        XCTAssertEqual(crop, CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25))
        XCTAssertEqual(CaptureGeometry.resolve(crop, in: CGRect(x: -100, y: 50, width: 1600, height: 1200)),
                       CGRect(x: 300, y: 650, width: 800, height: 300))
    }

    func testCropClipsAtWindowEdge() {
        XCTAssertEqual(CaptureGeometry.normalizedCrop(CGRect(x: 80, y: 80, width: 50, height: 50),
                                                     in: CGRect(x: 100, y: 100, width: 100, height: 100)),
                       CGRect(x: 0, y: 0, width: 0.3, height: 0.3))
    }

    func testInvalidCropsAreRejected() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNil(CaptureGeometry.normalizedCrop(CGRect(x: 110, y: 0, width: 10, height: 10), in: bounds))
        XCTAssertNil(CaptureGeometry.normalizedCrop(CGRect(x: 0, y: 0, width: 3, height: 10), in: bounds))
        XCTAssertNil(CaptureGeometry.normalizedCrop(bounds, in: .zero))
    }

    func testTextOverlayCoordinates() {
        XCTAssertEqual(CaptureGeometry.appKitRect(CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.1),
                                                  in: CGRect(x: 100, y: 100, width: 1000, height: 500)),
                       CGRect(x: 200, y: 450, width: 500, height: 50))
    }
}

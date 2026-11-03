import XCTest
@testable import LineLensCore

final class OverlayFrameStateTests: XCTestCase {
    func testChangedFrameHidesRecognizedSnapshotAndRejectsLateOCR() {
        var state = OverlayFrameState()
        XCTAssertFalse(state.canPresent)
        state.observe(100)
        XCTAssertTrue(state.acceptRecognition(100))
        XCTAssertTrue(state.canPresent)
        XCTAssertFalse(state.observe(100))
        XCTAssertTrue(state.canPresent)
        state.observe(200)
        XCTAssertFalse(state.canPresent)
        XCTAssertFalse(state.acceptRecognition(100))
        XCTAssertTrue(state.acceptRecognition(200))
        XCTAssertTrue(state.canPresent)
    }

    func testReturningToEarlierPixelsStillInvalidatesOldRenderRevision() {
        var state = OverlayFrameState()
        state.observe(100)
        let revision = state.revision
        state.observe(200)
        state.observe(100)
        XCTAssertNotEqual(state.revision, revision)
        XCTAssertFalse(state.canPresent)
    }
}

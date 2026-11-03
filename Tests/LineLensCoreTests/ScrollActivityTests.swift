import XCTest
@testable import LineLensCore

final class ScrollActivityTests: XCTestCase {
    func testWheelBurstsSettleOnlyAfterTheLastInput() {
        var state = ScrollActivityState()
        XCTAssertTrue(state.note(.wheel, at: 10))
        XCTAssertFalse(state.note(.wheel, at: 10.2))
        XCTAssertFalse(state.settle(at: 10.3))
        XCTAssertTrue(state.settle(at: 10.45))
        XCTAssertFalse(state.isScrolling)
        XCTAssertNil(state.deadline)
    }

    func testFingerUpDoesNotRefreshBeforeMomentumAndDirectionChangesFinish() {
        var state = ScrollActivityState()
        state.note(.gesture, at: 1)
        state.note(.gestureEnded, at: 1.1)
        XCTAssertFalse(state.settle(at: 1.15))
        XCTAssertFalse(state.note(.momentum, at: 1.16), "Momentum belongs to the same hidden interval")
        state.note(.momentum, at: 1.8)
        XCTAssertFalse(state.settle(at: 2))
        state.note(.momentumEnded, at: 2.1)
        XCTAssertFalse(state.settle(at: 2.2))
        XCTAssertTrue(state.settle(at: 2.35))
    }

    func testVisualTailDelaysRefreshButVideoCannotHoldItForever() {
        var state = ScrollActivityState()
        state.note(.wheel, at: 1)
        state.observeMotion(at: 1.2)
        XCTAssertFalse(state.settle(at: 1.3))
        XCTAssertTrue(state.settle(at: 1.43))

        state.note(.momentumEnded, at: 2)
        for moment in stride(from: 2.1, through: 3.2, by: 0.1) { state.observeMotion(at: moment) }
        XCTAssertTrue(state.settle(at: 3.21), "Unrelated animation must not keep translations hidden indefinitely")
    }

    func testNewScrollAfterASettledScreenStartsAFreshInterval() {
        var state = ScrollActivityState()
        state.note(.wheel, at: 1)
        XCTAssertTrue(state.settle(at: 2))
        XCTAssertTrue(state.note(.gesture, at: 10))
        XCTAssertFalse(state.settle(at: 10.1))
        state = ScrollActivityState()
        XCTAssertFalse(state.settle(at: 11), "Reset must not refresh a previous target")
    }
}

import ScreenCaptureKit
import XCTest
@testable import LineLens

final class ScreenAccessTests: XCTestCase {
    @MainActor
    func testAccessIsVerifiedByTheActualProbe() async {
        var calls = 0
        let service = ScreenCaptureService(accessProbe: { calls += 1 })
        XCTAssertFalse(service.hasPermission)
        let allowed = await service.verifyAccess()
        XCTAssertTrue(allowed)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(service.accessState, .allowed)
    }

    @MainActor
    func testPermissionDenialIsDistinguishedFromOtherFailures() async {
        let denied = ScreenCaptureService(accessProbe: {
            throw NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        })
        let deniedResult = await denied.verifyAccess()
        XCTAssertFalse(deniedResult)
        XCTAssertEqual(denied.accessState, .needsApproval)

        let failed = ScreenCaptureService(accessProbe: {
            throw NSError(domain: "LineLensTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Capture service unavailable"])
        })
        let failedResult = await failed.verifyAccess()
        XCTAssertFalse(failedResult)
        XCTAssertEqual(failed.accessState, .failed("Capture service unavailable"))
    }

    @MainActor
    func testRecheckRecoversAfterPermissionIsGranted() async {
        var isAllowed = false
        let service = ScreenCaptureService(accessProbe: {
            if !isAllowed {
                throw NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
            }
        })
        let before = await service.verifyAccess()
        XCTAssertFalse(before)
        isAllowed = true
        let after = await service.verifyAccess()
        XCTAssertTrue(after)
        XCTAssertTrue(service.hasPermission)
    }

    @MainActor
    func testResetClearsOldApprovalAndRequiresNewAuthorization() async {
        var resetCalls = 0
        var probeCalls = 0
        let service = ScreenCaptureService(accessProbe: { probeCalls += 1 }, accessReset: { resetCalls += 1 })
        _ = await service.verifyAccess()
        XCTAssertTrue(service.hasPermission)
        let reset = await service.resetAccess()
        XCTAssertTrue(reset)
        XCTAssertEqual(resetCalls, 1)
        XCTAssertEqual(service.accessState, .unchecked)
        XCTAssertFalse(service.hasPermission)
        XCTAssertNotNil(service.recoveryMessage)
        XCTAssertTrue(service.requiresRelaunch)
        let recheck = await service.verifyAccess()
        XCTAssertFalse(recheck)
        XCTAssertEqual(probeCalls, 1, "Do not recreate a stale denial before the process restarts")
    }

    @MainActor
    func testFailedResetPreservesExistingAccessState() async {
        let service = ScreenCaptureService(accessProbe: {}, accessReset: {
            throw NSError(domain: "LineLensTests", code: 1)
        })
        _ = await service.verifyAccess()
        let reset = await service.resetAccess()
        XCTAssertFalse(reset)
        XCTAssertTrue(service.hasPermission)
        XCTAssertNotNil(service.recoveryMessage)
    }
}

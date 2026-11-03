import ServiceManagement
import XCTest
@testable import LineLens

final class LaunchAtLoginTests: XCTestCase {
    @MainActor
    func testEnableAndDisableFollowSystemStatusWithoutDuplicateRegistration() async {
        var status: SMAppService.Status = .notFound
        var registrations = 0
        let service = LaunchAtLoginService(readStatus: { status }, register: {
            registrations += 1
            status = .enabled
        }, unregister: { status = .notRegistered })
        XCTAssertFalse(service.isOn)
        await service.setEnabled(true)
        XCTAssertTrue(service.isEnabled)
        await service.setEnabled(true)
        XCTAssertEqual(registrations, 1)
        await service.setEnabled(false)
        XCTAssertFalse(service.isOn)
        XCTAssertFalse(service.isUpdating)
    }

    @MainActor
    func testPendingApprovalCanBeTurnedOffAndExternalChangesAreReflected() async {
        var status: SMAppService.Status = .requiresApproval
        let service = LaunchAtLoginService(readStatus: { status }, register: { status = .enabled },
            unregister: { status = .notRegistered })
        XCTAssertTrue(service.isOn)
        XCTAssertFalse(service.isEnabled)
        await service.setEnabled(false)
        XCTAssertFalse(service.isOn)
        status = .enabled
        service.refresh()
        XCTAssertTrue(service.isEnabled)
        status = .notRegistered
        service.refresh()
        XCTAssertFalse(service.isOn)
    }

    @MainActor
    func testRegistrationFailureDoesNotLeaveACheckedToggle() async {
        let service = LaunchAtLoginService(readStatus: { .notRegistered }, register: {
            throw NSError(domain: "LineLensTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Registration denied"])
        }, unregister: {})
        await service.setEnabled(true)
        XCTAssertFalse(service.isOn)
        XCTAssertEqual(service.errorMessage, "Registration denied")
        XCTAssertFalse(service.isUpdating)
    }
}

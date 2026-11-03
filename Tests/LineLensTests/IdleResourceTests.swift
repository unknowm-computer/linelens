import XCTest
@testable import LineLens

final class IdleResourceTests: XCTestCase {
    @MainActor
    func testIdleWindowsAreLazyAndHiddenResultsCanBeReleased() {
        let model = AppModel()
        let windows = AppWindows(model: model)
        XCTAssertFalse(windows.hasResultsHost)
        XCTAssertFalse(windows.hasSettingsHost)
        XCTAssertFalse(windows.hasWelcomeHost)
        windows.prepareForRecognition()
        XCTAssertTrue(windows.hasResultsHost)
        windows.releaseIdleResources()
        XCTAssertFalse(windows.hasResultsHost)
        windows.prepareForRecognition()
        XCTAssertTrue(windows.hasResultsHost, "The results host must be reusable after being released")
        windows.releaseIdleResources()
    }

    @MainActor
    func testHiddenHostRemainsAvailableForActiveOverlayTranslation() {
        let model = AppModel()
        let windows = AppWindows(model: model)
        model.target = .region(displayID: 0, rect: CGRect(x: 0, y: 0, width: 200, height: 100))
        windows.prepareForRecognition()
        windows.releaseIdleResources()
        XCTAssertTrue(windows.hasResultsHost)
        model.target = nil
        windows.releaseIdleResources()
        XCTAssertFalse(windows.hasResultsHost)
    }

    @MainActor
    func testManualOnlyUpdaterDoesNotInitializeUntilRequested() {
        var initializations = 0
        let updater = AppUpdater(isBundledApp: true, automaticChecks: { false }, makeController: {
            initializations += 1
            throw TestError.unavailable
        })
        updater.start()
        updater.start()
        XCTAssertEqual(initializations, 0)
        XCTAssertFalse(updater.isInitialized)
        XCTAssertTrue(updater.canCheckForUpdates)
        updater.checkForUpdates()
        XCTAssertEqual(initializations, 1)
        XCTAssertNotNil(updater.startupError)
    }

    @MainActor
    func testAutomaticUpdatePreferenceStillStartsUpdater() {
        var initializations = 0
        let updater = AppUpdater(isBundledApp: true, automaticChecks: { true }, makeController: {
            initializations += 1
            throw TestError.unavailable
        })
        updater.start()
        XCTAssertEqual(initializations, 1)
        XCTAssertTrue(updater.checksAutomatically)
        XCTAssertNotNil(updater.startupError)
    }

    private enum TestError: Error { case unavailable }
}

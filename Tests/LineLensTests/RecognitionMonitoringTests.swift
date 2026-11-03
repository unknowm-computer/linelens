import XCTest
@testable import LineLens

final class RecognitionMonitoringTests: XCTestCase {
    @MainActor
    func testStopRemovesBothTimersAndNoCallbacksArriveAfterward() async throws {
        let monitoring = RecognitionMonitoringController()
        defer { monitoring.stop() }
        var refreshes = 0, overlays = 0
        monitoring.onRefresh = { refreshes += 1 }
        monitoring.onOverlayUpdate = { overlays += 1 }
        XCTAssertFalse(monitoring.isRefreshing)
        XCTAssertFalse(monitoring.isTrackingOverlay)
        monitoring.configure(refreshInterval: 0.02, overlayInterval: 0.01)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(refreshes, 0)
        XCTAssertGreaterThan(overlays, 0)
        monitoring.stop()
        let refreshesAtStop = refreshes, overlaysAtStop = overlays
        XCTAssertFalse(monitoring.isRefreshing)
        XCTAssertFalse(monitoring.isTrackingOverlay)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(refreshes, refreshesAtStop)
        XCTAssertEqual(overlays, overlaysAtStop)
    }

    @MainActor
    func testRepeatedConfigurationDoesNotDuplicateWorkAndModesCanRestartSeparately() async throws {
        let monitoring = RecognitionMonitoringController()
        defer { monitoring.stop() }
        var refreshes = 0, overlays = 0
        monitoring.onRefresh = { refreshes += 1 }
        monitoring.onOverlayUpdate = { overlays += 1 }
        for _ in 0..<20 { monitoring.configure(refreshInterval: 0.03, overlayInterval: nil) }
        try await Task.sleep(for: .milliseconds(130))
        XCTAssertGreaterThan(refreshes, 0)
        XCTAssertLessThan(refreshes, 10, "Repeated reconciliation must not accumulate polling tasks")
        XCTAssertEqual(overlays, 0)
        monitoring.configure(refreshInterval: nil, overlayInterval: 0.02)
        let previousRefreshes = refreshes
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(refreshes, previousRefreshes)
        XCTAssertGreaterThan(overlays, 0)
        monitoring.configure(refreshInterval: -1, overlayInterval: 0)
        XCTAssertFalse(monitoring.isRefreshing)
        XCTAssertFalse(monitoring.isTrackingOverlay)
        let previousOverlays = overlays
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(overlays, previousOverlays, "Invalid intervals must not create a busy loop")
    }

    @MainActor
    func testModelStopsMonitoringWhenIdlePausedOrSelectingAndRestartsOnlyNeededWork() {
        let model = AppModel()
        let original = model.settings
        defer { model.stop(); model.settings = original }
        var settings = original
        settings.automaticRefresh = true
        settings.translationEnabled = true
        settings.presentation = .overlay
        model.settings = settings
        assertInactive(model)
        // Exercise activity policy without invoking capture or requesting any
        // system permission from the test process.
        model.target = .region(displayID: 0, rect: CGRect(x: 0, y: 0, width: 500, height: 300))
        model.updateRecognitionMonitoring()
        XCTAssertTrue(model.isRefreshMonitoringActive)
        XCTAssertTrue(model.isOverlayMonitoringActive)
        XCTAssertTrue(model.isInputMonitoringActive)

        model.togglePause()
        XCTAssertTrue(model.hasTarget)
        assertInactive(model)
        model.isPaused = false
        model.updateRecognitionMonitoring()
        XCTAssertTrue(model.isRefreshMonitoringActive)
        model.isSelecting = true
        model.updateRecognitionMonitoring()
        assertInactive(model)
        model.isSelecting = false
        model.updateRecognitionMonitoring()
        XCTAssertTrue(model.isInputMonitoringActive)

        model.isPaused = true
        settings.automaticRefresh = false
        model.settings = settings
        assertInactive(model)
        model.isPaused = false
        model.updateRecognitionMonitoring()
        XCTAssertFalse(model.isRefreshMonitoringActive)
        XCTAssertFalse(model.isInputMonitoringActive)
        XCTAssertTrue(model.isOverlayMonitoringActive, "A manual overlay still needs window position/visibility checks")
        settings.translationEnabled = false
        model.settings = settings
        assertInactive(model)

        model.stop()
        XCTAssertFalse(model.hasTarget)
        assertInactive(model)
        model.settings = original
        assertInactive(model)
    }

    @MainActor
    private func assertInactive(_ model: AppModel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(model.isRefreshMonitoringActive, file: file, line: line)
        XCTAssertFalse(model.isOverlayMonitoringActive, file: file, line: line)
        XCTAssertFalse(model.isInputMonitoringActive, file: file, line: line)
    }
}

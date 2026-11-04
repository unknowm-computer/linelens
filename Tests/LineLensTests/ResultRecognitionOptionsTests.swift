import XCTest
import LineLensCore
@testable import LineLens

final class ResultRecognitionOptionsTests: XCTestCase {
    @MainActor
    private func model() -> AppModel {
        let model = AppModel()
        model.settings = AppSettings()
        model.ocrLanguages = ["en-US", "ja-JP", "ko-KR"]
        model.translation.supportedLanguages = ["en", "ja", "ko"]
        return model
    }

    @MainActor
    func testResultChoicesDoNotWriteDefaultsOrLeakIntoAnotherSession() {
        let original = AppSettings.load()
        defer { original.save() }
        let model = model()
        defer { model.stop() }
        let defaults = model.settings
        let saved = UserDefaults.standard.data(forKey: "settings")
        model.setResultRecognitionSource(.ocr)
        model.setRecognitionLanguage("ja")
        model.setResultTargetLanguage("en")
        XCTAssertEqual(model.recognitionSettings.recognitionSource, .ocr)
        XCTAssertEqual(model.recognitionSettings.ocrLanguage, "ja-JP")
        XCTAssertEqual(model.recognitionSettings.sourceLanguage, "ja")
        XCTAssertEqual(model.recognitionSettings.targetLanguage, "en")
        XCTAssertEqual(model.settings, defaults)
        XCTAssertEqual(AppSettings.load(), defaults)
        XCTAssertEqual(UserDefaults.standard.data(forKey: "settings"), saved)
        XCTAssertEqual(AppModel().recognitionSettings, defaults)
        XCTAssertFalse(model.isRefreshMonitoringActive)
        XCTAssertFalse(model.isInputMonitoringActive)
    }

    @MainActor
    func testResetFollowsLatestDefaultsAndLanguageResetKeepsSourceChoice() {
        let original = AppSettings.load()
        defer { original.save() }
        let model = model()
        defer { model.stop() }
        model.setResultRecognitionSource(.automatic)
        model.setRecognitionLanguage("ja")
        model.setResultTargetLanguage("en")
        var defaults = model.settings
        defaults.recognitionSource = .ocr
        defaults.ocrLanguage = "ko-KR"
        defaults.sourceLanguage = "ko"
        defaults.targetLanguage = "ja"
        model.settings = defaults
        XCTAssertEqual(model.recognitionSettings.recognitionSource, .automatic, "An explicit choice remains local even if the default changes")
        XCTAssertEqual(model.recognitionSettings.sourceLanguage, "ja")
        XCTAssertEqual(model.recognitionSettings.targetLanguage, "en")
        model.resetResultLanguages()
        XCTAssertFalse(model.resultOptions.hasLanguageOverrides)
        XCTAssertEqual(model.recognitionSettings.ocrLanguage, "ko-KR")
        XCTAssertEqual(model.recognitionSettings.sourceLanguage, "ko")
        XCTAssertEqual(model.recognitionSettings.targetLanguage, "ja")
        XCTAssertEqual(model.recognitionSettings.recognitionSource, .automatic)
        model.setResultRecognitionSource(nil)
        XCTAssertEqual(model.recognitionSettings, defaults)
        XCTAssertEqual(AppSettings.load(), defaults)
    }

    @MainActor
    func testInheritedChoicesFollowDefaultsAndStopClearsEveryOverride() {
        let original = AppSettings.load()
        defer { original.save() }
        let model = model()
        model.settings.recognitionSource = .ocr
        XCTAssertEqual(model.recognitionSettings.recognitionSource, .ocr)
        model.setResultRecognitionSource(.automatic)
        model.setRecognitionLanguage("en")
        model.setResultTargetLanguage("ja")
        let saved = UserDefaults.standard.data(forKey: "settings")
        model.stop()
        XCTAssertEqual(model.resultOptions, ResultRecognitionOptions())
        XCTAssertEqual(model.recognitionSettings, model.settings)
        XCTAssertEqual(UserDefaults.standard.data(forKey: "settings"), saved)
    }

    @MainActor
    func testTemporaryChangesPreservePauseAndSelectionWithoutStartingCapture() {
        let original = AppSettings.load()
        defer { original.save() }
        let model = model()
        defer { model.stop() }
        model.target = .window(id: 0, processID: 0, title: "Unavailable test window", crop: nil)
        model.isPaused = true
        model.setResultRecognitionSource(.ocr)
        model.setRecognitionLanguage("ja")
        XCTAssertTrue(model.isPaused)
        XCTAssertTrue(model.hasTarget)
        XCTAssertFalse(model.isRefreshMonitoringActive)
        XCTAssertFalse(model.isOverlayMonitoringActive)
        model.isPaused = false
        model.isSelecting = true
        model.setResultRecognitionSource(.automatic)
        model.setRecognitionLanguage("en")
        XCTAssertTrue(model.isSelecting)
        XCTAssertTrue(model.hasTarget)
        XCTAssertFalse(model.isRefreshMonitoringActive)
        XCTAssertFalse(model.isInputMonitoringActive)
        XCTAssertEqual(model.settings, AppSettings())
    }

    @MainActor
    func testTranslationJobUsesTemporaryLanguagesAndResetReturnsToDefaults() {
        let original = AppSettings.load()
        defer { original.save() }
        let model = model()
        defer { model.stop() }
        model.setRecognitionLanguage("en")
        model.setResultTargetLanguage("ja")
        model.target = .window(id: 0, processID: 0, title: "Unavailable test window", crop: nil)
        model.blocks = [TextBlock(source: "Open application settings", rect: .zero, confidence: 1)]
        model.translateCurrentBlocks()
        XCTAssertEqual(model.translation.configuration?.source?.languageCode?.identifier, "en")
        XCTAssertEqual(model.translation.configuration?.target?.languageCode?.identifier, "ja")
        XCTAssertEqual(model.settings.targetLanguage, "ko")
        model.resetResultLanguages()
        XCTAssertNil(model.translation.configuration, "Resetting OCR language must wait for fresh recognition")
        model.translateCurrentBlocks()
        XCTAssertEqual(model.translation.configuration?.target?.languageCode?.identifier, "ko")
        XCTAssertEqual(model.settings.sourceLanguage, "auto")
    }
}

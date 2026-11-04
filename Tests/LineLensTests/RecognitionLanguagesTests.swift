import XCTest
import LineLensCore
@testable import LineLens

final class RecognitionLanguagesTests: XCTestCase {
    func testCommonLanguagesMapToVisionIdentifiersAndPreserveChineseScripts() {
        let options = RecognitionLanguages.options(ocrLanguages: ["en-US", "ja-JP", "ko-KR", "zh-Hans", "zh-Hant"],
            translationLanguages: ["en", "ja", "ko", "zh", "zh-TW"])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: options.map { ($0.id, $0.ocrLanguage) }),
            ["en": "en-US", "ja": "ja-JP", "ko": "ko-KR", "zh": "zh-Hans", "zh-TW": "zh-Hant"])
    }

    func testRegionalTranslationVariantsUseCompatibleOCRLanguages() {
        let options = RecognitionLanguages.options(ocrLanguages: ["ar-SA", "en-US", "vi-VT"],
            translationLanguages: ["ar-AE", "en-GB", "vi", "unsupported"])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: options.map { ($0.id, $0.ocrLanguage) }),
            ["ar-AE": "ar-SA", "en-GB": "en-US", "vi": "vi-VT"])
    }

    func testUnsupportedScriptIsNotSilentlyReplacedWithAnotherScript() {
        XCTAssertTrue(RecognitionLanguages.options(ocrLanguages: ["zh-Hans"], translationLanguages: ["zh-TW"]).isEmpty)
    }

    @MainActor
    func testUnifiedSelectionUpdatesSessionLanguagesAndWaitsForFreshRecognition() {
        let original = AppSettings.load()
        defer { original.save() }
        let model = AppModel()
        model.settings = AppSettings()
        model.ocrLanguages = ["en-US", "ja-JP"]
        model.translation.supportedLanguages = ["en", "ja", "ko"]
        // A nonexistent window keeps this test from starting a real capture.
        model.target = .window(id: 0, processID: 0, title: "Unavailable test window", crop: nil)
        var block = TextBlock(source: "Old English text", rect: .zero, confidence: 1)
        block.translation = "이전 번역"
        model.blocks = [block]
        model.setRecognitionLanguage("ja")
        XCTAssertEqual(model.recognitionSettings.ocrLanguage, "ja-JP")
        XCTAssertEqual(model.recognitionSettings.sourceLanguage, "ja")
        XCTAssertEqual(model.settings, AppSettings(), "Result choices must not alter persisted defaults")
        XCTAssertEqual(model.settings.targetLanguage, "ko")
        XCTAssertEqual(model.recognitionLanguage, "ja")
        XCTAssertNil(model.blocks[0].translation)
        XCTAssertFalse(model.translation.isWorking, "Do not translate old OCR text under the new source language")
        model.setRecognitionLanguage("auto")
        XCTAssertEqual(model.recognitionSettings.ocrLanguage, "auto")
        XCTAssertEqual(model.recognitionSettings.sourceLanguage, "auto")
        XCTAssertEqual(model.recognitionLanguage, "auto")
    }

    @MainActor
    func testOpeningUnifiedSelectionPreservesIndividuallyConfiguredLanguages() {
        let original = AppSettings.load()
        defer { original.save() }
        let model = AppModel()
        model.ocrLanguages = ["en-US", "ja-JP"]
        model.translation.supportedLanguages = ["en", "ja"]
        var settings = AppSettings()
        settings.ocrLanguage = "en-US"
        settings.sourceLanguage = "ja"
        model.settings = settings
        XCTAssertEqual(model.recognitionLanguage, RecognitionLanguages.customSelection)
        XCTAssertEqual(model.settings, settings)
        model.setRecognitionLanguage("unknown")
        XCTAssertEqual(model.settings, settings)
        model.setRecognitionLanguage("en")
        XCTAssertEqual(model.recognitionSettings.ocrLanguage, "en-US")
        XCTAssertEqual(model.recognitionSettings.sourceLanguage, "en")
        XCTAssertEqual(model.settings, settings)
    }
}

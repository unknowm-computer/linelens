import XCTest
import LineLensCore
@preconcurrency import Translation
@testable import LineLens

final class TranslationLanguageTests: XCTestCase {
    @MainActor
    func testTextCacheSurvivesScrollCancellationAndUsesNewBlockIdentifiers() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Direct installed sessions require macOS 26") }
        let source = Locale.Language(identifier: "en"), target = Locale.Language(identifier: "ko")
        guard await LanguageAvailability().status(from: source, to: target) == .installed else { throw XCTSkip("Models not installed") }
        let engine = TranslationEngine()
        var settings = AppSettings()
        settings.sourceLanguage = "en"
        let before = TextBlock(source: "Open application settings", rect: CGRect(x: 0, y: 0.2, width: 0.4, height: 0.1), confidence: 1)
        var old: [UUID: String] = [:]
        engine.submit(blocks: [before], settings: settings) { old = $0 }
        await engine.run(using: TranslationSession(installedSource: source, target: target))
        XCTAssertNotNil(old[before.id])
        engine.cancel()
        let after = TextBlock(source: before.source, rect: CGRect(x: 0.5, y: 0.7, width: 0.3, height: 0.1), confidence: 1)
        var fresh: [UUID: String] = [:]
        engine.submit(blocks: [after], settings: settings) { fresh = $0 }
        XCTAssertEqual(fresh[after.id], old[before.id])
        XCTAssertNil(fresh[before.id])
        XCTAssertNil(engine.configuration, "An exact text cache hit must not wait for another TranslationSession")
        XCTAssertFalse(engine.isWorking)
        settings.translationQuality = .quality
        engine.submit(blocks: [after], settings: settings) { _ in XCTFail("A different quality must not reuse the speed cache") }
        XCTAssertTrue(engine.isWorking)
        engine.cancel()
    }

    @MainActor
    func testAutomaticSourceUsesFullScreenContextForChangingShortLabels() {
        let context = "Application Settings. Prevent the computer from sleeping while the app is running. Page 124."
        XCTAssertEqual(TranslationEngine.resolvedSourceLanguage("auto", context: context), "en")
    }

    @MainActor
    func testExplicitLanguageIsPreservedAndEmptyContextUsesSystemDetection() {
        XCTAssertEqual(TranslationEngine.resolvedSourceLanguage("ko", context: "English text"), "ko")
        XCTAssertEqual(TranslationEngine.resolvedSourceLanguage("auto", context: ""), "auto")
    }
    @MainActor
    func testInstalledLocalTranslationHandlesSuccessiveShortLabelChanges() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Direct installed sessions require macOS 26") }
        let source = Locale.Language(identifier: "en")
        let target = Locale.Language(identifier: "ko")
        let availability = LanguageAvailability()
        guard await availability.status(from: source, to: target) == .installed else {
            throw XCTSkip("No English/Korean model installed; this test never downloads models")
        }
        let engine = TranslationEngine()
        let session = TranslationSession(installedSource: source, target: target)
        for number in [124, 125] {
            let block = TextBlock(source: "Page \(number)", rect: .zero, confidence: 1)
            var results: [UUID: String] = [:]
            engine.submit(blocks: [block], settings: AppSettings(),
                sourceContext: "Application settings. Prevent the computer from sleeping while the app is running. Page \(number).") {
                results = $0
            }
            await engine.run(using: session)
            XCTAssertNil(engine.message)
            XCTAssertTrue(results[block.id]?.contains(String(number)) == true, results.description)
        }
    }

    @MainActor
    func testInstalledBatchPublishesLabelsBeforeTheWholeBatchCompletes() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Direct installed sessions require macOS 26") }
        let source = Locale.Language(identifier: "en")
        let target = Locale.Language(identifier: "ko")
        let availability = LanguageAvailability()
        guard await availability.status(from: source, to: target) == .installed else { throw XCTSkip("Models not installed") }
        let engine = TranslationEngine()
        let blocks = ["Open application settings", "Change the window size", "Keep the computer awake"].map {
            TextBlock(source: $0, rect: .zero, confidence: 1)
        }
        var publications: [Int] = []
        engine.submit(blocks: blocks, settings: AppSettings()) { publications.append($0.count) }
        await engine.run(using: TranslationSession(installedSource: source, target: target))
        XCTAssertNil(engine.message)
        XCTAssertEqual(publications.first, 1, "Do not withhold early labels behind the complete batch")
        XCTAssertEqual(publications.last, 3)
    }

    @MainActor
    func testNewOCRResultsDoNotCancelAnActiveTranslationBatch() {
        let model = AppModel()
        model.target = .region(displayID: 0, rect: CGRect(x: 0, y: 0, width: 500, height: 300))
        let first = TextBlock(source: "Open application settings", rect: .zero, confidence: 1)
        let next = TextBlock(source: "Change the window size", rect: .zero, confidence: 1)
        model.translation.submit(blocks: [first], settings: model.settings) { _ in }
        let configuration = model.translation.configuration
        model.blocks = [first, next]
        model.translateCurrentBlocks(clearExisting: false)
        XCTAssertTrue(model.translation.isWorking)
        XCTAssertEqual(model.translation.configuration, configuration, "Recognition must queue new labels without restarting the current batch")
        model.translation.cancel()
    }

    @MainActor
    func testTargetLanguageAndNumbersCompleteWithoutTranslationSession() {
        let engine = TranslationEngine()
        let blocks = ["30년만에 개편", "약속을 반드시 지키는군요", "123"].map {
            TextBlock(source: $0, rect: .zero, confidence: 1)
        }
        var results: [UUID: String] = [:]
        engine.submit(blocks: blocks, settings: AppSettings()) { results = $0 }
        XCTAssertFalse(engine.isWorking)
        XCTAssertNil(engine.configuration)
        XCTAssertNil(engine.message)
        XCTAssertEqual(results.count, blocks.count)
        for block in blocks { XCTAssertEqual(results[block.id], block.source) }
    }

    @MainActor
    func testMixedKoreanAndEnglishUsesEnglishSessionAndPreservesKorean() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Direct installed sessions require macOS 26") }
        let source = Locale.Language(identifier: "en")
        let target = Locale.Language(identifier: "ko")
        let availability = LanguageAvailability()
        guard await availability.status(from: source, to: target) == .installed else { throw XCTSkip("Models not installed") }
        let engine = TranslationEngine()
        let korean = TextBlock(source: "설정 화면을 확인해 주세요", rect: .zero, confidence: 1)
        let english = TextBlock(source: "Open application settings", rect: .zero, confidence: 1)
        var results: [UUID: String] = [:]
        engine.submit(blocks: [korean, english], settings: AppSettings(), sourceContext: korean.source) { results = $0 }
        XCTAssertEqual(engine.configuration?.source?.languageCode?.identifier, "en")
        await engine.run(using: TranslationSession(installedSource: source, target: target))
        XCTAssertNil(engine.message)
        XCTAssertEqual(results[korean.id], korean.source)
        XCTAssertNotNil(results[english.id])
    }

}

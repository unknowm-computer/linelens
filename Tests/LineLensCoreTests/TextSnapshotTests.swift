import XCTest
@testable import LineLensCore

final class TextSnapshotTests: XCTestCase {
    private let size = CGSize(width: 2000, height: 1000)

    private func block(_ text: String, y: CGFloat = 0.1) -> TextBlock {
        TextBlock(source: text, rect: CGRect(x: 0.1, y: y, width: 0.5, height: 0.05), confidence: 0.95)
    }

    func testSameTextKeepsIdentityAndTranslationDespiteNewOCRIds() {
        var previous = block("Hello")
        previous.translation = "안녕하세요"
        var incoming = block("Hello")
        incoming.rect = incoming.rect.offsetBy(dx: 0.0005, dy: 0.001)
        incoming.confidence = 0.8
        let result = TextSnapshot.reconcile([incoming], previous: [previous], pixelSize: size)
        XCTAssertEqual(result, [previous], "OCR jitter must not replace the row or erase the translation")
    }

    func testSingleDigitChangeUpdatesOnlyChangedParagraph() {
        var first = block("Page 123")
        first.translation = "123페이지"
        var second = block("Hello", y: 0.3)
        second.translation = "안녕하세요"
        let changed = block("Page 124")
        let result = TextSnapshot.reconcile([changed, block("Hello", y: 0.3)], previous: [first, second], pixelSize: size)
        XCTAssertEqual(result[0].source, "Page 124")
        XCTAssertNotEqual(result[0].id, first.id)
        XCTAssertNil(result[0].translation)
        XCTAssertEqual(result[1], second)
    }

    func testRealMovementPreservesTranslationAndUpdatesPosition() {
        var previous = block("Hello")
        previous.translation = "안녕하세요"
        let moved = block("Hello", y: 0.4)
        let result = TextSnapshot.reconcile([moved], previous: [previous], pixelSize: size)
        XCTAssertEqual(result[0].id, previous.id)
        XCTAssertEqual(result[0].translation, previous.translation)
        XCTAssertEqual(result[0].rect, moved.rect)
    }

    func testDuplicateTextMatchesNearestExistingBlock() {
        let top = block("OK")
        let bottom = block("OK", y: 0.7)
        let result = TextSnapshot.reconcile([block("OK", y: 0.7), block("OK")], previous: [top, bottom], pixelSize: size)
        XCTAssertEqual(result.map(\.id), [bottom.id, top.id])
    }

    func testRemovedTextDisappears() {
        let previous = [block("Hello"), block("World", y: 0.3)]
        XCTAssertEqual(TextSnapshot.reconcile([block("World", y: 0.3)], previous: previous, pixelSize: size), [previous[1]])
        XCTAssertTrue(TextSnapshot.reconcile([], previous: previous, pixelSize: size).isEmpty)
    }
    func testNewLineBoxesReplaceOldWrappingWhilePreservingTranslation() {
        var previous = block("Hello world")
        previous.translation = "안녕하세요"
        previous.lines = [TextLine(text: "Hello world", rect: previous.rect, confidence: 1)]
        var incoming = block("Hello world")
        incoming.lines = [
            TextLine(text: "Hello", rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.02), confidence: 1),
            TextLine(text: "world", rect: CGRect(x: 0.1, y: 0.13, width: 0.2, height: 0.02), confidence: 1),
        ]
        let result = TextSnapshot.reconcile([incoming], previous: [previous], pixelSize: size)
        XCTAssertEqual(result[0].translation, previous.translation)
        XCTAssertEqual(result[0].lines, incoming.lines)
    }

}

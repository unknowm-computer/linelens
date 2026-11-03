import XCTest
@testable import LineLensCore

final class TextLayoutTests: XCTestCase {
    func testWrappedLinesBecomeSentenceInReadingOrder() {
        let second = TextLine(text: "on the next line.", rect: CGRect(x: 0.1, y: 0.16, width: 0.5, height: 0.05), confidence: 0.8)
        let first = TextLine(text: "A sentence continued", rect: CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.05), confidence: 0.95)
        let blocks = TextLayout.paragraphs(from: [second, first])
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.source, "A sentence continued on the next line.")
        XCTAssertEqual(blocks.first?.lines, [first, second])
        XCTAssertEqual(blocks.first?.confidence, 0.8)
        XCTAssertEqual(blocks.first!.rect.height, 0.11, accuracy: 0.0001)
    }

    func testSeparateParagraphsAndColumnsStaySeparate() {
        let lines = [
            TextLine(text: "Left column", rect: CGRect(x: 0.05, y: 0.1, width: 0.3, height: 0.05), confidence: 1),
            TextLine(text: "Right column", rect: CGRect(x: 0.6, y: 0.1, width: 0.3, height: 0.05), confidence: 1),
            TextLine(text: "Next paragraph", rect: CGRect(x: 0.05, y: 0.35, width: 0.3, height: 0.05), confidence: 1),
        ]
        XCTAssertEqual(TextLayout.paragraphs(from: lines).map(\.source), ["Left column", "Right column", "Next paragraph"])
    }

    func testEmptyLinesAreIgnored() {
        XCTAssertTrue(TextLayout.paragraphs(from: [TextLine(text: "  \n", rect: .zero, confidence: 1)]).isEmpty)
    }
    func testHeadingAndDescriptionDoNotMerge() {
        let lines = [
            TextLine(text: "Application", rect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.06), confidence: 1),
            TextLine(text: "Manage app settings", rect: CGRect(x: 0.1, y: 0.18, width: 0.5, height: 0.035), confidence: 1),
        ]
        XCTAssertEqual(TextLayout.paragraphs(from: lines).count, 2)
    }

}

import XCTest
@testable import LineLensCore

final class DirtyRegionPlannerTests: XCTestCase {
    func testExpandsEditedTileToEntireParagraphAndMergesOverlaps() {
        let paragraph = TextBlock(source: "Two wrapped lines", rect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2), confidence: 1)
        let regions = DirtyRegionPlanner.regions(changes: [CGRect(x: 0.15, y: 0.12, width: 0.05, height: 0.05),
            CGRect(x: 0.3, y: 0.25, width: 0.05, height: 0.05)], previous: [paragraph], pixelSize: CGSize(width: 1000, height: 1000))
        XCTAssertEqual(regions.count, 1)
        XCTAssertTrue(regions[0].contains(paragraph.rect))
        XCTAssertLessThan(regions[0].width * regions[0].height, 0.45)
    }

    func testLargeChangeUsesFullFrameAndEmptyChangeSkipsOCR() {
        XCTAssertEqual(DirtyRegionPlanner.regions(changes: [CGRect(x: 0, y: 0, width: 0.9, height: 0.9)], previous: [], pixelSize: .zero),
                       [CGRect(x: 0, y: 0, width: 1, height: 1)])
        XCTAssertTrue(DirtyRegionPlanner.regions(changes: [], previous: [], pixelSize: .zero).isEmpty)
    }
}

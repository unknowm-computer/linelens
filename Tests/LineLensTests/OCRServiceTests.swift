import AppKit
import XCTest
import LineLensCore
@testable import LineLens

final class OCRServiceTests: XCTestCase {
    @MainActor
    private func textImage(_ text: String, backgroundMark: Bool = false) throws -> CGImage {
        let image = NSImage(size: NSSize(width: 900, height: 180), flipped: false) { bounds in
            NSColor.white.setFill()
            bounds.fill()
            if backgroundMark {
                NSColor.black.setFill()
                CGRect(x: 850, y: 5, width: 3, height: 3).fill()
            }
            (text as NSString).draw(at: CGPoint(x: 30, y: 60), withAttributes: [
                .font: NSFont.systemFont(ofSize: 42), .foregroundColor: NSColor.black,
            ])
            return true
        }
        return try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    @MainActor
    func testVisionRecognizesTextAndSkipsIdenticalImage() async throws {
        let service = OCRService()
        let image = try textImage("Hello LineLens 123")
        let first = try await service.recognize(image, language: "en-US", previousFingerprint: nil)
        XCTAssertTrue(first.blocks?.map(\.source).joined(separator: " ").contains("Hello LineLens 123") == true)
        let second = try await service.recognize(image, language: "en-US", previousFingerprint: first.fingerprint)
        XCTAssertNil(second.blocks)
        XCTAssertEqual(first.fingerprint, second.fingerprint)
    }

    @MainActor
    func testChangedTextTriggersRecognition() async throws {
        let service = OCRService()
        let first = try await service.recognize(textImage("Page 123"), language: "en-US", previousFingerprint: nil)
        let next = try await service.recognize(textImage("Page 124"), language: "en-US", previousFingerprint: first.fingerprint)
        XCTAssertNotEqual(first.fingerprint, next.fingerprint)
        XCTAssertTrue(next.blocks?.map(\.source).joined(separator: " ").contains("124") == true)
    }

    @MainActor
    func testBackgroundOnlyChangePreservesRecognizedTextAndTranslation() async throws {
        let service = OCRService()
        let first = try await service.recognize(textImage("Hello LineLens 123"), language: "en-US", previousFingerprint: nil)
        var previous = try XCTUnwrap(first.blocks)
        XCTAssertFalse(previous.isEmpty)
        previous[0].translation = "기존 번역"
        let next = try await service.recognize(textImage("Hello LineLens 123", backgroundMark: true),
                                              language: "en-US", previousFingerprint: first.fingerprint)
        XCTAssertNotEqual(first.fingerprint, next.fingerprint)
        let blocks = try XCTUnwrap(next.blocks)
        let stable = TextSnapshot.reconcile(blocks, previous: previous, pixelSize: CGSize(width: 900, height: 180))
        XCTAssertEqual(stable, previous)
    }
}

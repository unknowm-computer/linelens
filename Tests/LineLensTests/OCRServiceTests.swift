import AppKit
import XCTest
import LineLensCore
@testable import LineLens

final class OCRServiceTests: XCTestCase {
    @MainActor
    private func textImage(_ text: String, backgroundMark: Bool = false, caret: Int? = nil) throws -> CGImage {
        let image = NSImage(size: NSSize(width: 900, height: 180), flipped: false) { bounds in
            NSColor.white.setFill()
            bounds.fill()
            if backgroundMark {
                NSColor.black.setFill()
                CGRect(x: 850, y: 5, width: 3, height: 3).fill()
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 42), .foregroundColor: NSColor.black,
            ]
            (text as NSString).draw(at: CGPoint(x: 30, y: 60), withAttributes: attributes)
            if let caret {
                let x = 32 + (text as NSString).size(withAttributes: attributes).width
                let rects = [CGRect(x: x, y: 64, width: 3, height: 42),
                             CGRect(x: x, y: 61, width: 24, height: 3),
                             CGRect(x: x, y: 64, width: 24, height: 42)]
                NSColor.black.setFill()
                rects[caret].fill()
            }
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

    @MainActor
    func testVisionIgnoresLearnedCursorCyclesAndStillRecognizesEditsAndDeletion() async throws {
        for mode in [OCRMode.fast, .accurate] {
            for caret in 0...2 {
                let stabilizer = OCRFrameStabilizer()
                let service = OCRService(stabilizer: stabilizer)
                let off = try textImage("Hello LineLens 123")
                let on = try textImage("Hello LineLens 123", caret: caret)
                let initial = try await service.recognize(off, language: "en-US", previousFingerprint: nil, mode: mode)
                XCTAssertTrue(initial.blocks?.contains { $0.source.contains("123") } == true)
                for image in [on, off, on] {
                    try await Task.sleep(for: .milliseconds(60))
                    await stabilizer.observe(CapturedFrame(image: image, fingerprint: ImageFingerprint.make(image)))
                }
                let blinking = try await service.recognize(on, language: "en-US", previousFingerprint: initial.fingerprint, mode: mode)
                XCTAssertEqual(blinking.fingerprint, initial.fingerprint, "\(mode), caret variant \(caret)")
                XCTAssertNil(blinking.blocks, "\(mode), caret variant \(caret): a learned blink must reuse OCR instead of recognizing a caret as a character")
                let edited = try await service.recognize(textImage("Hello LineLens 128", caret: caret), language: "en-US", previousFingerprint: blinking.fingerprint, mode: mode)
                XCTAssertTrue(edited.blocks?.contains { $0.source.contains("128") } == true)
                let deleted = try await service.recognize(textImage(""), language: "en-US", previousFingerprint: edited.fingerprint, mode: mode)
                XCTAssertEqual(deleted.blocks, [])
            }
        }
    }
}

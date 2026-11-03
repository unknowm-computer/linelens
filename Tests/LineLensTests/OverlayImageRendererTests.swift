import AppKit
import XCTest
import LineLensCore
@testable import LineLens

final class OverlayImageRendererTests: XCTestCase {
    @MainActor
    private func fixture(dark: Bool = false) throws -> CGImage {
        let image = NSImage(size: NSSize(width: 700, height: 380), flipped: true) { bounds in
            (dark ? NSColor(calibratedWhite: 0.15, alpha: 1) : NSColor.white).setFill()
            bounds.fill()
            NSColor.systemBlue.setFill()
            CGRect(x: 24, y: 145, width: 280, height: 3).fill()
            let color: NSColor = dark ? .white : .black
            ("Application Settings" as NSString).draw(at: CGPoint(x: 24, y: 32), withAttributes: [
                .font: NSFont.systemFont(ofSize: 26), .foregroundColor: color,
            ])
            ("Prevent the computer from sleeping while the app is running." as NSString)
                .draw(at: CGPoint(x: 24, y: 100), withAttributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: color])
            ("Keep in menu bar" as NSString).draw(at: CGPoint(x: 24, y: 200), withAttributes: [
                .font: NSFont.systemFont(ofSize: 20), .foregroundColor: color,
            ])
            return true
        }
        return try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    @MainActor
    func testLightAndDarkBackgroundsPreservePixelsOutsideTextAndRemoveEnglish() async throws {
        for dark in [false, true] {
            let source = try fixture(dark: dark)
            let ocr = OCRService()
            let recognizedSource = try await ocr.recognize(source, language: "en-US", previousFingerprint: nil)
            var blocks = try XCTUnwrap(recognizedSource.blocks)
            XCTAssertEqual(blocks.count, 3)
            for index in blocks.indices {
                let text = blocks[index].source
                blocks[index].translation = text.contains("Application") ? "앱 설정" : text.contains("Prevent") ? "앱 실행 중 잠자기 방지" : "메뉴 막대에 유지"
                XCTAssertFalse(blocks[index].lines.isEmpty)
            }
            let renderer = OverlayImageRenderer()
            let rendered = try await renderer.render(image: source, pointSize: CGSize(width: 700, height: 380), blocks: blocks, style: .cover)
            let overlay = try XCTUnwrap(rendered)
            let result = try flatten(overlay, over: source)
            XCTAssertEqual(result.width, source.width)
            XCTAssertEqual(result.height, source.height)
            let before = try XCTUnwrap(ImagePixels(source))
            let after = try XCTUnwrap(ImagePixels(result))
            let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
            let masks = blocks.flatMap(\.lines).map { CaptureGeometry.resolve($0.rect, in: bounds).insetBy(dx: -4, dy: -4) }
            var changed = 0
            var unexpected = 0
            for y in 0..<source.height {
                for x in 0..<source.width {
                    let offset = (y * source.width + x) * 4
                    if before.bytes[offset..<(offset + 4)] != after.bytes[offset..<(offset + 4)] {
                        changed += 1
                        if !masks.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) { unexpected += 1 }
                    }
                }
            }
            XCTAssertEqual(unexpected, 0, "Pixels outside OCR line boxes must remain unchanged")
            XCTAssertGreaterThan(changed, 500)
            let recognized = try await ocr.recognize(result, language: "auto", previousFingerprint: nil)
            let text = recognized.blocks?.map(\.source).joined(separator: " ") ?? ""
            XCTAssertFalse(text.contains("Application"))
            XCTAssertFalse(text.contains("Prevent"))
            XCTAssertTrue(text.contains("설정"), text)
            let directory = URL(fileURLWithPath: "/tmp/linelens-overlay-qa", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent(dark ? "dark.png" : "light.png"))
        }
    }

    @MainActor
    func testUntranslatedImageRetainsOrientationColorsAndPixelsAtRetinaScale() async throws {
        let source = try fixture()
        let rendered = try await OverlayImageRenderer().render(image: source,
            pointSize: CGSize(width: 350, height: 190), blocks: [], style: .cover)
        let result = try XCTUnwrap(rendered)
        XCTAssertTrue(try XCTUnwrap(ImagePixels(result)).bytes.enumerated().allSatisfy { $0.offset % 4 != 3 || $0.element == 255 })
        XCTAssertEqual(ImageFingerprint.make(source), ImageFingerprint.make(result))
    }

    @MainActor
    func testOverlayDoesNotReceiveMouseEventsOrBecomeKey() async throws {
        let controller = TranslationOverlayController()
        controller.show(rect: CGRect(x: 20, y: 40, width: 700, height: 380), image: try fixture())
        defer { controller.clear() }
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertFalse(window.canBecomeKey)
        XCTAssertFalse(window.canBecomeMain)
    }
    @MainActor
    func testLongTranslationStaysInsideItsTextAreaAtRetinaScale() async throws {
        let source = try fixture()
        let recognition = try await OCRService().recognize(source, language: "en-US", previousFingerprint: nil)
        var blocks = try XCTUnwrap(recognition.blocks)
        for index in blocks.indices { blocks[index].translation = String(repeating: "아주 긴 번역문입니다. ", count: 30) }
        let rendered = try await OverlayImageRenderer().render(image: source, pointSize: CGSize(width: 700, height: 380), blocks: blocks, style: .cover)
        let result = try flatten(XCTUnwrap(rendered), over: source)
        let before = try XCTUnwrap(ImagePixels(source))
        let after = try XCTUnwrap(ImagePixels(result))
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let masks = blocks.map { CaptureGeometry.resolve($0.rect, in: bounds).insetBy(dx: -4, dy: -4) }
        var unexpected = 0
        for y in 0..<source.height {
            for x in 0..<source.width where !masks.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) {
                let offset = (y * source.width + x) * 4
                if before.bytes[offset..<(offset + 4)] != after.bytes[offset..<(offset + 4)] { unexpected += 1 }
            }
        }
        XCTAssertEqual(unexpected, 0)
    }

    @MainActor
    func testFrameSignatureDetectsAColorChangeAndExistingSettingsStillDecode() throws {
        let red = NSImage(size: NSSize(width: 10, height: 10), flipped: true) { bounds in
            NSColor.red.setFill(); bounds.fill(); return true
        }
        let green = NSImage(size: NSSize(width: 10, height: 10), flipped: true) { bounds in
            NSColor.green.setFill(); bounds.fill(); return true
        }
        let redImage = try XCTUnwrap(red.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let greenImage = try XCTUnwrap(green.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertNotEqual(ImageFingerprint.make(redImage), ImageFingerprint.make(greenImage))
        var previous = AppSettings()
        previous.presentation = .both
        previous.translationEnabled = false
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(previous))
        XCTAssertEqual(restored, previous)
    }

    private func flatten(_ overlay: CGImage, over source: CGImage) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: source.width, height: source.height,
            bitsPerComponent: 8, bytesPerRow: source.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        context.draw(source, in: bounds)
        context.draw(overlay, in: bounds)
        return try XCTUnwrap(context.makeImage())
    }

}

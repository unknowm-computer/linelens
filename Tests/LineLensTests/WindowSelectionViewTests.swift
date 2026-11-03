import AppKit
import XCTest
@testable import LineLens

final class WindowSelectionViewTests: XCTestCase {
    @MainActor
    func testHoveredWindowKeepsMouseCoverageInsteadOfATransparentHole() throws {
        for origin in [CGPoint.zero, CGPoint(x: -300, y: 200)] {
            let frame = CGRect(origin: origin, size: CGSize(width: 200, height: 160))
            let view = WindowSelectionView(frame: CGRect(origin: .zero, size: frame.size), screenFrame: frame)
            view.highlight = CGRect(x: origin.x + 40, y: origin.y + 40, width: 120, height: 80)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200,
                pixelsHigh: 160, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 800, bitsPerPixel: 32))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            view.draw(view.bounds)
            NSGraphicsContext.restoreGraphicsState()
            let hovered = try XCTUnwrap(bitmap.colorAt(x: 100, y: 80))
            let outside = try XCTUnwrap(bitmap.colorAt(x: 10, y: 80))
            // WindowServer can pass clicks through fully transparent pixels,
            // even though NSView.hitTest returns the selection view.
            XCTAssertGreaterThan(hovered.alphaComponent, 0.01, "Hover must retain a mouse-catching surface")
            XCTAssertLessThan(hovered.alphaComponent, outside.alphaComponent, "The hovered window should remain brighter")
        }
    }
}

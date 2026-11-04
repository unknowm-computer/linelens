import CoreGraphics
import LineLensCore

enum OCRTextStability {
    /// A failed reading cannot erase a paragraph whose original glyph pixels
    /// are still present. A real deletion or one-character edit changes those
    /// pixels and is published immediately, without a debounce or extra OCR pass.
    static func retainingVisibleText(_ incoming: [TextBlock], previous: [TextBlock],
                                     before: ImagePixels, after: ImagePixels, regions: [CGRect]) -> [TextBlock] {
        guard before.width == after.width, before.height == after.height else { return incoming }
        var result = incoming
        for old in previous where regions.contains(where: { $0.intersects(old.rect) }) {
            let overlapping = result.filter { $0.rect.intersects(old.rect) }
            if overlapping.contains(where: { $0.source == old.source || ($0.source.hasPrefix(old.source) && $0.source.count > old.source.count) }) {
                continue
            }
            guard preservesGlyphs(old, before: before, after: after) else { continue }
            result.removeAll { $0.rect.intersects(old.rect) }
            result.append(old)
        }
        return result.sorted { $0.rect.minY == $1.rect.minY ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY }
    }

    static func preservesGlyphs(_ block: TextBlock, before: ImagePixels, after: ImagePixels) -> Bool {
        guard before.width == after.width, before.height == after.height else { return false }
        let bounds = CGRect(x: 0, y: 0, width: before.width, height: before.height)
        var ink = 0
        for line in block.lines.isEmpty ? [block.rect] : block.lines.map(\.rect) {
            let rect = CaptureGeometry.resolve(line, in: bounds).integral.intersection(bounds)
            guard !rect.isEmpty, !rect.isNull else { return false }
            let outside = rect.insetBy(dx: -2, dy: -2).intersection(bounds)
            var colors: [Int: Int] = [:]
            for y in Int(outside.minY)..<Int(outside.maxY) {
                for x in Int(outside.minX)..<Int(outside.maxX) where !rect.contains(CGPoint(x: x, y: y)) {
                    let offset = (y * before.width + x) * 4
                    let color = Int(before.bytes[offset] >> 4) << 8 | Int(before.bytes[offset + 1] >> 4) << 4 | Int(before.bytes[offset + 2] >> 4)
                    colors[color, default: 0] += 1
                }
            }
            guard let background = colors.max(by: { $0.value < $1.value })?.key else { return false }
            let rgb = [(background >> 8) * 16 + 8, ((background >> 4) & 15) * 16 + 8, (background & 15) * 16 + 8]
            var minX = Int(rect.maxX), minY = Int(rect.maxY), maxX = -1, maxY = -1
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    let offset = (y * before.width + x) * 4
                    guard (0..<3).contains(where: { abs(Int(before.bytes[offset + $0]) - rgb[$0]) > 32 }) else { continue }
                    ink += 1
                    minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                    if (0..<3).contains(where: { abs(Int(before.bytes[offset + $0]) - Int(after.bytes[offset + $0])) > 12 }) { return false }
                }
            }
            // Added strokes can also be a real edit (for example 3 -> 8). Only
            // additions outside the existing glyph extent qualify as a caret miss.
            if maxX >= minX, maxY >= minY {
                for y in minY...maxY {
                    for x in minX...maxX {
                        let offset = (y * before.width + x) * 4
                        if (0..<3).contains(where: { abs(Int(before.bytes[offset + $0]) - Int(after.bytes[offset + $0])) > 12 }) { return false }
                    }
                }
            }
        }
        return ink >= 8
    }
}

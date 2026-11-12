import CoreGraphics
import LineLensCore

enum OCRTextStability {
    /// A failed reading cannot erase a paragraph whose original glyph pixels
    /// are still present. A real deletion or one-character edit changes those
    /// pixels and is published immediately, without a debounce or extra OCR pass.
    static func retainingVisibleText(_ incoming: [TextBlock], previous: [TextBlock],
                                     before oldPixels: @autoclosure () -> ImagePixels?,
                                     after newPixels: @autoclosure () -> ImagePixels?, regions: [CGRect]? = nil) -> [TextBlock] {
        let missing = previous.filter { old in
            (regions?.contains { $0.intersects(old.rect) } ?? true) && !incoming.contains { candidate in
                // A longer reading of the same lines can be a real append. A
                // paragraph that joined adjacent lines still needs checking.
                let sameLines = candidate.lines.count <= max(1, old.lines.count)
                    && candidate.rect.height <= old.rect.height * 1.5
                return overlapsText(candidate.rect, old.rect)
                    && (candidate.source == old.source || (sameLines && candidate.source.hasPrefix(old.source)))
            }
        }
        // Pixel conversion is only needed when recognition omitted or regrouped text.
        guard !missing.isEmpty, !Task.isCancelled, let before = oldPixels(), let after = newPixels() else { return incoming }
        let retained = missing.filter { preservesGlyphs($0, before: before, after: after) }
        guard !retained.isEmpty else { return incoming }

        let retainedRects = retained.flatMap { $0.lines.isEmpty ? [$0.rect] : $0.lines.map(\.rect) }
        func isRetained(_ rect: CGRect) -> Bool {
            retainedRects.contains { overlapsText(rect, $0) }
        }
        let fresh = incoming.flatMap { block -> [TextBlock] in
            guard block.lines.contains(where: { isRetained($0.rect) }) else {
                return block.lines.isEmpty && isRetained(block.rect) ? [] : [block]
            }
            // A merged result can also contain a new line. Keep that line and
            // draw the confirmed translation over only its original lines.
            return TextLayout.paragraphs(from: block.lines.filter { !isRetained($0.rect) })
        }
        return (fresh + retained).sorted { $0.rect.minY == $1.rect.minY ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY }
    }

    private static func overlapsText(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = a.intersection(b)
        return !overlap.isEmpty && overlap.width >= min(a.width, b.width) * 0.5
            && overlap.height >= min(a.height, b.height) * 0.5
    }

    static func preservesGlyphs(_ block: TextBlock, before: ImagePixels, after: ImagePixels) -> Bool {
        guard !Task.isCancelled, before.width == after.width, before.height == after.height else { return false }
        let bounds = CGRect(x: 0, y: 0, width: before.width, height: before.height)
        if preservesOriginalPixels(block, before: before, after: after, bounds: bounds) { return true }
        let lines = block.lines.isEmpty ? [block.rect] : block.lines.map(\.rect)
        return lines.allSatisfy { line in
            let rect = CaptureGeometry.resolve(line, in: bounds).integral.intersection(bounds)
            return hasMatchingInk(in: rect, before: before, after: after)
        }
    }

    /// Estimate each frame's background independently. The contrast mask stays
    /// at the same coordinates when a hover, selection, or theme recolors text.
    static func hasMatchingInk(in rect: CGRect, before: ImagePixels, after: ImagePixels,
                               ignoring ignored: [CGRect] = []) -> Bool {
        guard !rect.isNull, !rect.isEmpty else { return false }
        let xRange = Int(rect.minX)..<Int(rect.maxX)
        let yRange = Int(rect.minY)..<Int(rect.maxY)
        // A partial selection can put two colors behind the same line. Use
        // the column colors when both margins agree on where those colors lie.
        if let oldColors = backgroundColors(atEdgesOf: yRange, columns: xRange, pixels: before),
           let newColors = backgroundColors(atEdgesOf: yRange, columns: xRange, pixels: after),
           Set(oldColors).count > 1 || Set(newColors).count > 1 {
            return matchingInk(columns: xRange, rows: yRange, before: before, after: after,
                oldColors: oldColors, newColors: newColors, ignoring: ignored)
        }
        guard let oldBackground = backgroundColor(in: xRange, rows: yRange, pixels: before),
              let newBackground = backgroundColor(in: xRange, rows: yRange, pixels: after) else { return false }
        return matchingInk(columns: xRange, rows: yRange, before: before, after: after,
            oldColors: Array(repeating: oldBackground, count: xRange.count),
            newColors: Array(repeating: newBackground, count: xRange.count), ignoring: ignored)
    }

    private static func matchingInk(columns: Range<Int>, rows: Range<Int>, before: ImagePixels, after: ImagePixels,
                                    oldColors: [Int], newColors: [Int], ignoring ignored: [CGRect]) -> Bool {
        var sharedInk = 0
        var changedInk = 0
        for y in rows {
            guard !Task.isCancelled else { return false }
            for (column, x) in columns.enumerated() {
                if ignored.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) { continue }
                let offset = (y * before.width + x) * 4
                let oldContrast = contrast(before.bytes, offset: offset, background: oldColors[column])
                let newContrast = contrast(after.bytes, offset: offset, background: newColors[column])
                if oldContrast >= 42 && newContrast >= 42 {
                    sharedInk += 1
                } else if (oldContrast >= 42 && newContrast <= 22) || (newContrast >= 42 && oldContrast <= 22) {
                    // Count stroke edits in both directions, even in a long line.
                    changedInk += 1
                    if changedInk > 3 { return false }
                }
            }
        }
        return sharedInk >= 8
    }

    private static func backgroundColors(atEdgesOf rows: Range<Int>, columns: Range<Int>, pixels: ImagePixels) -> [Int]? {
        guard rows.lowerBound >= 2, rows.upperBound + 1 < pixels.height else { return nil }
        let top = rows.lowerBound - 2
        let bottom = rows.upperBound
        var colors: [Int] = []
        colors.reserveCapacity(columns.count)
        for x in columns {
            let color = colorBucket(in: pixels, x: x, y: top)
            guard colorBucket(in: pixels, x: x, y: top + 1) == color,
                  colorBucket(in: pixels, x: x, y: bottom) == color,
                  colorBucket(in: pixels, x: x, y: bottom + 1) == color else { return nil }
            colors.append(color)
        }
        return colors
    }

    private static func backgroundColor(in columns: Range<Int>, rows: Range<Int>, pixels: ImagePixels) -> Int? {
        var colors: [Int: Int] = [:]
        var samples = 0
        for y in stride(from: rows.lowerBound, to: rows.upperBound, by: max(1, rows.count / 16)) {
            for x in stride(from: columns.lowerBound, to: columns.upperBound, by: max(1, columns.count / 64)) {
                let bucket = colorBucket(in: pixels, x: x, y: y)
                colors[bucket, default: 0] += 1
                samples += 1
            }
        }
        // If the region has no dominant color, leave it to the strict pixel check.
        guard let dominant = colors.max(by: { $0.value < $1.value }), dominant.value * 3 >= samples else { return nil }
        return dominant.key
    }

    private static func colorBucket(in pixels: ImagePixels, x: Int, y: Int) -> Int {
        let offset = (y * pixels.width + x) * 4
        return Int(pixels.bytes[offset] >> 4) << 8 | Int(pixels.bytes[offset + 1] >> 4) << 4 | Int(pixels.bytes[offset + 2] >> 4)
    }

    private static func contrast(_ bytes: [UInt8], offset: Int, background: Int) -> Int {
        let red = abs(Int(bytes[offset]) - ((background >> 8) * 16 + 8))
        let green = abs(Int(bytes[offset + 1]) - (((background >> 4) & 15) * 16 + 8))
        let blue = abs(Int(bytes[offset + 2]) - ((background & 15) * 16 + 8))
        return max(red, green, blue)
    }

    private static func preservesOriginalPixels(_ block: TextBlock, before: ImagePixels, after: ImagePixels, bounds: CGRect) -> Bool {
        var ink = 0
        for line in block.lines.isEmpty ? [block.rect] : block.lines.map(\.rect) {
            let rect = CaptureGeometry.resolve(line, in: bounds).integral.intersection(bounds)
            guard !rect.isEmpty, !rect.isNull else { return false }
            let outside = rect.insetBy(dx: -2, dy: -2).intersection(bounds)
            var colors: [Int: Int] = [:]
            for y in Int(outside.minY)..<Int(outside.maxY) {
                for x in Int(outside.minX)..<Int(outside.maxX) where !rect.contains(CGPoint(x: x, y: y)) {
                    let color = colorBucket(in: before, x: x, y: y)
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

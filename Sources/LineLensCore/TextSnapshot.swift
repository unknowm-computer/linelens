import Foundation

public enum TextSnapshot {
    /// Background animation and OCR rounding do not change the identity or translation of text.
    /// Match duplicate strings by proximity so repeated labels keep their own rows.
    public static func reconcile(_ incoming: [TextBlock], previous: [TextBlock], pixelSize: CGSize) -> [TextBlock] {
        var available = Set(previous.indices)
        return incoming.map { block in
            guard let match = available.filter({ previous[$0].source == block.source }).min(by: {
                distance(previous[$0].rect, block.rect) < distance(previous[$1].rect, block.rect)
            }) else { return block }
            available.remove(match)
            var preserved = previous[match]
            if !isNearlyEqual(preserved.rect, block.rect, pixelSize: pixelSize) { preserved.rect = block.rect }
            // Image compositing needs this frame's exact line boxes, including wrapping changes.
            preserved.lines = block.lines
            preserved.fontSizeHint = block.fontSizeHint
            return preserved
        }
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.midX - b.midX) + abs(a.midY - b.midY)
    }

    private static func isNearlyEqual(_ a: CGRect, _ b: CGRect, pixelSize: CGSize) -> Bool {
        let width = max(pixelSize.width, 1)
        let height = max(pixelSize.height, 1)
        return abs(a.minX - b.minX) * width <= 2
            && abs(a.minY - b.minY) * height <= 2
            && abs(a.maxX - b.maxX) * width <= 2
            && abs(a.maxY - b.maxY) * height <= 2
    }
}

import Foundation

public enum DirtyRegionPlanner {
    /// Expand to whole previous text blocks before re-recognition: never leave
    /// half an old paragraph behind when a tile clips one of its wrapped lines.
    public static func regions(changes: [CGRect], previous: [TextBlock], pixelSize: CGSize) -> [CGRect] {
        let bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        let dx = 2 / max(pixelSize.width, 1), dy = 2 / max(pixelSize.height, 1)
        var regions = changes.map { $0.intersection(bounds) }.filter { !$0.isNull && !$0.isEmpty }
        guard !regions.isEmpty else { return [] }
        var changed = true
        while changed {
            changed = false
            for index in regions.indices {
                for block in previous where regions[index].intersects(block.rect) {
                    let expanded = regions[index].union(block.rect.insetBy(dx: -dx, dy: -dy)).intersection(bounds)
                    if expanded != regions[index] { regions[index] = expanded; changed = true }
                }
            }
            var merged: [CGRect] = []
            for region in regions {
                if let index = merged.firstIndex(where: { $0.insetBy(dx: -dx, dy: -dy).intersects(region) }) {
                    let union = merged[index].union(region)
                    if union != merged[index] { changed = true }
                    merged[index] = union
                } else { merged.append(region) }
            }
            if merged.count != regions.count { changed = true }
            regions = merged
        }
        let area = regions.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
        if regions.count > 8 || area > 0.45 { return [bounds] }
        return regions.sorted { $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY }
    }
}

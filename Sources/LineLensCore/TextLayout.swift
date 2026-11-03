import Foundation

public struct TextLine: Sendable, Equatable {
    public let text: String
    public let rect: CGRect
    public let confidence: Float

    public init(text: String, rect: CGRect, confidence: Float) {
        self.text = text
        self.rect = rect
        self.confidence = confidence
    }
}

public struct TextBlock: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var source: String
    public var translation: String?
    /// Normalized coordinates with a top-left origin, relative to the captured region.
    public var rect: CGRect
    public var confidence: Float
    /// Keep the original line boxes for erasing text without filling paragraph gaps.
    public var lines: [TextLine]
    public var fontSizeHint: CGFloat?

    public init(id: UUID = UUID(), source: String, rect: CGRect, confidence: Float, lines: [TextLine] = []) {
        self.id = id
        self.source = source
        self.rect = rect
        self.confidence = confidence
        self.lines = lines
        self.fontSizeHint = nil
    }
}

public enum TextLayout {
    public static func paragraphs(from lines: [TextLine]) -> [TextBlock] {
        let ordered = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.rect.minY == $1.rect.minY ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY }
        var groups: [[TextLine]] = []
        for line in ordered {
            let candidate = groups.indices.filter { index in
                guard let last = groups[index].last else { return false }
                let gap = line.rect.minY - last.rect.maxY
                let overlap = min(last.rect.maxX, line.rect.maxX) - max(last.rect.minX, line.rect.minX)
                let aligned = abs(last.rect.minX - line.rect.minX) < max(last.rect.height, line.rect.height)
                return gap >= -min(last.rect.height, line.rect.height) * 0.25
                    && gap < min(last.rect.height, line.rect.height) * 0.55
                    && max(last.rect.height, line.rect.height) <= min(last.rect.height, line.rect.height) * 1.25
                    && overlap > min(last.rect.width, line.rect.width) * 0.4 && aligned
            }.min { left, right in
                line.rect.minY - groups[left].last!.rect.maxY < line.rect.minY - groups[right].last!.rect.maxY
            }
            if let candidate { groups[candidate].append(line) } else { groups.append([line]) }
        }
        return groups.compactMap { group in
            guard let first = group.first else { return nil }
            // A space restores sentences broken by visual wrapping without merging separate paragraphs.
            return TextBlock(source: group.map(\.text).joined(separator: " "),
                             rect: group.dropFirst().reduce(first.rect) { $0.union($1.rect) },
                             confidence: group.map(\.confidence).min() ?? 0, lines: group)
        }.sorted { $0.rect.minY == $1.rect.minY ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY }
    }
}

import CoreGraphics
import Foundation
import LineLensCore

/// Learns small A/B pixel cycles near known text. No cursor glyphs or OCR
/// strings are blacklisted, and a third pixel state invalidates a learned cycle.
actor OCRFrameStabilizer {
    struct Normalized: Sendable {
        let image: CGImage
        let pixels: ImagePixels?
    }

    private struct Cycle {
        let rect: CGRect
        let first: [UInt8]
        let second: [UInt8]
        var isSecond = true
        var transitions = 1
        var lastTransition: TimeInterval
        var isBlinking: Bool { transitions >= 3 }
    }

    private let now: @Sendable () -> TimeInterval
    private var previous: ImagePixels?
    private var fingerprint: UInt64?
    private var sequence: UInt64 = 0
    private var regions: [CGRect] = []
    private var trackedBlocks: [TextBlock] = []
    private var cycles: [Cycle] = []

    init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    func track(_ blocks: [TextBlock], pixelSize: CGSize) {
        let bounds = CGRect(origin: .zero, size: pixelSize)
        let changed = trackedBlocks.filter { old in
            !blocks.contains { $0.source == old.source && $0.rect.intersects(old.rect) }
        } + blocks.filter { new in
            !trackedBlocks.contains { $0.source == new.source && $0.rect.intersects(new.rect) }
        }
        // Repeated real values (such as a counter toggling between 1 and 2)
        // must not become a cursor mask after OCR has confirmed an edit.
        cycles.removeAll { cycle in
            changed.contains { block in
                let rect = CaptureGeometry.resolve(block.rect, in: bounds)
                return rect.insetBy(dx: -max(4, rect.height), dy: -max(2, rect.height * 0.5)).intersects(cycle.rect)
            }
        }
        trackedBlocks = blocks
        regions = blocks.flatMap { block in
            (block.lines.isEmpty ? [block.rect] : block.lines.map(\.rect)).map { line in
                let rect = CaptureGeometry.resolve(line, in: bounds)
                // Include an insertion caret just beyond either end of a line.
                return rect.insetBy(dx: -max(4, rect.height), dy: -max(2, rect.height * 0.5))
                    .integral.intersection(bounds)
            }
        }
        cycles.removeAll { cycle in !regions.contains { $0.contains(cycle.rect) } }
    }

    func observe(_ frame: CapturedFrame) {
        guard frame.sequence == 0 || sequence <= frame.sequence else { return }
        let time = now()
        cycles.removeAll { time - $0.lastTransition > 1.4 }
        guard let pixels = frame.pixels ?? ImagePixels(frame.image) else { return }
        defer {
            previous = pixels
            fingerprint = frame.fingerprint
            sequence = frame.sequence
        }
        guard let previous, previous.width == pixels.width, previous.height == pixels.height else {
            cycles.removeAll()
            return
        }
        guard fingerprint != frame.fingerprint else { return }
        let bounds = CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height)
        for tracked in regions {
            let region = tracked.intersection(bounds)
            guard !region.isEmpty, !region.isNull else { continue }
            guard let change = difference(previous, pixels, in: region) else { continue }
            let related = cycles.firstIndex { $0.rect.intersects(region) }
            if let index = related {
                var cycle = cycles[index]
                let current = patch(pixels, rect: cycle.rect)
                let phase: Bool? = current == cycle.first ? false : current == cycle.second ? true : nil
                if cycle.rect.contains(change), let phase {
                    if phase != cycle.isSecond {
                        let interval = time - cycle.lastTransition
                        cycle.transitions = (0.04...1.2).contains(interval) ? cycle.transitions + 1 : 1
                        cycle.isSecond = phase
                        cycle.lastTransition = time
                        cycles[index] = cycle
                    }
                    continue
                }
                // An edit anywhere on this line must not be hidden by its caret mask.
                cycles.remove(at: index)
            }
            guard change.width <= 128, change.height <= 128, change.width * change.height <= 16384,
                  cycles.count < 32 else { continue }
            cycles.append(Cycle(rect: change, first: patch(previous, rect: change),
                                second: patch(pixels, rect: change), lastTransition: time))
        }
    }

    func ignoredRegions(in image: CGImage, pixels: ImagePixels?, baseline: ImagePixels) -> [CGRect] {
        guard let pixels = pixels ?? ImagePixels(image) else { return [] }
        guard pixels.width == baseline.width, pixels.height == baseline.height else { return [] }
        return activeCycles(in: pixels).filter { cycle in
            let before = patch(baseline, rect: cycle.rect)
            return before == cycle.first || before == cycle.second
        }.map { cycle in
            CGRect(x: cycle.rect.minX / CGFloat(pixels.width), y: cycle.rect.minY / CGFloat(pixels.height),
                   width: cycle.rect.width / CGFloat(pixels.width), height: cycle.rect.height / CGFloat(pixels.height))
        }
    }

    func normalized(_ image: CGImage, pixels: ImagePixels?) -> Normalized {
        guard let pixels = pixels ?? ImagePixels(image) else { return Normalized(image: image, pixels: nil) }
        let active = activeCycles(in: pixels)
        guard !active.isEmpty else { return Normalized(image: image, pixels: pixels) }
        var bytes = pixels.bytes
        for cycle in active {
            let width = Int(cycle.rect.width)
            for row in 0..<Int(cycle.rect.height) {
                let start = ((Int(cycle.rect.minY) + row) * pixels.width + Int(cycle.rect.minX)) * 4
                bytes.replaceSubrange(start..<start + width * 4, with: cycle.first[row * width * 4..<(row + 1) * width * 4])
            }
        }
        let stable = ImagePixels(width: pixels.width, height: pixels.height, bytes: bytes)
        guard let image = stable.makeImage() else { return Normalized(image: image, pixels: pixels) }
        return Normalized(image: image, pixels: stable)
    }

    private func activeCycles(in pixels: ImagePixels) -> [Cycle] {
        let time = now()
        let bounds = CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height)
        return cycles.filter { cycle in
            guard cycle.isBlinking, time - cycle.lastTransition <= 1.4, bounds.contains(cycle.rect) else { return false }
            let current = patch(pixels, rect: cycle.rect)
            return current == cycle.first || current == cycle.second
        }
    }

    /// Bounded work on text lines, with an early exit for scrolling/large edits.
    private func difference(_ before: ImagePixels, _ after: ImagePixels, in rect: CGRect) -> CGRect? {
        var minX = Int(rect.maxX), minY = Int(rect.maxY), maxX = -1, maxY = -1, count = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let offset = (y * before.width + x) * 4
                if (0..<3).contains(where: { abs(Int(before.bytes[offset + $0]) - Int(after.bytes[offset + $0])) > 12 }) {
                    minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                    count += 1
                    if count > 16384 || maxX - minX >= 128 || maxY - minY >= 128 { return rect }
                }
            }
        }
        return maxX < 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func patch(_ pixels: ImagePixels, rect: CGRect) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(Int(rect.width * rect.height) * 4)
        for y in Int(rect.minY)..<Int(rect.maxY) {
            let start = (y * pixels.width + Int(rect.minX)) * 4
            result.append(contentsOf: pixels.bytes[start..<start + Int(rect.width) * 4])
        }
        return result
    }
}

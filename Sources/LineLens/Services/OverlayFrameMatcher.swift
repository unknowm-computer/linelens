import CoreGraphics
import LineLensCore

/// Compare only pixels covered by translated patches. A clock, video, cursor or
/// loading animation elsewhere must not invalidate otherwise unchanged text.
actor OverlayFrameMatcher {
    private var baseline: CGImage?
    private var baselinePixels: ImagePixels?

    func matches(_ image: CGImage, baseline source: CGImage, regions: [CGRect], pixels: ImagePixels? = nil, sourcePixels: ImagePixels? = nil) throws -> Bool {
        try Task.checkCancellation()
        guard image.width == source.width, image.height == source.height else { return false }
        if image === source { return true }
        if baseline !== source {
            baseline = source
            baselinePixels = sourcePixels ?? ImagePixels(source)
        }
        guard let before = baselinePixels, let after = pixels ?? ImagePixels(image) else { return false }
        let bounds = CGRect(x: 0, y: 0, width: before.width, height: before.height)
        for region in regions {
            let rect = CaptureGeometry.resolve(region, in: bounds).intersection(bounds).integral.intersection(bounds)
            guard !rect.isNull, rect.width > 0, rect.height > 0 else { continue }
            var changed = 0
            // Ignore compression/color rounding and a few isolated noisy pixels,
            // but do not use a whole-screen percentage that could hide a digit edit.
            let allowance = max(3, min(16, Int(rect.width * rect.height) / 1000))
            for y in Int(rect.minY)..<Int(rect.maxY) {
                try Task.checkCancellation()
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    let offset = (y * before.width + x) * 4
                    if (0..<3).contains(where: { abs(Int(before.bytes[offset + $0]) - Int(after.bytes[offset + $0])) > 12 }) {
                        changed += 1
                        if changed > allowance { return false }
                    }
                }
            }
        }
        return true
    }
}

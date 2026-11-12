import CoreGraphics
import Foundation
import LineLensCore

/// A canonical sRGB, top-row-first buffer shared by frame detection and compositing.
struct ImagePixels: Sendable {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(width: Int, height: Int, bytes: [UInt8]) {
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    func makeImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    init?(_ image: CGImage) {
        let width = image.width
        let height = image.height
        var storage = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = storage.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        bytes = storage
    }

    var fingerprint: UInt64 {
        // Include every pixel and all color channels: small digits and equal-luminance
        // hover/selection colors must invalidate a full-image overlay too.
        var value = UInt64(width) ^ (UInt64(height) << 32)
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let pixel = UInt64(bytes[offset]) | UInt64(bytes[offset + 1]) << 8
                | UInt64(bytes[offset + 2]) << 16 | UInt64(bytes[offset + 3]) << 24
            value = (value ^ pixel) &* 1_099_511_628_211
        }
        return value
    }
}

enum ImageFingerprint {
    static func make(_ image: CGImage) -> UInt64 {
        ImagePixels(image)?.fingerprint ?? UInt64.random(in: .min ... .max)
    }
}

extension ImagePixels {
    func hasSamePixels(as other: ImagePixels, in regions: [CGRect]) -> Bool {
        guard width == other.width, height == other.height else { return false }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        return bytes.withUnsafeBytes { before in
            other.bytes.withUnsafeBytes { after in
                guard let oldBytes = before.baseAddress, let newBytes = after.baseAddress else { return false }
                return regions.allSatisfy { region in
                    let rect = CaptureGeometry.resolve(region, in: bounds).integral.intersection(bounds)
                    guard !rect.isNull, !rect.isEmpty else { return true }
                    let column = Int(rect.minX)
                    let rowBytes = Int(rect.width) * 4
                    for row in Int(rect.minY)..<Int(rect.maxY) {
                        let offset = (row * width + column) * 4
                        if memcmp(oldBytes.advanced(by: offset), newBytes.advanced(by: offset), rowBytes) != 0 { return false }
                    }
                    return true
                }
            }
        }
    }

    func changedTiles(from previous: ImagePixels, tileSize: Int = 64) -> [CGRect] {
        guard width == previous.width, height == previous.height else { return [CGRect(x: 0, y: 0, width: 1, height: 1)] }
        var regions: [CGRect] = []
        for y0 in stride(from: 0, to: height, by: tileSize) {
            for x0 in stride(from: 0, to: width, by: tileSize) {
                let x1 = min(width, x0 + tileSize), y1 = min(height, y0 + tileSize)
                var changed = false
                rows: for y in y0..<y1 {
                    for x in x0..<x1 {
                        let offset = (y * width + x) * 4
                        if abs(Int(bytes[offset]) - Int(previous.bytes[offset])) > 10
                            || abs(Int(bytes[offset + 1]) - Int(previous.bytes[offset + 1])) > 10
                            || abs(Int(bytes[offset + 2]) - Int(previous.bytes[offset + 2])) > 10 {
                            changed = true
                            break rows
                        }
                    }
                }
                if changed {
                    regions.append(CGRect(x: CGFloat(x0) / CGFloat(width), y: CGFloat(y0) / CGFloat(height),
                        width: CGFloat(x1 - x0) / CGFloat(width), height: CGFloat(y1 - y0) / CGFloat(height)))
                }
            }
        }
        return regions
    }
}

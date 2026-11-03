import AppKit
import LineLensCore

/// CPU pixel analysis and AppKit drawing run synchronously on this actor, away from
/// UI events. No NSView, window or shared graphics context crosses the actor boundary.
struct OverlayPatch: Sendable {
    let id: UUID
    let rect: CGRect
    let image: CGImage
}

actor OverlayImageRenderer {
    private struct PatchKey: Hashable {
        let source: String
        let translation: String
        let style: String
        let fingerprint: UInt64
        let width: Int
        let height: Int
        let geometry: [Double]
        let fontSize: Double
    }
    private var patchCache: [PatchKey: CGImage] = [:]
    private(set) var renderedPatchCount = 0
    private(set) var cacheHitCount = 0

    func renderPatches(image: CGImage, pointSize: CGSize, blocks: [TextBlock], style: OverlayStyle) throws -> [OverlayPatch] {
        var patches: [OverlayPatch] = []
        let pixelBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let bounds = CGRect(origin: .zero, size: pointSize)
        guard pointSize.width > 0, pointSize.height > 0 else { return [] }
        let sx = pixelBounds.width / pointSize.width, sy = pixelBounds.height / pointSize.height
        for block in blocks {
            try Task.checkCancellation()
            let translated = block.translation?.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = translated.flatMap { $0.isEmpty ? nil : $0 } ?? (style == .cover ? "…" : "")
            guard !text.isEmpty, text != block.source else { continue }
            let source = CaptureGeometry.resolve(block.rect, in: bounds).intersection(bounds)
            guard !source.isNull, source.width > 1, source.height > 1 else { continue }
            if style == .below {
                let width = min(max(source.width, 140), max(1, bounds.maxX - source.minX))
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byWordWrapping
                let measured = (text as NSString).boundingRect(with: CGSize(width: max(1, width - 8), height: 120),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 12), .paragraphStyle: paragraph])
                let height = min(bounds.height, ceil(measured.height) + 8)
                let rect = CGRect(x: source.minX, y: min(source.maxY + 3, bounds.maxY - height), width: width, height: height)
                let pw = max(1, Int(ceil(width * sx))), ph = max(1, Int(ceil(height * sy)))
                let key = PatchKey(source: block.source, translation: text, style: style.rawValue, fingerprint: 0,
                    width: pw, height: ph, geometry: [Double(width), Double(height)], fontSize: 12)
                let rendered: CGImage
                if let cached = patchCache[key] { rendered = cached; cacheHitCount += 1 }
                else {
                    guard let context = makeContext(width: pw, height: ph) else { continue }
                    context.translateBy(x: 0, y: CGFloat(ph)); context.scaleBy(x: sx, y: -sy)
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                    NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
                    NSBezierPath(roundedRect: CGRect(origin: .zero, size: rect.size), xRadius: 4, yRadius: 4).fill()
                    drawFitted(text, in: CGRect(origin: .zero, size: rect.size).insetBy(dx: 4, dy: 4), preferredSize: 12, color: .white)
                    NSGraphicsContext.restoreGraphicsState()
                    guard let result = context.makeImage() else { continue }
                    rendered = result
                    cache(result, for: key)
                }
                patches.append(OverlayPatch(id: block.id, rect: CGRect(x: rect.minX / bounds.width, y: rect.minY / bounds.height,
                    width: rect.width / bounds.width, height: rect.height / bounds.height), image: rendered))
                continue
            }
            let cropRect = CGRect(x: source.minX * sx, y: source.minY * sy, width: source.width * sx, height: source.height * sy)
                .insetBy(dx: -sx, dy: -sy).integral.intersection(pixelBounds)
            guard let crop = image.cropping(to: cropRect) else { continue }
            let normalized = CGRect(x: cropRect.minX / pixelBounds.width, y: cropRect.minY / pixelBounds.height,
                width: cropRect.width / pixelBounds.width, height: cropRect.height / pixelBounds.height)
            func local(_ rect: CGRect) -> CGRect {
                CGRect(x: (rect.minX - normalized.minX) / normalized.width, y: (rect.minY - normalized.minY) / normalized.height,
                       width: rect.width / normalized.width, height: rect.height / normalized.height)
            }
            var adjusted = block
            adjusted.rect = local(block.rect)
            adjusted.lines = block.lines.map { TextLine(text: $0.text, rect: local($0.rect), confidence: $0.confidence) }
            let size = CGSize(width: cropRect.width / sx, height: cropRect.height / sy)
            let geometry = [Double(size.width), Double(size.height)] + adjusted.lines.flatMap {
                [Double($0.rect.minX), Double($0.rect.minY), Double($0.rect.width), Double($0.rect.height)]
            }
            let key = PatchKey(source: block.source, translation: text, style: style.rawValue, fingerprint: ImageFingerprint.make(crop),
                width: crop.width, height: crop.height, geometry: geometry, fontSize: Double(block.fontSizeHint ?? -1))
            let rendered: CGImage
            if let cached = patchCache[key] { rendered = cached; cacheHitCount += 1 }
            else {
                guard let result = try render(image: crop, pointSize: size, blocks: [adjusted], style: style) else { continue }
                rendered = result
                cache(result, for: key)
            }
            patches.append(OverlayPatch(id: block.id, rect: normalized, image: rendered))
        }
        return patches
    }

    private func cache(_ image: CGImage, for key: PatchKey) {
        if patchCache.count >= 256 { patchCache.removeAll(keepingCapacity: true) }
        patchCache[key] = image
        renderedPatchCount += 1
    }

    private func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    }

    func render(image: CGImage, pointSize: CGSize, blocks: [TextBlock], style: OverlayStyle) throws -> CGImage? {
        try Task.checkCancellation()
        guard pointSize.width > 0, pointSize.height > 0,
              let pixels = ImagePixels(image),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        let pixelBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.clear(pixelBounds)
        if style == .cover {
            // Cover newly arriving source text too; pending labels below use an
            // ellipsis instead of exposing untranslated text or freezing the old UI.
            context.draw(image, in: pixelBounds)
        }
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: CGFloat(image.width) / pointSize.width, y: -CGFloat(image.height) / pointSize.height)
        let bounds = CGRect(origin: .zero, size: pointSize)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        for block in blocks {
            try Task.checkCancellation()
            let translated = block.translation?.trimmingCharacters(in: .whitespacesAndNewlines)
            let text: String
            if let translated, !translated.isEmpty { text = translated }
            else if style == .cover { text = "…" }
            else { continue }
            guard text != block.source else { continue }
            let source = CaptureGeometry.resolve(block.rect, in: bounds).intersection(bounds)
            guard !source.isNull, source.width > 1, source.height > 1 else { continue }
            let lines = block.lines.isEmpty ? [block.rect] : block.lines.map(\.rect)
            let lineRects = lines.map { CaptureGeometry.resolve($0, in: bounds).intersection(bounds) }
                .filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
            guard !lineRects.isEmpty else { continue }
            if style == .below {
                drawCaption(text, below: source, in: bounds)
                continue
            }

            let appearance = pixels.appearance(around: lineRects, pointSize: pointSize)
            // Erase individual lines only. Paragraph gaps, icons, dividers and pixels
            // outside the OCR line boxes retain the original captured image.
            context.setFillColor(appearance.background.cgColor)
            for line in lineRects {
                let padded = line.insetBy(dx: -1, dy: -1).intersection(bounds)
                context.fill(padded)
            }
            let lineHeight = lineRects.map(\.height).sorted()[lineRects.count / 2]
            let preferredSize = max(9, min(48, block.fontSizeHint ?? lineHeight * 1.1))
            drawFitted(text, in: source.insetBy(dx: -1, dy: -1).intersection(bounds),
                       preferredSize: preferredSize, color: appearance.foreground)
        }
        try Task.checkCancellation()
        return context.makeImage()
    }

    private func drawFitted(_ text: String, in rect: CGRect, preferredSize: CGFloat, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        var size = preferredSize
        var attributes: [NSAttributedString.Key: Any] = [:]
        var measured = CGRect.zero
        repeat {
            attributes = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: paragraph]
            measured = (text as NSString).boundingRect(with: CGSize(width: rect.width, height: 10_000),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
            if ceil(measured.height) <= rect.height && ceil(measured.width) <= rect.width || size <= 9 { break }
            size = max(9, size - 0.5)
        } while true
        // Constrain drawing to the original text area rather than covering adjacent controls.
        let drawRect = CGRect(x: rect.minX, y: rect.minY + max(0, (rect.height - ceil(measured.height)) / 2),
                              width: rect.width, height: rect.height)
        NSGraphicsContext.current?.cgContext.saveGState()
        NSGraphicsContext.current?.cgContext.clip(to: rect)
        (text as NSString).draw(with: drawRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine], attributes: attributes)
        NSGraphicsContext.current?.cgContext.restoreGState()
    }

    private func drawCaption(_ text: String, below source: CGRect, in bounds: CGRect) {
        let width = min(max(source.width, 140), max(1, bounds.maxX - source.minX))
        let font = NSFont.systemFont(ofSize: 12)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
        let measured = (text as NSString).boundingRect(with: CGSize(width: max(1, width - 8), height: 120),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
        let height = min(bounds.height, ceil(measured.height) + 8)
        let rect = CGRect(x: source.minX, y: min(source.maxY + 3, bounds.maxY - height), width: width, height: height)
        NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        drawFitted(text, in: rect.insetBy(dx: 4, dy: 4), preferredSize: 12, color: .white)
    }
}

private struct SampleColor {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat

    var color: NSColor { NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1) }
    var bucket: Int { (Int(red) / 16) << 8 | (Int(green) / 16) << 4 | Int(blue) / 16 }
    func distance(to other: SampleColor) -> CGFloat {
        abs(red - other.red) + abs(green - other.green) + abs(blue - other.blue)
    }
}

private extension ImagePixels {
    func sample(x: Int, y: Int) -> SampleColor {
        let offset = (min(height - 1, max(0, y)) * width + min(width - 1, max(0, x))) * 4
        return SampleColor(red: CGFloat(bytes[offset]), green: CGFloat(bytes[offset + 1]), blue: CGFloat(bytes[offset + 2]))
    }

    func appearance(around lines: [CGRect], pointSize: CGSize) -> (background: NSColor, foreground: NSColor) {
        let scaleX = CGFloat(width) / pointSize.width
        let scaleY = CGFloat(height) / pointSize.height
        let rects = lines.map { CGRect(x: $0.minX * scaleX, y: $0.minY * scaleY,
                                      width: $0.width * scaleX, height: $0.height * scaleY) }
        var surrounding: [SampleColor] = []
        var inside: [SampleColor] = []
        for rect in rects {
            let x0 = max(0, Int(rect.minX)), x1 = min(width - 1, Int(ceil(rect.maxX)))
            let y0 = max(0, Int(rect.minY)), y1 = min(height - 1, Int(ceil(rect.maxY)))
            guard x0 <= x1, y0 <= y1 else { continue }
            let margin = max(2, Int(ceil(scaleY * 2)))
            let step = max(1, (x1 - x0) / 200)
            for x in stride(from: x0, through: x1, by: step) {
                for y in [max(0, y0 - margin), min(height - 1, y1 + margin)] {
                    if !rects.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) {
                        surrounding.append(sample(x: x, y: y))
                    }
                }
            }
            for y in stride(from: y0, through: y1, by: max(1, (y1 - y0) / 40)) {
                surrounding.append(sample(x: x0 - 3, y: y))
                surrounding.append(sample(x: x1 + 3, y: y))
                for x in stride(from: x0, through: x1, by: step) { inside.append(sample(x: x, y: y)) }
            }
        }
        let background = dominant(surrounding) ?? SampleColor(red: 32, green: 32, blue: 32)
        let contrasting = inside.filter { $0.distance(to: background) > 100 }
        let foreground = dominant(contrasting)
        let fallback: NSColor = background.red * 0.2126 + background.green * 0.7152 + background.blue * 0.0722 > 140 ? .black : .white
        return (background.color, foreground?.color ?? fallback)
    }

    func dominant(_ colors: [SampleColor]) -> SampleColor? {
        let groups = Dictionary(grouping: colors, by: \.bucket)
        guard let group = groups.max(by: { $0.value.count < $1.value.count })?.value, !group.isEmpty else { return nil }
        let count = CGFloat(group.count)
        return SampleColor(red: group.reduce(0) { $0 + $1.red } / count,
                           green: group.reduce(0) { $0 + $1.green } / count,
                           blue: group.reduce(0) { $0 + $1.blue } / count)
    }
}


/// Snapshot export/debugging only. Live presentation sends source + small cached
/// patches to separate Core Animation layers without composing a full CGImage.
enum OverlaySnapshotComposer {
    static func compose(source: CGImage, patches: [OverlayPatch]) -> CGImage? {
        guard let context = CGContext(data: nil, width: source.width, height: source.height,
            bitsPerComponent: 8, bytesPerRow: source.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        context.draw(source, in: bounds)
        for patch in patches {
            let rect = CaptureGeometry.resolve(patch.rect, in: bounds)
            context.draw(patch.image, in: CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height))
        }
        return context.makeImage()
    }
}

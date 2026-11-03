// Reproducible vector drawing for the macOS app icon; no external assets needed.
import AppKit

func drawIcon() {
    let tile = NSBezierPath(roundedRect: CGRect(x: 80, y: 80, width: 864, height: 864), xRadius: 194, yRadius: 194)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.22)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor.systemBlue.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.16, green: 0.27, blue: 0.91, alpha: 1),
        NSColor(srgbRed: 0.06, green: 0.49, blue: 0.98, alpha: 1),
        NSColor(srgbRed: 0.25, green: 0.73, blue: 1, alpha: 1),
    ])!
    gradient.draw(in: tile, angle: 70)
    NSColor.white.withAlphaComponent(0.3).setStroke()
    tile.lineWidth = 3
    tile.stroke()

    NSGraphicsContext.saveGraphicsState()
    let glyphShadow = NSShadow()
    glyphShadow.shadowColor = NSColor(srgbRed: 0.03, green: 0.22, blue: 0.64, alpha: 0.25)
    glyphShadow.shadowBlurRadius = 8
    glyphShadow.shadowOffset = NSSize(width: 0, height: -4)
    glyphShadow.set()
    NSColor.white.setStroke()
    let corners = NSBezierPath()
    corners.lineWidth = 46
    corners.lineCapStyle = .round
    corners.lineJoinStyle = .round
    corners.move(to: CGPoint(x: 270, y: 660))
    corners.line(to: CGPoint(x: 270, y: 720))
    corners.curve(to: CGPoint(x: 310, y: 760), controlPoint1: CGPoint(x: 270, y: 746), controlPoint2: CGPoint(x: 284, y: 760))
    corners.line(to: CGPoint(x: 370, y: 760))
    corners.move(to: CGPoint(x: 654, y: 760))
    corners.line(to: CGPoint(x: 714, y: 760))
    corners.curve(to: CGPoint(x: 754, y: 720), controlPoint1: CGPoint(x: 740, y: 760), controlPoint2: CGPoint(x: 754, y: 746))
    corners.line(to: CGPoint(x: 754, y: 660))
    corners.move(to: CGPoint(x: 754, y: 364))
    corners.line(to: CGPoint(x: 754, y: 304))
    corners.curve(to: CGPoint(x: 714, y: 264), controlPoint1: CGPoint(x: 754, y: 278), controlPoint2: CGPoint(x: 740, y: 264))
    corners.line(to: CGPoint(x: 654, y: 264))
    corners.move(to: CGPoint(x: 370, y: 264))
    corners.line(to: CGPoint(x: 310, y: 264))
    corners.curve(to: CGPoint(x: 270, y: 304), controlPoint1: CGPoint(x: 284, y: 264), controlPoint2: CGPoint(x: 270, y: 278))
    corners.line(to: CGPoint(x: 270, y: 364))
    corners.stroke()
    NSColor.white.setFill()
    for (y, width) in [(584.0, 324.0), (496.0, 252.0), (408.0, 298.0)] {
        NSBezierPath(roundedRect: CGRect(x: 350, y: y, width: width, height: 32), xRadius: 16, yRadius: 16).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
}

func png(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "LineLens.Icon", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(size) / 1024)
    scale.concat()
    drawIcon()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "LineLens.Icon", code: 2)
    }
    return data
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources")
let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try png(size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
try png(size: 1024).write(to: resources.appendingPathComponent("AppIcon.png"))
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
print("Generated Resources/AppIcon.png and AppIcon.icns")

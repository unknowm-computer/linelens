import CoreGraphics

public enum CaptureGeometry {
    /// AppKit uses a bottom-left origin, while screen capture uses the main display's top-left.
    /// Do not use the union of all displays: monitors above the main display change that union.
    public static func flipScreenRect(_ rect: CGRect, mainDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainDisplayHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func normalizedCrop(_ selection: CGRect, in bounds: CGRect) -> CGRect? {
        let clipped = selection.intersection(bounds)
        guard !clipped.isNull, clipped.width >= 8, clipped.height >= 8,
              bounds.width > 0, bounds.height > 0 else { return nil }
        return CGRect(
            x: (clipped.minX - bounds.minX) / bounds.width,
            y: (clipped.minY - bounds.minY) / bounds.height,
            width: clipped.width / bounds.width,
            height: clipped.height / bounds.height
        )
    }

    public static func resolve(_ normalized: CGRect, in bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.minX + normalized.minX * bounds.width,
            y: bounds.minY + normalized.minY * bounds.height,
            width: normalized.width * bounds.width,
            height: normalized.height * bounds.height
        )
    }

    public static func appKitRect(_ normalized: CGRect, in bounds: CGRect) -> CGRect {
        let local = resolve(normalized, in: CGRect(origin: .zero, size: bounds.size))
        return CGRect(x: bounds.minX + local.minX, y: bounds.maxY - local.maxY,
                      width: local.width, height: local.height)
    }
}

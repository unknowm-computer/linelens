import Foundation

/// Identifies the image whose OCR and composition may be presented. A late render
/// must not become visible after the source changed, even if it later changes back.
public struct OverlayFrameState: Sendable {
    public private(set) var fingerprint: UInt64?
    public private(set) var revision = UUID()
    public private(set) var recognizedFingerprint: UInt64?

    public init() {}

    @discardableResult
    public mutating func observe(_ value: UInt64) -> Bool {
        guard fingerprint != value else { return false }
        fingerprint = value
        recognizedFingerprint = nil
        revision = UUID()
        return true
    }

    @discardableResult
    public mutating func acceptRecognition(_ value: UInt64) -> Bool {
        guard fingerprint == value else { return false }
        recognizedFingerprint = value
        return true
    }

    public var canPresent: Bool { fingerprint != nil && recognizedFingerprint == fingerprint }
}

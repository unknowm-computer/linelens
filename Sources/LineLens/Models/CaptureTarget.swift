import AppKit
import CoreVideo
import IOSurface
import LineLensCore

struct WindowChoice: Identifiable, Equatable, Sendable {
    let id: CGWindowID
    let processID: pid_t
    let application: String
    let title: String
    let frame: CGRect
    var label: String { application.isEmpty ? title : "\(application) — \(title)" }
}

enum CaptureTarget: Equatable, Sendable {
    case region(displayID: CGDirectDisplayID, rect: CGRect)
    case window(id: CGWindowID, processID: pid_t, title: String, crop: CGRect?)

    var title: String {
        switch self {
        case .region(_, let rect): "화면 영역 · \(Int(rect.width)) × \(Int(rect.height))"
        case .window(_, _, let title, let crop): crop == nil ? title : "\(title) · 일부 영역"
        }
    }
}

// The capture buffer is retained and read-only for its lifetime. Only the main
// actor installs its IOSurface in a layer; no code mutates its pixels.
final class CapturedSurface: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let surface: IOSurfaceRef
    let sequence: UInt64
    init?(buffer: CVPixelBuffer, sequence: UInt64 = 0) {
        guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return nil }
        self.buffer = buffer
        self.surface = surface
        self.sequence = sequence
    }
}

struct CapturedFrame: Sendable {
    let image: CGImage
    let fingerprint: UInt64
    var pixels: ImagePixels? = nil
    var sequence: UInt64 = 0
}

struct CapturedImage: Sendable {
    let image: CGImage
    let screenRect: CGRect
    let fingerprint: UInt64
    var pixels: ImagePixels? = nil
    var sequence: UInt64 = 0
}

enum LineLensError: LocalizedError {
    case permission, targetUnavailable, invalidRegion, noDisplay
    case unsupportedOCR, unsupportedTranslation, sameLanguage, captureTimedOut

    var errorDescription: String? {
        switch self {
        case .permission: "화면 기록 권한이 필요합니다. 시스템 설정에서 LineLens를 허용한 뒤 다시 시도해 주세요. 권한 적용에 앱 재실행이 필요할 수 있습니다."
        case .targetUnavailable: "선택한 창을 찾을 수 없습니다. 창이 닫혔거나 최소화되었는지 확인해 주세요."
        case .invalidRegion: "영역이 너무 작거나 화면 밖에 있습니다. 다시 선택해 주세요."
        case .noDisplay: "선택한 디스플레이를 찾을 수 없습니다. 영역을 다시 선택해 주세요."
        case .unsupportedOCR: "현재 macOS에서 지원하지 않는 OCR 언어입니다. 다른 언어를 선택해 주세요."
        case .unsupportedTranslation: "현재 기기에서 지원하지 않는 번역 언어 조합입니다."
        case .sameLanguage: "원문과 목표 언어가 같습니다. 목표 언어를 변경해 주세요."
        case .captureTimedOut: "화면 프레임을 받지 못했습니다. 대상 창을 확인하고 새로고침해 주세요."
        }
    }
}

import AppKit
import CoreImage
import CoreMedia
import OSLog
import ScreenCaptureKit

@MainActor
final class LiveCaptureSession {
    let target: CaptureTarget
    let screenRect: CGRect
    private var stream: SCStream?
    private var output: CaptureStreamOutput?
    private var latestFrame: CapturedFrame?
    var onFrame: ((CapturedFrame) -> Void)?
    var onPreview: ((CapturedSurface) -> Void)?
    var onUnavailable: (() -> Void)?
    private var failure: (any Error)?
    private var isStopped = false
    private let logger = Logger(subsystem: "com.linelens.app", category: "Capture")

    init(target: CaptureTarget, screenRect: CGRect) {
        self.target = target
        self.screenRect = screenRect
    }

    func start(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws {
        let output = CaptureStreamOutput(onPreview: { [weak self] surface in
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped else { return }
                self.onPreview?(surface)
            }
        }, onFrame: { [weak self] frame in
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped else { return }
                self.latestFrame = frame
                self.onFrame?(frame)
            }
        }, onError: { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped else { return }
                self.failure = error
                self.onUnavailable?()
            }
        }, onUnavailable: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped else { return }
                self.latestFrame = nil
                self.onUnavailable?()
            }
        })
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        self.output = output
        self.stream = stream
        try stream.addStreamOutput(output, type: .screen,
                                   sampleHandlerQueue: output.queue)
        do {
            try await stream.startCapture()
            guard !isStopped, !Task.isCancelled else {
                stop()
                throw CancellationError()
            }
            logger.notice("Live capture session started")
        } catch {
            stop()
            throw error
        }
    }

    func frame() async throws -> CapturedFrame {
        // The first frame is asynchronous; later reads reuse the latest completed frame.
        // Idle frames never discard the last image or cause a new capture session.
        for _ in 0..<100 {
            try Task.checkCancellation()
            guard !isStopped else { throw CancellationError() }
            if let failure { throw failure }
            if let latestFrame { return latestFrame }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw LineLensError.captureTimedOut
    }

    func stop() {
        if !isStopped { logger.notice("Live capture session stopped") }
        isStopped = true
        latestFrame = nil
        stream?.stopCapture { _ in }
    }
}

// Mutable analysis state is confined to queue. Retained capture buffers are read-only;
// only immutable pixels and surfaces cross to MainActor.
private final class CaptureStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.linelens.capture", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let onFrame: @Sendable (CapturedFrame) -> Void
    private let onPreview: @Sendable (CapturedSurface) -> Void
    // Accessed only on the serial sampleHandlerQueue.
    private var lastAnalysisTime: UInt64 = 0
    private var pendingBuffer: CVPixelBuffer?
    private var analysisScheduled = false
    private let onError: @Sendable (any Error) -> Void
    private let onUnavailable: @Sendable () -> Void

    init(onPreview: @escaping @Sendable (CapturedSurface) -> Void, onFrame: @escaping @Sendable (CapturedFrame) -> Void, onError: @escaping @Sendable (any Error) -> Void, onUnavailable: @escaping @Sendable () -> Void) {
        self.onFrame = onFrame
        self.onPreview = onPreview
        self.onError = onError
        self.onUnavailable = onUnavailable
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return }
        guard status == .complete else {
            if status == .blank || status == .suspended || status == .stopped {
                pendingBuffer = nil
                onUnavailable()
            }
            return
        }
        guard let buffer = sampleBuffer.imageBuffer else { return }
        if let surface = CapturedSurface(buffer: buffer) { onPreview(surface) }
        pendingBuffer = buffer
        let now = DispatchTime.now().uptimeNanoseconds
        if now - lastAnalysisTime >= 200_000_000 { analyzeLatest() }
        else if !analysisScheduled {
            analysisScheduled = true
            queue.asyncAfter(deadline: .init(uptimeNanoseconds: lastAnalysisTime + 200_000_000)) { [self] in
                analysisScheduled = false
                analyzeLatest()
            }
        }
    }

    private func analyzeLatest() {
        guard let buffer = pendingBuffer else { return }
        pendingBuffer = nil
        lastAnalysisTime = DispatchTime.now().uptimeNanoseconds
        let image = CIImage(cvPixelBuffer: buffer)
        guard let result = context.createCGImage(image, from: image.extent) else { return }
        let pixels = ImagePixels(result)
        onFrame(CapturedFrame(image: result, fingerprint: pixels?.fingerprint ?? ImageFingerprint.make(result), pixels: pixels))
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) { onError(error) }
}

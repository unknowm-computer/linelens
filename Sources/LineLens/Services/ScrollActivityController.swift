import Foundation
import LineLensCore

/// Observes input and a tiny sampled signature solely to decide when the screen
/// has settled. It never estimates displacement or moves translation layers.
@MainActor
final class ScrollActivityController {
    private var state = ScrollActivityState()
    private var task: Task<Void, Never>?
    private var lifetime = UUID()
    private var signature: [UInt8]?
    var isScrolling: Bool { state.isScrolling }
    var didStart: (() -> Void)?
    var didSettle: (() -> Void)?

    func note(_ interaction: ScrollInteraction) {
        guard isScrolling || interaction.delta != .zero || interaction.isBeginning else { return }
        let phase: ScrollInputPhase
        if interaction.isMomentum { phase = interaction.isEnding ? .momentumEnded : .momentum }
        else if interaction.isEnding { phase = .gestureEnded }
        else { phase = interaction.hasPhase ? .gesture : .wheel }
        if state.note(phase, at: ProcessInfo.processInfo.systemUptime) { didStart?() }
        schedule()
    }

    func observe(_ frame: CapturedFrame) {
        guard isScrolling, let pixels = frame.pixels else { return }
        // Existing capture pixels are sampled at 32x24. No additional CGImage,
        // full pixel conversion, OCR or image registration is requested here.
        var next: [UInt8] = []
        next.reserveCapacity(32 * 24)
        var changed = 0, changedRows = 0
        for row in 0..<24 {
            var rowChanged = false
            for column in 0..<32 {
                let x = min(pixels.width - 1, (column * 2 + 1) * pixels.width / 64)
                let y = min(pixels.height - 1, (row * 2 + 1) * pixels.height / 48)
                let offset = (y * pixels.width + x) * 4
                let red = Int(pixels.bytes[offset])
                let green = Int(pixels.bytes[offset + 1])
                let blue = Int(pixels.bytes[offset + 2])
                let value = UInt8((77 * red + 150 * green + 29 * blue) >> 8)
                let index = next.count
                if let signature, abs(Int(value) - Int(signature[index])) > 16 {
                    changed += 1
                    rowChanged = true
                }
                next.append(value)
            }
            if rowChanged { changedRows += 1 }
        }
        signature = next
        if changed > 15, changedRows >= 6 {
            state.observeMotion(at: ProcessInfo.processInfo.systemUptime)
            schedule()
        }
    }

    func reset() {
        task?.cancel()
        task = nil
        lifetime = UUID()
        state = ScrollActivityState()
        signature = nil
    }

    private func schedule() {
        task?.cancel()
        guard let deadline = state.deadline else { return }
        let token = lifetime
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.lifetime == token else { return }
            if self.state.settle(at: ProcessInfo.processInfo.systemUptime) {
                self.task = nil
                self.signature = nil
                self.didSettle?()
            } else { self.schedule() }
        }
    }
}

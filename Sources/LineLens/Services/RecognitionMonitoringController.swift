import Foundation

/// Periodic work exists only while an active recognition target needs it.
/// An idle app has no sleeping polling tasks waiting to wake it again.
@MainActor
final class RecognitionMonitoringController {
    private var refreshTask: Task<Void, Never>?
    private var overlayTask: Task<Void, Never>?
    private var refreshInterval: TimeInterval?
    private var overlayInterval: TimeInterval?
    var isRefreshing: Bool { refreshTask != nil }
    var isTrackingOverlay: Bool { overlayTask != nil }
    var onRefresh: (() -> Void)?
    var onOverlayUpdate: (() -> Void)?

    deinit {
        refreshTask?.cancel()
        overlayTask?.cancel()
    }

    func configure(refreshInterval: TimeInterval?, overlayInterval: TimeInterval?) {
        let refresh = validInterval(refreshInterval), overlay = validInterval(overlayInterval)
        if self.refreshInterval != refresh {
            refreshTask?.cancel()
            refreshTask = nil
            self.refreshInterval = refresh
            if let refresh {
                refreshTask = repeating(every: refresh) { [weak self] in self?.onRefresh?() }
            }
        }
        if self.overlayInterval != overlay {
            overlayTask?.cancel()
            overlayTask = nil
            self.overlayInterval = overlay
            if let overlay {
                overlayTask = repeating(every: overlay) { [weak self] in self?.onOverlayUpdate?() }
            }
        }
    }

    func stop() { configure(refreshInterval: nil, overlayInterval: nil) }

    private func validInterval(_ interval: TimeInterval?) -> TimeInterval? {
        guard let interval, interval.isFinite, interval > 0 else { return nil }
        return interval
    }

    private func repeating(every interval: TimeInterval, action: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                action()
            }
        }
    }
}

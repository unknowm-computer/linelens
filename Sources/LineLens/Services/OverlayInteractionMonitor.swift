import AppKit

struct ScrollInteraction: Sendable {
    let location: CGPoint
    let delta: CGPoint
    let isEnding: Bool
    let isMomentum: Bool
    let isBeginning: Bool
    var hasPhase: Bool = false
}

/// Observe completed mouse actions without consuming or forwarding their events.
/// Mouse monitoring needs no global keyboard/accessibility permission.
@MainActor
final class OverlayInteractionMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    var isRunning: Bool { globalMonitor != nil || localMonitor != nil }
    var onInteraction: ((CGPoint) -> Void)?
    var onScroll: ((ScrollInteraction) -> Void)?

    func start() {
        guard !isRunning else { return }
        let events: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp, .otherMouseUp, .scrollWheel]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        guard isRunning else { return }
        if event.type == .scrollWheel {
            onScroll?(ScrollInteraction(location: NSEvent.mouseLocation,
                delta: CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY),
                isEnding: event.phase.contains(.ended) || event.phase.contains(.cancelled)
                    || event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled),
                isMomentum: !event.momentumPhase.isEmpty,
                isBeginning: event.phase.contains(.began) || event.momentumPhase.contains(.began),
                hasPhase: !event.phase.isEmpty || !event.momentumPhase.isEmpty))
        } else { onInteraction?(NSEvent.mouseLocation) }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
}

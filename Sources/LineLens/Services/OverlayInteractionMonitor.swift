import AppKit

/// Observe completed mouse actions without consuming or forwarding their events.
/// Mouse monitoring needs no global keyboard/accessibility permission.
@MainActor
final class OverlayInteractionMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    var onInteraction: ((CGPoint) -> Void)?

    func start() {
        let events: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp, .otherMouseUp, .scrollWheel]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            MainActor.assumeIsolated { self?.onInteraction?(NSEvent.mouseLocation) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.onInteraction?(NSEvent.mouseLocation)
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
}

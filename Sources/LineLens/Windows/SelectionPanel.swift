import AppKit
import Carbon

/// Handles Escape only while a selection panel holds keyboard focus.
final class SelectionPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape),
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           let onCancel {
            onCancel()
            return
        }
        super.sendEvent(event)
    }

    static func focusSelection(in panels: [SelectionPanel]) {
        let pointer = NSEvent.mouseLocation
        (panels.first { $0.frame.contains(pointer) } ?? panels.first)?.makeKey()
    }
}

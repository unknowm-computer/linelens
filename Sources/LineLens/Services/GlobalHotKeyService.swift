import AppKit
import Carbon

@MainActor
final class GlobalHotKeyService {
    private var handler: EventHandlerRef?
    private var references: [EventHotKeyRef] = []
    var onCapture: (() -> Void)?
    var onStop: (() -> Void)?

    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                          EventParamType(typeEventHotKeyID), nil,
                                          MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr else { return status }
            let id = identifier.id
            let service = Unmanaged<GlobalHotKeyService>.fromOpaque(context).takeUnretainedValue()
            // Carbon delivers application hot-key events on the application's main event loop.
            MainActor.assumeIsolated {
                if id == 1 { service.onCapture?() } else if id == 2 { service.onStop?() }
            }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func configure(capture: KeyboardShortcut?, stop: KeyboardShortcut?) -> String? {
        references.forEach { UnregisterEventHotKey($0) }
        references.removeAll()
        var errors: [String] = []
        for (id, shortcut) in [(UInt32(1), capture), (UInt32(2), stop)] {
            guard let shortcut else { continue }
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                            EventHotKeyID(signature: 0x4C4C4E53, id: id),
                                            GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference { references.append(reference) }
            else { errors.append("\(shortcut.label) 단축키를 등록하지 못했습니다. 다른 키 조합을 지정해 주세요.") }
        }
        return errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    func shutdown() {
        references.forEach { UnregisterEventHotKey($0) }
        references.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}

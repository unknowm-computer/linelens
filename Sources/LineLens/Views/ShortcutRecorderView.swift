import AppKit
import Carbon
import SwiftUI

struct ShortcutRecorderView: View {
    let title: String
    let onSave: (KeyboardShortcut) -> Void
    let onCancel: () -> Void
    @State private var shortcut: KeyboardShortcut?
    @State private var message = "⌘, ⌃, ⌥ 중 하나 이상을 포함한 키 조합을 누르세요."

    var body: some View {
        VStack(spacing: 20) {
            Text(title).font(.headline)
            Text(shortcut?.label ?? "키 조합 입력 대기…").font(.system(size: 26, weight: .medium, design: .rounded))
            Text(message).font(.caption).foregroundStyle(.secondary)
            KeyRecorder { event in
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard event.keyCode != 53, !flags.intersection([.command, .control, .option]).isEmpty,
                      let key = event.charactersIgnoringModifiers, !key.isEmpty,
                      !CharacterSet.controlCharacters.contains(key.unicodeScalars.first!) else {
                    message = "Escape와 단독 키는 사용할 수 없습니다. 수정 키와 문자·숫자를 함께 누르세요."
                    return
                }
                var modifiers: UInt32 = 0
                if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
                if flags.contains(.control) { modifiers |= UInt32(controlKey) }
                if flags.contains(.option) { modifiers |= UInt32(optionKey) }
                if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
                shortcut = KeyboardShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: key)
                message = "저장하면 적용됩니다. 다른 앱과 겹치면 다른 조합을 선택해 주세요."
            }.frame(width: 1, height: 1)
            HStack {
                Button("닫기", action: onCancel)
                Spacer()
                Button("저장") { if let shortcut { onSave(shortcut) } }
                    .buttonStyle(.borderedProminent).disabled(shortcut == nil)
            }
        }.padding(24).frame(width: 400)
    }
}

private struct KeyRecorder: NSViewRepresentable {
    let onKey: (NSEvent) -> Void

    func makeNSView(context: Context) -> KeyRecorderNSView {
        let view = KeyRecorderNSView()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ nsView: KeyRecorderNSView, context: Context) { nsView.onKey = onKey }
}

private final class KeyRecorderNSView: NSView {
    var onKey: ((NSEvent) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
    override func keyDown(with event: NSEvent) { onKey?(event) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { onKey?(event); return true }
}

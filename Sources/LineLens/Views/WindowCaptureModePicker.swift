import SwiftUI

struct WindowCaptureModePicker: View {
    @Binding var selection: WindowCaptureMode?
    let defaultMode: WindowCaptureMode

    var body: some View {
        Picker("캡처 방식", selection: $selection) {
            Text("설정 기본값 · \(defaultMode.title)").tag(WindowCaptureMode?.none)
            ForEach(WindowCaptureMode.allCases) { mode in
                Text(mode.title).tag(Optional(mode))
            }
        }
        .pickerStyle(.menu)
    }
}

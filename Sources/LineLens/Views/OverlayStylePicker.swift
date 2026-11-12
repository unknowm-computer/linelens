import SwiftUI

struct OverlayStylePicker: View {
    @Binding private var selection: OverlayStyle?
    private let allowsDefault: Bool

    init(selection: Binding<OverlayStyle>) {
        _selection = Binding(get: { selection.wrappedValue }, set: { style in
            if let style { selection.wrappedValue = style }
        })
        allowsDefault = false
    }

    init(override: Binding<OverlayStyle?>) {
        _selection = override
        allowsDefault = true
    }

    var body: some View {
        Picker("화면 위 번역", selection: $selection) {
            if allowsDefault {
                Text("설정 기본값 사용").tag(OverlayStyle?.none)
            }
            ForEach(OverlayStyle.allCases) { style in
                Text(style.title).tag(Optional(style))
            }
        }
    }
}

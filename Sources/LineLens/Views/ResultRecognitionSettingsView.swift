import SwiftUI

struct ResultRecognitionSettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("텍스트 읽기").font(.headline)
            Form {
                Picker("읽기 방식", selection: Binding(get: { model.resultOptions.recognitionSource }, set: model.setResultRecognitionSource)) {
                    Text("설정 기본값 사용").tag(TextRecognitionSource?.none)
                    ForEach(TextRecognitionSource.allCases) { source in
                        Text(source.title).tag(Optional(source))
                    }
                }
                .pickerStyle(.menu)
            }
            Text("설정 기본값: \(model.settings.recognitionSource.title)")
                .font(.caption).foregroundStyle(.secondary)
            Text("앱 텍스트 우선은 프로그램의 글자를 직접 읽고, 사용할 수 없으면 OCR로 전환합니다. 화면 영역은 항상 OCR을 사용합니다.")
                .font(.caption).foregroundStyle(.secondary)
            Text("여기서 선택한 방식은 현재 인식에만 적용됩니다. 인식을 해제하면 설정 기본값으로 돌아갑니다.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("완료") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

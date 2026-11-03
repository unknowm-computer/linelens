import SwiftUI

struct ResultLanguageSettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("인식·번역 언어").font(.headline)
            Form {
                Picker("인식 언어", selection: Binding(get: { model.recognitionLanguage }, set: model.setRecognitionLanguage)) {
                    if model.recognitionLanguage == RecognitionLanguages.customSelection {
                        Text("설정에서 개별 지정").tag(RecognitionLanguages.customSelection).disabled(true)
                    }
                    Text("자동 감지").tag("auto")
                    ForEach(model.recognitionLanguages) { Text(languageName($0.id)).tag($0.id) }
                }
                TranslationTargetLanguagePicker(target: $model.settings.targetLanguage,
                    supportedLanguages: model.translation.supportedLanguages)
            }
            .pickerStyle(.menu)
            Text("인식 언어는 OCR과 번역 원문에 함께 적용됩니다. 설정 창에서는 각각 지정할 수 있습니다.")
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

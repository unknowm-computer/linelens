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
                TranslationTargetLanguagePicker(target: Binding(get: { model.recognitionSettings.targetLanguage }, set: model.setResultTargetLanguage),
                    supportedLanguages: model.translation.supportedLanguages)
            }
            .pickerStyle(.menu)
            Text("인식 언어는 OCR과 번역 원문에 함께 적용됩니다. 여기서 선택한 언어는 현재 인식에만 적용되며 설정 기본값은 바뀌지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("설정 기본값 사용") { model.resetResultLanguages() }
                    .disabled(!model.resultOptions.hasLanguageOverrides)
                Spacer()
                Button("완료") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340)
        .task(id: model.settings.translationQuality) { await model.loadLanguageOptionsIfNeeded() }
    }
}

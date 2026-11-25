import SwiftUI

struct ResultLanguageSettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let settings = model.recognitionSettings
        let downloadedOnly = Binding(get: { model.recognitionSettings.downloadedTranslationLanguagesOnly },
            set: model.setResultDownloadedTranslationLanguagesOnly)
        TranslationLanguageFilter(downloadedOnly: settings.downloadedTranslationLanguagesOnly, settings: settings,
            languages: model.translation.supportedLanguages,
            sourceText: settings.downloadedTranslationLanguagesOnly && settings.sourceLanguage == "auto" ? model.sourceText : "") { choices, hint in
            languageSettings(choices: choices, hint: hint, downloadedOnly: downloadedOnly)
        }
        .padding(16)
        .frame(width: 340)
        .task(id: model.settings.translationQuality) { await model.loadLanguageOptionsIfNeeded() }
    }

    private func languageSettings(choices: TranslationEngine.LanguageChoices, hint: String?,
                                  downloadedOnly: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("인식·번역 언어").font(.headline)
                Spacer(minLength: 8)
                Toggle("다운로드한 언어만 표시", isOn: downloadedOnly)
                    .toggleStyle(.checkbox).controlSize(.small).font(.caption)
            }
            Form {
                let selection = model.recognitionLanguage
                Picker("인식 언어", selection: Binding(get: { model.recognitionLanguage }, set: model.setRecognitionLanguage)) {
                    if selection == RecognitionLanguages.customSelection {
                        Text("설정에서 개별 지정").tag(RecognitionLanguages.customSelection).disabled(true)
                    }
                    Text("자동 감지").tag("auto")
                    TranslationLanguageOptions(languages: model.recognitionLanguages.map(\.id).filter { choices.sources.contains($0) },
                        current: selection == "auto" || selection == RecognitionLanguages.customSelection ? nil : selection)
                }
                TranslationTargetLanguagePicker(target: Binding(get: { model.recognitionSettings.targetLanguage }, set: model.setResultTargetLanguage),
                    supportedLanguages: choices.targets)
            }
            .pickerStyle(.menu)
            if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
            Text("인식 언어는 OCR과 번역 원문에 함께 적용됩니다. 여기서 변경한 항목은 현재 인식에만 적용됩니다.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("설정 기본값 사용") { model.resetResultLanguages() }
                    .disabled(!model.resultOptions.hasLanguageOverrides)
                Spacer()
                Button("완료") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

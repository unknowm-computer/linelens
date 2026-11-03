import SwiftUI

struct OCRLanguagePicker: View {
    @Binding var language: String
    let supportedLanguages: [String]

    var body: some View {
        Picker("OCR 언어", selection: $language) {
            Text("자동 감지").tag("auto")
            ForEach(languages, id: \.self) { Text(languageName($0)).tag($0) }
        }
    }

    private var languages: [String] {
        Set(supportedLanguages + (language == "auto" ? [] : [language])).sorted()
    }
}

struct TranslationLanguagePickers: View {
    @Binding var source: String
    @Binding var target: String
    let supportedLanguages: [String]

    var body: some View {
        Picker("원문 언어", selection: $source) {
            Text("자동 감지").tag("auto")
            ForEach(languages, id: \.self) { Text(languageName($0)).tag($0) }
        }
        TranslationTargetLanguagePicker(target: $target, supportedLanguages: languages)
    }

    private var languages: [String] {
        // Preserve saved selections while the system language list is loading.
        Set(supportedLanguages + [target] + (source == "auto" ? [] : [source])).sorted()
    }
}

struct TranslationTargetLanguagePicker: View {
    @Binding var target: String
    let supportedLanguages: [String]

    var body: some View {
        Picker("목표 언어", selection: $target) {
            ForEach(Array(Set(supportedLanguages + [target])).sorted(), id: \.self) { Text(languageName($0)).tag($0) }
        }
    }
}

func languageName(_ identifier: String) -> String {
    Locale(identifier: "ko").localizedString(forIdentifier: identifier) ?? identifier
}

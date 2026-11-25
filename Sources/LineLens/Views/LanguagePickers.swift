import SwiftUI

struct OCRLanguagePicker: View {
    @Binding var language: String
    let supportedLanguages: [String]

    var body: some View {
        Picker("OCR 언어", selection: $language) {
            Text("자동 감지").tag("auto")
            TranslationLanguageOptions(languages: supportedLanguages, current: language == "auto" ? nil : language)
        }
    }
}

struct TranslationLanguagePickers: View {
    @Binding var source: String
    @Binding var target: String
    let choices: TranslationEngine.LanguageChoices

    var body: some View {
        Picker("원문 언어", selection: $source) {
            Text("자동 감지").tag("auto")
            TranslationLanguageOptions(languages: choices.sources, current: source == "auto" ? nil : source)
        }
        TranslationTargetLanguagePicker(target: $target, supportedLanguages: choices.targets)
    }
}

struct TranslationTargetLanguagePicker: View {
    @Binding var target: String
    let supportedLanguages: [String]

    var body: some View {
        Picker("목표 언어", selection: $target) {
            TranslationLanguageOptions(languages: supportedLanguages, current: target)
        }
    }
}

struct TranslationLanguageOptions: View {
    let languages: [String]
    let current: String?

    var body: some View {
        if let current, !languages.contains(current) {
            Text("\(languageName(current)) (현재 선택)").tag(current).disabled(true)
        }
        ForEach(languages, id: \.self) { Text(languageName($0)).tag($0) }
    }
}

struct TranslationLanguageFilter<Content: View>: View {
    let downloadedOnly: Bool
    let settings: AppSettings
    let languages: [String]
    var sourceText = ""
    var includeInstalledLanguages = false
    @ViewBuilder let content: (TranslationEngine.LanguageChoices, String?) -> Content
    @State private var loaded: (query: Query, choices: TranslationEngine.LanguageChoices)?

    private struct Query: Equatable {
        let source: String
        let target: String
        let languages: [String]
        let quality: TranslationQuality
    }

    private var query: Query? {
        guard downloadedOnly else { return nil }
        return Query(source: TranslationEngine.resolvedSourceLanguage(settings.sourceLanguage, context: sourceText),
            target: settings.targetLanguage, languages: languages, quality: settings.translationQuality)
    }

    var body: some View {
        let query = query
        let downloaded = loaded.flatMap { $0.query == query ? $0.choices : nil }
        let choices = downloadedOnly
            ? downloaded ?? TranslationEngine.LanguageChoices()
            : TranslationEngine.LanguageChoices(sources: languages, targets: languages)
        let hint = query.map { query in
            downloaded.map { filterHint($0, automaticSource: query.source == "auto") }
                ?? "다운로드한 언어를 확인하는 중…"
        }
        content(choices, hint)
            .task(id: query) {
                loaded = nil
                guard let query, !query.languages.isEmpty else { return }
                let choices = await TranslationEngine.downloadedLanguageChoices(source: query.source,
                    target: query.target, languages: query.languages, quality: query.quality,
                    includeInstalledLanguages: includeInstalledLanguages)
                guard !Task.isCancelled else { return }
                loaded = (query, choices)
            }
    }

    private func filterHint(_ choices: TranslationEngine.LanguageChoices, automaticSource: Bool) -> String {
        if choices.sources.isEmpty && choices.targets.isEmpty {
            return "현재 선택과 조합할 수 있는 다운로드된 언어가 없습니다. 전체 목록을 보려면 이 옵션을 끄세요."
        }
        if automaticSource {
            return "원문을 감지하기 전에는 다운로드된 조합이 하나 이상 있는 목표 언어를 표시합니다."
        }
        return "현재 원문·목표 언어와 조합할 수 있는 다운로드된 언어를 표시합니다."
    }
}

func languageName(_ identifier: String) -> String {
    Locale(identifier: "ko").localizedString(forIdentifier: identifier) ?? identifier
}

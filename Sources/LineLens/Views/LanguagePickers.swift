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

struct TranslationLanguageFilter<Header: View, Content: View>: View {
    @Binding var downloadedOnly: Bool
    let settings: AppSettings
    let languages: [String]
    var sourceText = ""
    @ViewBuilder let header: (Toggle<Text>) -> Header
    @ViewBuilder let content: (TranslationEngine.LanguageChoices) -> Content
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
        header(Toggle("다운로드한 언어만 표시", isOn: $downloadedOnly))
            .task(id: query) {
                loaded = nil
                guard let query, !query.languages.isEmpty else { return }
                let choices = await TranslationEngine.downloadedLanguageChoices(source: query.source,
                    target: query.target, languages: query.languages, quality: query.quality)
                guard !Task.isCancelled else { return }
                loaded = (query, choices)
            }
        content(choices)
        if let query {
            if let downloaded {
                Text(filterHint(downloaded, automaticSource: query.source == "auto"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("다운로드한 언어를 확인하는 중…")
                    .font(.caption).foregroundStyle(.secondary)
            }
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

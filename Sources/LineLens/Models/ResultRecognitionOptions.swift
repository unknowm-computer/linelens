/// In-memory choices for the current recognition session. AppSettings remains
/// the persisted default; stopping recognition discards these overrides.
struct ResultRecognitionOptions: Equatable {
    var recognitionSource: TextRecognitionSource?
    var recognitionLanguage: RecognitionLanguages.Option?
    var targetLanguage: String?

    var hasLanguageOverrides: Bool { recognitionLanguage != nil || targetLanguage != nil }

    func applying(to defaults: AppSettings) -> AppSettings {
        var effective = defaults
        if let recognitionSource { effective.recognitionSource = recognitionSource }
        if let recognitionLanguage {
            effective.ocrLanguage = recognitionLanguage.ocrLanguage
            effective.sourceLanguage = recognitionLanguage.id
        }
        if let targetLanguage { effective.targetLanguage = targetLanguage }
        return effective
    }
}

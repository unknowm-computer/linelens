import Foundation

enum RecognitionLanguages {
    static let customSelection = "custom"

    struct Option: Identifiable, Equatable {
        let id: String
        let ocrLanguage: String
    }

    /// Vision uses regional identifiers (en-US, ko-KR), while Translation often
    /// uses a language alone (en, ko). Match scripts too so Chinese variants stay distinct.
    static func options(ocrLanguages: [String], translationLanguages: [String]) -> [Option] {
        let ocr = Array(Set(ocrLanguages)).sorted()
        return Set(translationLanguages).sorted().compactMap { identifier in
            let language = Locale.Language(identifier: identifier)
            let candidates = ocr.filter {
                let candidate = Locale.Language(identifier: $0)
                return candidate.languageCode == language.languageCode && candidate.script == language.script
            }
            let matching = candidates.first { Locale.Language(identifier: $0).maximalIdentifier == language.maximalIdentifier }
                ?? candidates.first
            return matching.map { Option(id: identifier, ocrLanguage: $0) }
        }
    }

    static func selection(ocrLanguage: String, sourceLanguage: String, options: [Option]) -> String {
        if ocrLanguage == "auto", sourceLanguage == "auto" { return "auto" }
        let source = Locale.Language(identifier: sourceLanguage).minimalIdentifier
        return options.first {
            $0.ocrLanguage == ocrLanguage && Locale.Language(identifier: $0.id).minimalIdentifier == source
        }?.id ?? customSelection
    }
}

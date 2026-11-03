import Carbon
import Foundation

struct KeyboardShortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    var key: String

    var label: String {
        var prefix = ""
        if modifiers & UInt32(controlKey) != 0 { prefix += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { prefix += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { prefix += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { prefix += "⌘" }
        return prefix + key.uppercased()
    }

    static let capture = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_L),
                                          modifiers: UInt32(controlKey | optionKey), key: "L")
}

enum ResultPresentation: String, CaseIterable, Codable, Identifiable {
    case panel, overlay, both
    var id: String { rawValue }
    var title: String {
        switch self { case .panel: "결과 창"; case .overlay: "번역 화면"; case .both: "둘 다" }
    }
}

enum OverlayStyle: String, CaseIterable, Codable, Identifiable {
    case cover, below
    var id: String { rawValue }
    var title: String { self == .cover ? "이미지 속 글자 바꾸기" : "원문 아래 번역 상자" }
}

enum OCRMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case fast, accurate
    var id: String { rawValue }
    var title: String { self == .fast ? "빠른 OCR" : "정확한 OCR" }
}

enum TranslationQuality: String, CaseIterable, Codable, Identifiable, Sendable {
    case speed, quality
    var id: String { rawValue }
    var title: String { self == .speed ? "속도 우선" : "품질 우선" }
}

enum TextRecognitionSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic, ocr
    var id: String { rawValue }
    var title: String { self == .automatic ? "자동 · 앱 텍스트 우선" : "화면 OCR" }
}

struct AppSettings: Codable, Equatable {
    var translationEnabled = true
    var ocrLanguage = "auto"
    var ocrMode: OCRMode = .fast
    var recognitionSource: TextRecognitionSource = .automatic
    var translationQuality: TranslationQuality = .speed
    var livePreview = true
    var sourceLanguage = "auto"
    var targetLanguage = "ko"
    var automaticRefresh = true
    var refreshInterval: Double = 2
    var presentation: ResultPresentation = .overlay
    var overlayStyle: OverlayStyle = .cover
    var pinResults = true
    var captureShortcut: KeyboardShortcut? = .capture
    var stopShortcut: KeyboardShortcut?

    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "settings"),
              let settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "settings") }
    }
}

// Decode new preferences independently so adding settings never discards saved
// language, shortcuts or display preferences from earlier releases.
extension AppSettings {
    private enum CodingKeys: String, CodingKey {
        case translationEnabled, ocrLanguage, ocrMode, recognitionSource, translationQuality, livePreview
        case sourceLanguage, targetLanguage, automaticRefresh, refreshInterval, presentation, overlayStyle
        case pinResults, captureShortcut, stopShortcut
    }

    init(from decoder: any Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        translationEnabled = try values.decodeIfPresent(Bool.self, forKey: .translationEnabled) ?? translationEnabled
        ocrLanguage = try values.decodeIfPresent(String.self, forKey: .ocrLanguage) ?? ocrLanguage
        ocrMode = (try values.decodeIfPresent(String.self, forKey: .ocrMode)).flatMap(OCRMode.init(rawValue:)) ?? .fast
        recognitionSource = (try values.decodeIfPresent(String.self, forKey: .recognitionSource)).flatMap(TextRecognitionSource.init(rawValue:)) ?? .automatic
        translationQuality = (try values.decodeIfPresent(String.self, forKey: .translationQuality)).flatMap(TranslationQuality.init(rawValue:)) ?? .speed
        livePreview = try values.decodeIfPresent(Bool.self, forKey: .livePreview) ?? livePreview
        sourceLanguage = try values.decodeIfPresent(String.self, forKey: .sourceLanguage) ?? sourceLanguage
        targetLanguage = try values.decodeIfPresent(String.self, forKey: .targetLanguage) ?? targetLanguage
        automaticRefresh = try values.decodeIfPresent(Bool.self, forKey: .automaticRefresh) ?? automaticRefresh
        refreshInterval = try values.decodeIfPresent(Double.self, forKey: .refreshInterval) ?? refreshInterval
        presentation = try values.decodeIfPresent(ResultPresentation.self, forKey: .presentation) ?? presentation
        overlayStyle = try values.decodeIfPresent(OverlayStyle.self, forKey: .overlayStyle) ?? overlayStyle
        pinResults = try values.decodeIfPresent(Bool.self, forKey: .pinResults) ?? pinResults
        // Legacy encoders omitted nil shortcuts in otherwise complete settings.
        if values.contains(.captureShortcut) || values.contains(.translationEnabled) {
            captureShortcut = try values.decodeIfPresent(KeyboardShortcut.self, forKey: .captureShortcut)
        }
        stopShortcut = try values.decodeIfPresent(KeyboardShortcut.self, forKey: .stopShortcut)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(translationEnabled, forKey: .translationEnabled)
        try values.encode(ocrLanguage, forKey: .ocrLanguage)
        try values.encode(ocrMode, forKey: .ocrMode)
        try values.encode(recognitionSource, forKey: .recognitionSource)
        try values.encode(translationQuality, forKey: .translationQuality)
        try values.encode(livePreview, forKey: .livePreview)
        try values.encode(sourceLanguage, forKey: .sourceLanguage)
        try values.encode(targetLanguage, forKey: .targetLanguage)
        try values.encode(automaticRefresh, forKey: .automaticRefresh)
        try values.encode(refreshInterval, forKey: .refreshInterval)
        try values.encode(presentation, forKey: .presentation)
        try values.encode(overlayStyle, forKey: .overlayStyle)
        try values.encode(pinResults, forKey: .pinResults)
        // Explicit null distinguishes an intentionally removed shortcut from a new setting.
        try values.encode(captureShortcut, forKey: .captureShortcut)
        try values.encode(stopShortcut, forKey: .stopShortcut)
    }
}

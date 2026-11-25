import Foundation

/// Query installed translation assets only while automatic OCR is in use.
/// Reuse the result across frames without adding an idle timer or loading UI.
actor OCRLanguagePreferences {
    typealias Loader = @Sendable (String, TranslationQuality) async throws -> [String]

    private struct Snapshot {
        let target: String
        let quality: TranslationQuality
        let languages: [String]
        let loadedAt: ContinuousClock.Instant
    }

    private let load: Loader
    private let cacheLifetime: Duration
    private var snapshot: Snapshot?

    init(cacheLifetime: Duration = .seconds(30), load: @escaping Loader = { target, quality in
        try await TranslationEngine.downloadedOCRLanguages(target: target, quality: quality)
    }) {
        self.cacheLifetime = cacheLifetime
        self.load = load
    }

    func languages(target: String, quality: TranslationQuality, forceRefresh: Bool = false) async throws -> [String] {
        try Task.checkCancellation()
        if !forceRefresh, let snapshot, snapshot.target == target, snapshot.quality == quality,
           snapshot.loadedAt.duration(to: .now) < cacheLifetime {
            return snapshot.languages
        }
        let languages = try await load(target, quality)
        try Task.checkCancellation()
        snapshot = Snapshot(target: target, quality: quality, languages: languages, loadedAt: .now)
        return languages
    }
}

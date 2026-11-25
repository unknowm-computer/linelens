import Foundation
import LineLensCore
import NaturalLanguage
import Observation
// TranslationSession lacks Sendable annotations in the macOS 15 API. Each session is
// used sequentially within its translationTask and is never stored or shared between tasks.
@preconcurrency import Translation

@MainActor @Observable
final class TranslationEngine {
    struct LanguageChoices: Sendable {
        var sources: [String] = []
        var targets: [String] = []
        var installed: [String] = []
    }

    struct LanguagePair: Equatable {
        let source: String
        let target: String
        let quality: TranslationQuality
    }

    private struct Job {
        var id = UUID()
        var allowsDownload = false
        let blocks: [TextBlock]
        let languages: LanguagePair
        let preserved: [UUID: String]
        let completion: ([UUID: String]) -> Void
    }

    var configuration: TranslationSession.Configuration?
    var isWorking = false
    var message: String?
    private(set) var downloadOffer: LanguagePair?
    var supportedLanguages: [String] = []
    var needsPresentation: (() -> Void)?
    var didFinish: (() -> Void)?
    private var job: Job?
    private var lastConfiguration: TranslationSession.Configuration?
    private var cache: [String: String] = [:]
    private var languageLoadID = UUID()

    func loadLanguages(quality: TranslationQuality = .speed) async {
        let token = UUID()
        languageLoadID = token
        let languages = await Self.availableLanguages(quality: quality)
        if token == languageLoadID { supportedLanguages = languages }
    }

    private nonisolated static func availableLanguages(quality: TranslationQuality) async -> [String] {
        let availability = makeAvailability(quality: quality)
        let languages = await availability.supportedLanguages
        return languages.map(\.minimalIdentifier).sorted()
    }

    nonisolated static func downloadedOCRLanguages(target: String, quality: TranslationQuality) async throws -> [String] {
        let availability = makeAvailability(quality: quality)
        let targetLanguage = Locale.Language(identifier: target)
        var installed: [String] = []
        for language in await availability.supportedLanguages {
            try Task.checkCancellation()
            if await availability.status(from: language, to: targetLanguage) == .installed {
                installed.append(language.minimalIdentifier)
            }
        }
        // Same-language translation is unsupported. An installed pairing also
        // establishes that its target assets are present; keep target text legible.
        if !installed.isEmpty { installed.append(targetLanguage.minimalIdentifier) }
        return Array(Set(installed)).sorted()
    }

    nonisolated static func downloadedLanguageChoices(
        source: String, target: String, languages: [String], quality: TranslationQuality,
        includeInstalledLanguages: Bool = false
    ) async -> LanguageChoices {
        let availability = makeAvailability(quality: quality)
        return await downloadedLanguageChoices(source: source, target: target, languages: languages,
            includeInstalledLanguages: includeInstalledLanguages) { source, target in
                await availability.status(from: source, to: target) == .installed
            }
    }

    nonisolated static func downloadedLanguageChoices(
        source: String, target: String, languages: [String], includeInstalledLanguages: Bool,
        isInstalled: (Locale.Language, Locale.Language) async -> Bool
    ) async -> LanguageChoices {
        struct Pair: Hashable {
            let source: Locale.Language
            let target: Locale.Language
        }
        let candidates = languages.map { Locale.Language(identifier: $0) }
        let selectedTarget = Locale.Language(identifier: target)
        let possibleSources = source == "auto" ? candidates : [Locale.Language(identifier: source)]
        var choices = LanguageChoices()
        var checkedPairs: [Pair: Bool] = [:]
        var installedLanguages = Set<Locale.Language>()

        func checkPair(from source: Locale.Language, to target: Locale.Language) async -> Bool {
            guard !Task.isCancelled, source != target else { return false }
            let pair = Pair(source: source, target: target)
            if let checked = checkedPairs[pair] { return checked }
            let installed = await isInstalled(source, target)
            checkedPairs[pair] = installed
            if installed {
                installedLanguages.insert(source)
                installedLanguages.insert(target)
            }
            return installed
        }
        for (identifier, candidate) in zip(languages, candidates) {
            guard !Task.isCancelled else { return LanguageChoices() }
            if await checkPair(from: candidate, to: selectedTarget) {
                choices.sources.append(identifier)
            }
        }
        // With no sample for automatic detection, a target is selectable if it
        // already has at least one installed source pairing.
        for (identifier, candidate) in zip(languages, candidates) {
            for possibleSource in possibleSources {
                guard !Task.isCancelled else { return LanguageChoices() }
                if await checkPair(from: possibleSource, to: candidate) {
                    choices.targets.append(identifier)
                    break
                }
            }
        }
        if includeInstalledLanguages {
            // OCR can use either end of an installed pair, regardless of the
            // current translation source and target. Reuse the checks above.
            for candidate in candidates where !installedLanguages.contains(candidate) {
                for other in candidates {
                    guard !Task.isCancelled else { return LanguageChoices() }
                    if await checkPair(from: candidate, to: other) { break }
                    if await checkPair(from: other, to: candidate) { break }
                }
            }
            choices.installed = languages.filter { installedLanguages.contains(Locale.Language(identifier: $0)) }
        }
        return choices
    }

    func cancel() {
        job = nil
        configuration = nil
        isWorking = false
        message = nil
        downloadOffer = nil
    }

    func requestLanguageDownload() {
        guard !isWorking, var pending = job, downloadOffer == pending.languages else { return }
        pending.id = UUID()
        pending.allowsDownload = true
        start(pending)
    }

    func submit(blocks: [TextBlock], settings: AppSettings, sourceContext: String? = nil, completion: @escaping ([UUID: String]) -> Void) {
        guard !blocks.isEmpty else { cancel(); return }
        // A changing label such as "Page 124" may be the only cache miss. Detect
        // from the whole screen so an isolated short label cannot switch languages.
        let preservedBlocks = blocks.filter { Self.canPreserve($0.source, target: settings.targetLanguage) }
        let preserved = Dictionary(uniqueKeysWithValues: preservedBlocks.map { ($0.id, $0.source) })
        let translatable = blocks.filter { preserved[$0.id] == nil }
        guard !translatable.isEmpty else {
            cancel()
            completion(preserved)
            return
        }
        var source = Self.resolvedSourceLanguage(settings.sourceLanguage,
            context: sourceContext ?? translatable.map(\.source).joined(separator: "\n"))
        if settings.sourceLanguage == "auto", Self.languageCode(source) == Self.languageCode(settings.targetLanguage) {
            source = Self.resolvedSourceLanguage("auto", context: translatable.map(\.source).joined(separator: "\n"))
        }
        let languages = LanguagePair(source: source, target: settings.targetLanguage, quality: settings.translationQuality)
        let next = Job(blocks: translatable, languages: languages, preserved: preserved, completion: completion)
        var cached = preserved
        for block in translatable {
            if let value = cache[cacheKey(block.source, job: next)] { cached[block.id] = value }
        }
        if cached.count == blocks.count {
            // A newly recognized layout has new identifiers and coordinates.
            // Reuse text immediately without starting another system session.
            cancel()
            completion(cached)
            return
        }
        start(next)
    }

    private func start(_ next: Job) {
        if downloadOffer != next.languages { downloadOffer = nil }
        if downloadOffer == nil || next.allowsDownload { message = nil }
        job = next
        isWorking = true
        var config = Self.makeConfiguration(source: next.languages.source, target: next.languages.target, quality: next.languages.quality)
        if let old = lastConfiguration, old.source == config.source, old.target == config.target {
            let sameStrategy: Bool
            if #available(macOS 26.4, *) { sameStrategy = old.preferredStrategy == config.preferredStrategy }
            else { sameStrategy = true }
            if sameStrategy { config = old; config.invalidate() }
        }
        lastConfiguration = config
        configuration = config
    }

    func run(using session: TranslationSession) async {
        await run(checkAvailability: Self.languageStatus,
                  prepare: { try await session.prepareTranslation() },
                  translate: { session.translate(batch: $0) })
    }

    func run(
        checkAvailability: (LanguagePair) async -> LanguageAvailability.Status,
        prepare: () async throws -> Void,
        translate: ([TranslationSession.Request]) throws -> TranslationSession.BatchResponse
    ) async {
        guard let current = job, isWorking else { return }
        defer {
            if job?.id == current.id {
                configuration = nil
                isWorking = false
                didFinish?()
            }
        }
        var requestedDownload = false
        do {
            var values = current.preserved
            let pending = current.blocks.filter { block in
                if let cached = cache[cacheKey(block.source, job: current)] { values[block.id] = cached; return false }
                return true
            }
            if !values.isEmpty { current.completion(values) }
            if !pending.isEmpty {
                guard current.languages.source != "auto" else {
                    message = "원문 언어를 감지하지 못했습니다. 결과 창에서 인식 언어를 선택해 주세요."
                    needsPresentation?()
                    return
                }
                let status = await checkAvailability(current.languages)
                guard isCurrent(current) else { return }
                switch status {
                case .unsupported: throw LineLensError.unsupportedTranslation
                case .supported:
                    let isNewOffer = downloadOffer != current.languages
                    downloadOffer = current.languages
                    guard current.allowsDownload else {
                        if isNewOffer || message == nil { message = "이 언어 조합을 번역하려면 모델 다운로드가 필요합니다." }
                        if isNewOffer { needsPresentation?() }
                        return
                    }
                    requestedDownload = true
                    message = "시스템 다운로드 안내를 확인해 주세요."
                    try await prepare()
                    try Task.checkCancellation()
                case .installed: break
                @unknown default: throw LineLensError.unsupportedTranslation
                }
                guard isCurrent(current) else { return }
                downloadOffer = nil
                message = nil
                let requests = pending.map { TranslationSession.Request(sourceText: $0.source, clientIdentifier: $0.id.uuidString) }
                var lastPublished = Date.distantPast
                for try await response in try translate(requests) {
                    guard isCurrent(current) else { return }
                    if let identifier = response.clientIdentifier, let id = UUID(uuidString: identifier) {
                        values[id] = response.targetText
                        if cache.count >= 500 { cache.removeAll(keepingCapacity: true) }
                        cache[cacheKey(response.sourceText, job: current)] = response.targetText
                        if Date.now.timeIntervalSince(lastPublished) >= 0.1 {
                            current.completion(values)
                            lastPublished = .now
                        }
                    }
                }
            }
            guard isCurrent(current) else { return }
            current.completion(values)
            message = nil
        } catch {
            guard job?.id == current.id else { return }
            if requestedDownload {
                downloadOffer = current.languages
                if Task.isCancelled || error is CancellationError || (error as? CocoaError)?.code == .userCancelled {
                    message = "시스템 다운로드 창을 닫았습니다."
                } else {
                    message = "번역 모델을 준비하지 못했습니다. \(error.localizedDescription)"
                }
            } else if !Task.isCancelled {
                downloadOffer = nil
                message = "번역하지 못했습니다. \(error.localizedDescription) 원문은 계속 확인할 수 있습니다."
                needsPresentation?()
            }
        }
    }

    private nonisolated static func languageStatus(_ pair: LanguagePair) async -> LanguageAvailability.Status {
        await makeAvailability(quality: pair.quality).status(from: Locale.Language(identifier: pair.source),
                                                           to: Locale.Language(identifier: pair.target))
    }

    static var supportsQualitySelection: Bool {
        if #available(macOS 26.4, *) { return true }
        return false
    }

    static func makeConfiguration(source: String, target: String, quality: TranslationQuality) -> TranslationSession.Configuration {
        let sourceLanguage = source == "auto" ? nil : Locale.Language(identifier: source)
        let targetLanguage = Locale.Language(identifier: target)
        if #available(macOS 26.4, *) {
            return TranslationSession.Configuration(source: sourceLanguage, target: targetLanguage,
                preferredStrategy: quality == .speed ? .lowLatency : .highFidelity)
        }
        return TranslationSession.Configuration(source: sourceLanguage, target: targetLanguage)
    }

    private nonisolated static func makeAvailability(quality: TranslationQuality) -> LanguageAvailability {
        if #available(macOS 26.4, *) {
            return LanguageAvailability(preferredStrategy: quality == .speed ? .lowLatency : .highFidelity)
        }
        return LanguageAvailability()
    }

    static func resolvedSourceLanguage(_ language: String, context: String) -> String {
        guard language == "auto" else { return language }
        return NLLanguageRecognizer.dominantLanguage(for: context)?.rawValue ?? "auto"
    }

    private static func canPreserve(_ text: String, target: String) -> Bool {
        if text.rangeOfCharacter(from: .letters) == nil { return true }
        guard let detected = NLLanguageRecognizer.dominantLanguage(for: text) else { return false }
        return languageCode(detected.rawValue) == languageCode(target)
    }

    private static func languageCode(_ identifier: String) -> String {
        Locale.Language(identifier: identifier).languageCode?.identifier ?? identifier
    }

    private func isCurrent(_ value: Job) -> Bool { job?.id == value.id && !Task.isCancelled }
    private func cacheKey(_ text: String, job: Job) -> String {
        "\(job.languages.quality.rawValue)|\(job.languages.source)|\(job.languages.target)|\(text)"
    }
}

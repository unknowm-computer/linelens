import Foundation
import LineLensCore
import NaturalLanguage
import Observation
// TranslationSession lacks Sendable annotations in the macOS 15 API. Each session is
// used sequentially within its translationTask and is never stored or shared between tasks.
@preconcurrency import Translation

@MainActor @Observable
final class TranslationEngine {
    struct Job {
        let id = UUID()
        let blocks: [TextBlock]
        let source: String
        let target: String
        let quality: TranslationQuality
        let preserved: [UUID: String]
        let completion: ([UUID: String]) -> Void
    }

    var configuration: TranslationSession.Configuration?
    var isWorking = false
    var message: String?
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

    func cancel() {
        job = nil
        configuration = nil
        isWorking = false
        message = nil
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
        let next = Job(blocks: translatable, source: source, target: settings.targetLanguage, quality: settings.translationQuality,
                       preserved: preserved, completion: completion)
        job = next
        isWorking = true
        message = nil
        var config = Self.makeConfiguration(source: next.source, target: next.target, quality: next.quality)
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
        guard let current = job else { return }
        defer {
            if job?.id == current.id {
                isWorking = false
                didFinish?()
            }
        }
        do {
            var values = current.preserved
            let pending = current.blocks.filter { block in
                if let cached = cache[cacheKey(block.source, job: current)] { values[block.id] = cached; return false }
                return true
            }
            if !values.isEmpty { current.completion(values) }
            if !pending.isEmpty {
                let availability = Self.makeAvailability(quality: current.quality)
                let status: LanguageAvailability.Status
                if current.source == "auto" {
                    status = try await availability.status(for: pending.map(\.source).joined(separator: "\n"),
                                                           to: Locale.Language(identifier: current.target))
                } else {
                    status = await availability.status(from: Locale.Language(identifier: current.source),
                                                       to: Locale.Language(identifier: current.target))
                }
                guard isCurrent(current) else { return }
                switch status {
                case .unsupported: throw LineLensError.unsupportedTranslation
                case .supported:
                    message = "번역 언어 모델을 다운로드해야 합니다. 시스템 안내를 확인해 주세요."
                    needsPresentation?()
                    try await session.prepareTranslation()
                case .installed: break
                @unknown default: throw LineLensError.unsupportedTranslation
                }
                guard isCurrent(current) else { return }
                let requests = pending.map { TranslationSession.Request(sourceText: $0.source, clientIdentifier: $0.id.uuidString) }
                var lastPublished = Date.distantPast
                for try await response in session.translate(batch: requests) {
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
            isWorking = false
            message = nil
        } catch {
            guard job?.id == current.id else { return }
            isWorking = false
            if !Task.isCancelled {
                message = "번역하지 못했습니다. \(error.localizedDescription) 원문은 계속 확인할 수 있습니다."
                needsPresentation?()
            }
        }
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
    private func cacheKey(_ text: String, job: Job) -> String { "\(job.quality.rawValue)|\(job.source)|\(job.target)|\(text)" }
}

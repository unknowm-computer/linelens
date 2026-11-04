import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var checksAutomatically = false
    @Published private(set) var startupError: String?
    let isDevelopmentBuild: Bool

    private var controller: SPUStandardUpdaterController?
    private let isBundledApp: Bool
    private let automaticChecks: @MainActor () -> Bool
    private let makeController: @MainActor () throws -> SPUStandardUpdaterController
    private var configured = false
    private var started = false

    var isInitialized: Bool { controller != nil }

    init(isBundledApp: Bool = Bundle.main.bundleURL.pathExtension == "app",
         isDevelopmentBuild: Bool = Bundle.main.object(forInfoDictionaryKey: "LineLensDevelopmentBuild") as? Bool ?? false,
         automaticChecks: @escaping @MainActor () -> Bool = AppUpdater.savedAutomaticChecks,
         makeController: @escaping @MainActor () throws -> SPUStandardUpdaterController = {
             SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
         }) {
        self.isBundledApp = isBundledApp
        self.isDevelopmentBuild = isDevelopmentBuild
        self.automaticChecks = automaticChecks
        self.makeController = makeController
    }

    func start() {
        // A manual-only updater needs no Sparkle controller or notification
        // observers until the user actually checks or enables automatic checks.
        guard !configured, isBundledApp, !isDevelopmentBuild else { return }
        configured = true
        checksAutomatically = automaticChecks()
        if checksAutomatically { _ = startController() }
        else { canCheckForUpdates = true }
    }

    private func startController() -> Bool {
        guard !isDevelopmentBuild else { return false }
        if controller != nil { return started }
        do {
            let instance = try makeController()
            controller = instance
            instance.updater.publisher(for: \.canCheckForUpdates)
                .receive(on: DispatchQueue.main)
                .assign(to: &$canCheckForUpdates)
            instance.updater.publisher(for: \.automaticallyChecksForUpdates)
                .receive(on: DispatchQueue.main)
                .assign(to: &$checksAutomatically)
            try instance.updater.start()
            started = true
            startupError = nil
            canCheckForUpdates = instance.updater.canCheckForUpdates
            checksAutomatically = instance.updater.automaticallyChecksForUpdates
            return true
        } catch {
            startupError = error.localizedDescription
            canCheckForUpdates = false
            return false
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates, startController(), let controller,
              controller.updater.canCheckForUpdates else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    func setChecksAutomatically(_ enabled: Bool) {
        guard isBundledApp, startController(), let controller else { return }
        controller.updater.automaticallyChecksForUpdates = enabled
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
    }

    private static func savedAutomaticChecks() -> Bool {
        let domain = Bundle.main.object(forInfoDictionaryKey: "SUDefaultsDomain") as? String
        let defaults = domain.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        // Read Sparkle's own setting without introducing another preference.
        if defaults.object(forKey: "SUEnableAutomaticChecks") != nil {
            return defaults.bool(forKey: "SUEnableAutomaticChecks")
        }
        return Bundle.main.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool ?? false
    }

    var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }
}

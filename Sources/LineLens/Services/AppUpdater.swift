import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var checksAutomatically = false
    @Published private(set) var startupError: String?

    private let controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
    )
    private var started = false

    init() {
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$checksAutomatically)
    }

    func start() {
        // SwiftPM tests and `swift run` do not have the signed app's Info.plist.
        guard !started, Bundle.main.bundleURL.pathExtension == "app" else { return }
        do {
            try controller.updater.start()
            started = true
        } catch {
            startupError = error.localizedDescription
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    func setChecksAutomatically(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }
}

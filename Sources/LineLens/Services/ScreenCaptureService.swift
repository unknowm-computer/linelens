import AppKit
import LineLensCore
import Observation
import OSLog
import ScreenCaptureKit

enum ScreenAccessState: Equatable {
    case unchecked, checking, allowed, needsApproval, failed(String)
}

@MainActor @Observable
final class ScreenCaptureService {
    typealias WindowInfoProvider = (CGWindowListOption, CGWindowID) -> [[String: Any]]?
    typealias DisplayFramesProvider = @MainActor () -> [(id: CGDirectDisplayID, frame: CGRect)]

    private(set) var accessState: ScreenAccessState = .unchecked
    private let accessProbe: () async throws -> Void
    private let accessReset: () async throws -> Void
    private let windowInfoProvider: WindowInfoProvider
    private let displayFramesProvider: DisplayFramesProvider
    private let isWebBrowser: @MainActor (pid_t) -> Bool
    private var accessCheck: Task<Bool, Never>?
    private let logger = Logger(subsystem: "com.linelens.app", category: "ScreenAccess")
    private var lastPreflight: Bool?
    private(set) var isResettingAccess = false
    private(set) var requiresRelaunch = false
    private(set) var recoveryMessage: String?
    private(set) var diagnosticDetails = ""
    private var liveCapture: LiveCaptureSession?
    private var liveCaptureGeneration = UUID()
    var onFrame: ((CapturedFrame) -> Void)?
    var onPreview: ((CapturedSurface) -> Void)?
    var onUnavailable: (() -> Void)?

    var hasPermission: Bool { accessState == .allowed }
    var isCheckingAccess: Bool { accessState == .checking }

    init(accessProbe: @escaping () async throws -> Void = {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard !content.displays.isEmpty else { throw LineLensError.noDisplay }
    }, accessReset: @escaping () async throws -> Void = ScreenCaptureService.resetSystemPermission,
         windowInfoProvider: @escaping WindowInfoProvider = ScreenCaptureService.systemWindowInfo,
         displayFramesProvider: @escaping DisplayFramesProvider = ScreenCaptureService.systemDisplayFrames,
         isWebBrowser: @escaping @MainActor (pid_t) -> Bool = ScreenCaptureService.isBrowserApplication) {
        self.accessProbe = accessProbe
        self.accessReset = accessReset
        self.windowInfoProvider = windowInfoProvider
        self.displayFramesProvider = displayFramesProvider
        self.isWebBrowser = isWebBrowser
    }

    /// CoreGraphics preflight can disagree with ScreenCaptureKit after a permission or signing
    /// change. Test the API we actually use instead of blocking it on the preflight result.
    @discardableResult
    func verifyAccess() async -> Bool {
        guard !isResettingAccess, !requiresRelaunch else { return false }
        if let accessCheck { return await accessCheck.value }
        lastPreflight = CGPreflightScreenCaptureAccess()
        accessState = .checking
        let check = Task { @MainActor in
            do {
                try await accessProbe()
                accessState = .allowed
                diagnosticDetails = "ScreenCaptureKit: allowed; CoreGraphics: \(lastPreflight == true)"
                recoveryMessage = nil
                logger.notice("ScreenCaptureKit access allowed")
                return true
            } catch {
                recordAccessError(error)
                return false
            }
        }
        accessCheck = check
        let allowed = await check.value
        accessCheck = nil
        return allowed
    }

    func requestPermission() async {
        guard !requiresRelaunch else { return }
        CGRequestScreenCaptureAccess()
        await verifyAccess()
    }

    func recheckIfAuthorizationChanged() async {
        // Activation notifications are not user requests. Avoid repeatedly invoking an API
        // that can prompt when the OS authorization state hasn't changed.
        guard CGPreflightScreenCaptureAccess() != lastPreflight else { return }
        await verifyAccess()
    }

    @discardableResult
    func resetAccess() async -> Bool {
        guard !isResettingAccess else { return false }
        isResettingAccess = true
        defer { isResettingAccess = false }
        if let accessCheck { _ = await accessCheck.value }
        do {
            try await accessReset()
            accessState = .unchecked
            lastPreflight = nil
            requiresRelaunch = true
            diagnosticDetails = "LineLens ScreenCapture approval reset"
            recoveryMessage = "LineLens의 화면 기록 승인 연결을 초기화했습니다. 앱을 다시 실행하고 권한을 허용해 주세요."
            return true
        } catch {
            recoveryMessage = "승인 연결을 초기화하지 못했습니다. \(error.localizedDescription)"
            return false
        }
    }

    private nonisolated static func resetSystemPermission() async throws {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier, !bundleIdentifier.isEmpty else {
            throw NSError(domain: "LineLens.PermissionReset", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "현재 앱의 식별자를 확인할 수 없습니다."])
        }
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", "ScreenCapture", bundleIdentifier]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw NSError(domain: "LineLens.PermissionReset", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "시스템 권한 초기화에 실패했습니다." : message])
            }
        }.value
    }

    private func availableContent(onScreenWindowsOnly: Bool) async throws -> SCShareableContent {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: onScreenWindowsOnly)
            accessState = .allowed
            return content
        } catch {
            recordAccessError(error)
            throw error
        }
    }

    private func recordAccessError(_ error: any Error) {
        let nsError = error as NSError
        diagnosticDetails = "\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)\nCoreGraphics: \(CGPreflightScreenCaptureAccess())\nApp: \(Bundle.main.bundlePath)"
        logger.error("Screen access failed: \(nsError.domain, privacy: .public) code=\(nsError.code); preflight=\(CGPreflightScreenCaptureAccess())")
        if nsError.domain == SCStreamErrorDomain && nsError.code == SCStreamError.Code.userDeclined.rawValue {
            accessState = .needsApproval
        } else {
            accessState = .failed(error.localizedDescription)
        }
    }

    func windows() async throws -> [WindowChoice] {
        let content = try await availableContent(onScreenWindowsOnly: true)
        return content.windows.compactMap { window in
            // App-owned floating panels can contain text just like normal windows.
            // Menus and system overlays live at other levels and remain excluded.
            guard [0, NSWindow.Level.floating.rawValue].contains(window.windowLayer),
                  window.frame.width > 80, window.frame.height > 50,
                  let app = window.owningApplication, app.processID != ProcessInfo.processInfo.processIdentifier
            else { return nil }
            return WindowChoice(id: window.windowID, processID: app.processID,
                                application: app.applicationName,
                                title: window.title?.isEmpty == false ? window.title! : "제목 없는 창",
                                frame: window.frame)
        }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    func capture(_ selection: CaptureTarget, continuously: Bool = false,
                 windowMode: WindowCaptureMode = .direct) async throws -> CapturedImage {
        let target = try captureTarget(for: selection, windowMode: windowMode)
        // Display crops are tied to absolute screen coordinates. Never deliver a
        // frame from the old position after the selected window has moved.
        let isCurrent: () -> Bool = { [weak self] in
            guard let self else { return false }
            return (try? self.captureTarget(for: selection, windowMode: windowMode)) == target
        }
        if continuously {
            let visibleRect = availableFrame(for: target)
            if let liveCapture, liveCapture.target == target,
               visibleRect == nil || liveCapture.screenRect.size == visibleRect?.size {
                let token = liveCaptureGeneration
                do {
                    let frame = try await liveCapture.frame()
                    guard token == liveCaptureGeneration, isCurrent() else { throw CancellationError() }
                    return CapturedImage(image: frame.image, screenRect: visibleRect ?? liveCapture.screenRect, fingerprint: frame.fingerprint, pixels: frame.pixels, sequence: frame.sequence)
                } catch {
                    if token == liveCaptureGeneration { stopLiveCapture() }
                    throw error
                }
            }
            stopLiveCapture()
            let token = liveCaptureGeneration
            let setup = try await captureSetup(target)
            try Task.checkCancellation()
            guard token == liveCaptureGeneration else { throw CancellationError() }
            // Keep one session for the target. New frames are delivered only when available;
            // polling the latest image must not start/stop screen recording each time.
            setup.configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            setup.configuration.queueDepth = 3
            let session = LiveCaptureSession(target: target, screenRect: setup.screenRect)
            liveCapture = session
            session.onFrame = { [weak self] frame in
                guard let self, self.liveCaptureGeneration == token, isCurrent() else { return }
                self.onFrame?(frame)
            }
            session.onPreview = { [weak self] surface in
                guard let self, self.liveCaptureGeneration == token, isCurrent() else { return }
                self.onPreview?(surface)
            }
            session.onUnavailable = { [weak self] in
                guard let self, self.liveCaptureGeneration == token else { return }
                self.onUnavailable?()
            }
            do {
                try await session.start(filter: setup.filter, configuration: setup.configuration)
                guard token == liveCaptureGeneration else { session.stop(); throw CancellationError() }
                let frame = try await session.frame()
                guard token == liveCaptureGeneration, isCurrent() else { throw CancellationError() }
                return CapturedImage(image: frame.image, screenRect: setup.screenRect, fingerprint: frame.fingerprint, pixels: frame.pixels, sequence: frame.sequence)
            } catch {
                session.stop()
                if token == liveCaptureGeneration { liveCapture = nil }
                throw error
            }
        }
        stopLiveCapture()
        let setup = try await captureSetup(target)
        let image = try await SCScreenshotManager.captureImage(contentFilter: setup.filter, configuration: setup.configuration)
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        let pixels = ImagePixels(image)
        let fingerprint = pixels?.fingerprint ?? ImageFingerprint.make(image)
        onFrame?(CapturedFrame(image: image, fingerprint: fingerprint, pixels: pixels))
        return CapturedImage(image: image, screenRect: setup.screenRect, fingerprint: fingerprint, pixels: pixels)
    }

    func stopLiveCapture() {
        liveCaptureGeneration = UUID()
        liveCapture?.stop()
        liveCapture = nil
    }

    private func captureSetup(_ target: CaptureTarget) async throws -> (filter: SCContentFilter, configuration: SCStreamConfiguration, screenRect: CGRect) {
        let content = try await availableContent(onScreenWindowsOnly: false)
        try Task.checkCancellation()
        let filter: SCContentFilter
        let captureRect: CGRect
        let screenRect: CGRect
        switch target {
        case .region(let displayID, let rect):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw LineLensError.noDisplay
            }
            let clipped = rect.intersection(display.frame)
            guard !clipped.isNull, clipped.width >= 8, clipped.height >= 8 else { throw LineLensError.invalidRegion }
            let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            captureRect = clipped.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            screenRect = clipped
        case .window(let id, _, _, let crop):
            guard let window = content.windows.first(where: { $0.windowID == id }), window.isOnScreen else {
                throw LineLensError.targetUnavailable
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            let bounds = CGRect(origin: .zero, size: window.frame.size)
            captureRect = crop.map { CaptureGeometry.resolve($0, in: bounds) } ?? bounds
            screenRect = captureRect.offsetBy(dx: window.frame.minX, dy: window.frame.minY)
        }
        let config = SCStreamConfiguration()
        config.sourceRect = captureRect
        let scale = max(CGFloat(filter.pointPixelScale), 1)
        config.width = max(1, Int((captureRect.width * scale).rounded()))
        config.height = max(1, Int((captureRect.height * scale).rounded()))
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = true
        config.shouldBeOpaque = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        return (filter, config, screenRect)
    }

    /// Preserve the window selection (including its normalized crop), while
    /// resolving the display crop anew whenever its position or size changes.
    func captureTarget(for target: CaptureTarget, windowMode: WindowCaptureMode) throws -> CaptureTarget {
        guard case .window = target, windowMode == .screenRegion else { return target }
        guard let rect = availableFrame(for: target) else { throw LineLensError.targetUnavailable }
        let candidates = displayFramesProvider().compactMap { display -> (CGDirectDisplayID, CGRect)? in
            let clipped = rect.intersection(display.frame)
            guard !clipped.isNull, clipped.width >= 8, clipped.height >= 8 else { return nil }
            return (display.id, clipped)
        }
        guard let best = candidates.max(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height }) else {
            throw LineLensError.noDisplay
        }
        return .region(displayID: best.0, rect: best.1)
    }

    func visibleFrame(for target: CaptureTarget, windowMode: WindowCaptureMode = .direct) -> CGRect? {
        // An inactive window can remain fully visible beside the active app.
        // Actual overlap is checked separately by isOccluded, not by focus.
        if case .window = target, windowMode == .screenRegion {
            guard let resolved = try? captureTarget(for: target, windowMode: windowMode),
                  case .region(_, let rect) = resolved else { return nil }
            return rect
        }
        return availableFrame(for: target)
    }

    func isOccluded(_ target: CaptureTarget, rect: CGRect, overlayWindowID: Int?, resultWindowID: Int? = nil,
                    windowMode: WindowCaptureMode = .direct) -> Bool {
        overlayExclusions(for: target, rect: rect, overlayWindowID: overlayWindowID, resultWindowID: resultWindowID,
                          windowMode: windowMode)?.isEmpty != true
    }

    /// Returns the screen rectangles to leave visible. An unavailable or covered
    /// target returns nil, so the overlay cannot obscure other windows.
    func overlayExclusions(for target: CaptureTarget, rect: CGRect, overlayWindowID: Int?, resultWindowID: Int? = nil,
                           excludeBrowserLinkStatus: Bool = false, windowMode: WindowCaptureMode = .direct) -> [CGRect]? {
        guard let list = windowInfoProvider([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) else { return nil }
        let targetWindow: (number: Int, pid: pid_t, frame: CGRect, layer: Int)?
        if case .window(let id, let pid, _, _) = target {
            guard let info = list.first(where: { $0[kCGWindowNumber as String] as? Int == Int(id) }),
                  let frame = Self.onScreenFrame(info), let layer = info[kCGWindowLayer as String] as? Int else { return nil }
            // A tracked screen region already contains other apps and popups.
            // Only our excluded windows need the existing region visibility rule.
            targetWindow = windowMode == .direct ? (Int(id), pid, frame, layer) : nil
        } else {
            targetWindow = nil
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var exclusions: [CGRect] = []
        for info in list {
            guard let number = info[kCGWindowNumber as String] as? Int else { continue }
            if number == targetWindow?.number { return exclusions }
            if number == overlayWindowID || number == resultWindowID { continue }
            guard let layer = info[kCGWindowLayer as String] as? Int, layer >= 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let rawBounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: rawBounds),
                  frame.intersects(rect), frame.width > 1, frame.height > 1 else { continue }
            let pid = info[kCGWindowOwnerPID as String] as? pid_t
            if let pid,
               let app = NSRunningApplication(processIdentifier: pid),
               let bundle = app.bundleIdentifier,
               ["com.apple.dock", "com.apple.WindowManager", "com.apple.screencaptureui"].contains(bundle),
               !app.isActive {
                // These processes keep transparent, display-sized helper windows
                // on screen even when their visible UI is not being presented.
                continue
            }
            if let targetWindow {
                // Chrome displays the hovered link's address in a separate
                // strip attached to the bottom corner of the selected window.
                guard excludeBrowserLinkStatus, pid == targetWindow.pid, layer == targetWindow.layer,
                      Self.isBottomStatusWindow(frame, of: targetWindow.frame), isWebBrowser(targetWindow.pid) else { return nil }
                exclusions.append(frame.intersection(rect))
            } else {
                // Other apps are already part of a region capture. Our windows are
                // excluded from capture and must never be covered by its screenshot.
                if pid == ownPID { return nil }
            }
        }
        return targetWindow == nil ? exclusions : nil
    }

    private static func isBottomStatusWindow(_ frame: CGRect, of target: CGRect) -> Bool {
        let edgeTolerance: CGFloat = 4
        return frame.height <= 36 && frame.width <= target.width
            && abs(frame.maxY - target.maxY) <= edgeTolerance
            && (abs(frame.minX - target.minX) <= edgeTolerance || abs(frame.maxX - target.maxX) <= edgeTolerance)
    }

    private static func isBrowserApplication(_ pid: pid_t) -> Bool {
        guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL,
              let bundle = Bundle(url: url),
              let urlTypes = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]],
              let documentTypes = bundle.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] else { return false }
        let schemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }.map { $0.lowercased() }
        guard schemes.contains("http"), schemes.contains("https") else { return false }
        return documentTypes.contains { type in
            let identifiers = type["LSItemContentTypes"] as? [String] ?? []
            let extensions = type["CFBundleTypeExtensions"] as? [String] ?? []
            let mimeTypes = type["CFBundleTypeMIMETypes"] as? [String] ?? []
            return identifiers.contains("public.html") || extensions.contains("html") || mimeTypes.contains("text/html")
        }
    }

    /// Keep standard window title-bar controls and the system recording indicator live.
    /// Crops starting below the title bar need no exclusion.
    func overlayTopInset(for target: CaptureTarget, rect: CGRect) -> CGFloat {
        guard case .window(let id, _, _, _) = target,
              let frame = Self.onScreenFrame(windowInfoProvider([.optionIncludingWindow], id)?.first) else { return 0 }
        return min(rect.height, max(0, frame.minY + 32 - rect.minY))
    }

    func overlayLevel(for target: CaptureTarget) -> NSWindow.Level {
        guard case .window(let id, _, _, _) = target,
              let list = windowInfoProvider([.optionIncludingWindow], id),
              let layer = list.first?[kCGWindowLayer as String] as? Int else { return .floating }
        return NSWindow.Level(rawValue: max(NSWindow.Level.floating.rawValue, layer + 1))
    }

    /// On-screen membership, not activation, determines availability. Minimized,
    /// closed and off-space windows remain unavailable; overlap is checked separately.
    func availableFrame(for target: CaptureTarget) -> CGRect? {
        switch target {
        case .region(let id, let rect):
            return NSScreen.screens.contains { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id } ? rect : nil
        case .window(let id, _, _, let crop):
            guard let frame = Self.onScreenFrame(windowInfoProvider([.optionIncludingWindow], id)?.first) else { return nil }
            return crop.map { CaptureGeometry.resolve($0, in: frame) } ?? frame
        }
    }

    static func windowFrame(id: CGWindowID) -> CGRect? {
        onScreenFrame(systemWindowInfo([.optionIncludingWindow], id)?.first)
    }

    private static func systemDisplayFrames() -> [(id: CGDirectDisplayID, frame: CGRect)] {
        NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return (id, CGDisplayBounds(id))
        }
    }

    private nonisolated static func systemWindowInfo(_ options: CGWindowListOption, _ id: CGWindowID) -> [[String: Any]]? {
        CGWindowListCopyWindowInfo(options, id) as? [[String: Any]]
    }

    private static func onScreenFrame(_ info: [String: Any]?) -> CGRect? {
        guard let info,
              info[kCGWindowIsOnscreen as String] as? Bool == true,
              let rawBounds = info[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: rawBounds),
              frame.width > 0, frame.height > 0 else { return nil }
        return frame
    }
}

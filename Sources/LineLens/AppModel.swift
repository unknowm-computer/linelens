import AppKit
import LineLensCore
import Observation
import OSLog

@MainActor @Observable
final class AppModel {
    var settings = AppSettings.load() {
        didSet {
            settings.save()
            guard settings != oldValue else { return }
            applyConfigurationChanges(from: resultOptions.applying(to: oldValue))
        }
    }
    private(set) var resultOptions = ResultRecognitionOptions()
    var recognitionSettings: AppSettings { resultOptions.applying(to: settings) }
    var target: CaptureTarget?
    var blocks: [TextBlock] = []
    var isSelecting = false
    var isPaused = false
    var isCapturing = false
    var status = "영역이나 프로그램 창을 선택해 주세요."
    var errorMessage: String?
    var hotKeyError: String?
    var lastUpdated: Date?
    var ocrLanguages: [String] = []
    let translation = TranslationEngine()
    let capture = ScreenCaptureService()
    let accessibility = AccessibilityAccess()
    let updater = AppUpdater()
    let launchAtLogin = LaunchAtLoginService()
    private var ocr: OCRService
    private let accessibleText = AccessibilityTextService()
    private let imageOverlay: ImageOverlaySession
    private let interactions = OverlayInteractionMonitor()
    private let monitoring = RecognitionMonitoringController()
    private let scrollActivity = ScrollActivityController()
    private(set) var isScrolling = false
    private(set) var isWaitingForScrollTranslation = false
    private var hasFreshScrollRecognition = false
    private var interactionRefreshTask: Task<Void, Never>?
    private var needsTranslation = false
    private var languageOptionsTask: Task<Void, Never>?
    private var languageOptionsID: UUID?
    private var loadedLanguageQuality: TranslationQuality?
    private let hotKeys = GlobalHotKeyService()
    private let recognitionLogger = Logger(subsystem: "com.linelens.app", category: "Recognition")
    private var fingerprint: UInt64?
    private var usedAppText = false
    private var generation = UUID()
    private var captureTask: Task<Void, Never>?
    private var permissionAction = UUID()
    private var needsRefresh = false
    private var lastCaptureRect: CGRect?
    private var lastVisibleRect: CGRect?
    private(set) var windowsController: AppWindows?

    init() {
        let stabilizer = OCRFrameStabilizer()
        ocr = OCRService(stabilizer: stabilizer)
        imageOverlay = ImageOverlaySession(stabilizer: stabilizer)
    }

    var hasTarget: Bool { target != nil }
    var isRefreshMonitoringActive: Bool { monitoring.isRefreshing }
    var isOverlayMonitoringActive: Bool { monitoring.isTrackingOverlay }
    var isInputMonitoringActive: Bool { interactions.isRunning }
    var sourceText: String { blocks.map(\.source).joined(separator: "\n\n") }
    var translatedText: String { blocks.compactMap(\.translation).joined(separator: "\n\n") }

    var recognitionLanguages: [RecognitionLanguages.Option] {
        RecognitionLanguages.options(ocrLanguages: ocrLanguages, translationLanguages: translation.supportedLanguages)
    }

    var recognitionLanguage: String {
        RecognitionLanguages.selection(ocrLanguage: recognitionSettings.ocrLanguage, sourceLanguage: recognitionSettings.sourceLanguage,
            options: recognitionLanguages)
    }

    func setRecognitionLanguage(_ identifier: String) {
        var next = resultOptions
        if identifier == "auto" {
            next.recognitionLanguage = RecognitionLanguages.Option(id: "auto", ocrLanguage: "auto")
        } else {
            guard let option = recognitionLanguages.first(where: { $0.id == identifier }) else { return }
            next.recognitionLanguage = option
        }
        // Apply both values together so capture and translation restart only once.
        setResultOptions(next)
    }

    func setResultRecognitionSource(_ source: TextRecognitionSource?) {
        var next = resultOptions
        next.recognitionSource = source
        setResultOptions(next)
    }

    func setResultTargetLanguage(_ identifier: String) {
        guard !identifier.isEmpty else { return }
        var next = resultOptions
        next.targetLanguage = identifier
        setResultOptions(next)
    }

    func resetResultLanguages() {
        var next = resultOptions
        next.recognitionLanguage = nil
        next.targetLanguage = nil
        setResultOptions(next)
    }

    private func setResultOptions(_ next: ResultRecognitionOptions) {
        guard resultOptions != next else { return }
        let previous = recognitionSettings
        resultOptions = next
        applyConfigurationChanges(from: previous)
    }

    private func applyConfigurationChanges(from previous: AppSettings) {
        let current = recognitionSettings
        guard current != previous else { return }
        if current.captureShortcut != previous.captureShortcut || current.stopShortcut != previous.stopShortcut {
            configureHotKeys()
        }
        windowsController?.updateResultLevel()
        if current.presentation != previous.presentation {
            if current.presentation == .overlay { windowsController?.hideResults() }
            else { showResults() }
        }
        let recognitionChanged = current.ocrLanguage != previous.ocrLanguage || current.ocrMode != previous.ocrMode
            || current.recognitionSource != previous.recognitionSource
        if recognitionChanged || current.automaticRefresh != previous.automaticRefresh
            || current.presentation != previous.presentation || current.livePreview != previous.livePreview {
            cancelWork()
            fingerprint = nil
            if hasTarget { requestRefresh() }
        }
        if current.translationEnabled != previous.translationEnabled
            || current.sourceLanguage != previous.sourceLanguage || current.targetLanguage != previous.targetLanguage
            || current.translationQuality != previous.translationQuality {
            if current.ocrLanguage != previous.ocrLanguage, hasTarget, !isPaused, !isSelecting {
                // Wait for fresh OCR before translating under the new language.
                for index in blocks.indices { blocks[index].translation = nil }
            } else { translateCurrentBlocks() }
        }
        updateOverlay()
        updateRecognitionMonitoring()
    }

    func start() {
        guard windowsController == nil else { return }
        windowsController = AppWindows(model: self)
        updater.start()
        imageOverlay.didInvalidate = { [weak self] in
            guard let self, !self.isScrolling else { return }
            self.windowsController?.overlay.clear()
        }
        imageOverlay.didRender = { [weak self] in self?.updateOverlay() }
        capture.onFrame = { [weak self] frame in
            guard let self, self.hasTarget, !self.isPaused, !self.isSelecting else { return }
            self.scrollActivity.observe(frame)
            self.imageOverlay.observe(frame)
        }
        capture.onPreview = { [weak self] surface in
            guard let self, self.hasTarget, !self.isPaused, !self.isSelecting else { return }
            self.windowsController?.overlay.updateBackground(surface)
        }
        scrollActivity.didStart = { [weak self] in self?.beginScroll() }
        scrollActivity.didSettle = { [weak self] in self?.finishScroll() }
        imageOverlay.needsRecognition = { [weak self] in
            guard let self, self.settings.automaticRefresh else { return }
            self.requestRefresh()
        }
        capture.onUnavailable = { [weak self] in self?.imageOverlay.suspend() }
        translation.didFinish = { [weak self] in
            guard let self else { return }
            if self.needsTranslation {
                self.needsTranslation = false
                self.translateCurrentBlocks(clearExisting: false)
            }
            if self.needsRefresh {
                self.needsRefresh = false
                self.requestRefresh()
            }
        }
        interactions.onInteraction = { [weak self] point in self?.refreshAfterInteraction(at: point) }
        interactions.onScroll = { [weak self] event in self?.refreshAfterInteraction(at: event.location, scroll: event) }
        monitoring.onRefresh = { [weak self] in self?.requestRefresh() }
        monitoring.onOverlayUpdate = { [weak self] in self?.updateOverlay() }
        hotKeys.onCapture = { [weak self] in self?.selectRegion() }
        hotKeys.onStop = { [weak self] in self?.stop() }
        translation.needsPresentation = { [weak self] in self?.showResults() }
        configureHotKeys()
        Task {
            if !(await capture.verifyAccess()) { windowsController?.showWelcome() }
        }
        updateRecognitionMonitoring()
    }

    func shutdown() {
        stop()
        languageOptionsTask?.cancel()
        hotKeys.shutdown()
    }

    func loadLanguageOptionsIfNeeded() async {
        if let languageOptionsTask { await languageOptionsTask.value }
        guard !Task.isCancelled else { return }
        let quality = settings.translationQuality
        guard ocrLanguages.isEmpty || translation.supportedLanguages.isEmpty || loadedLanguageQuality != quality else { return }
        let id = UUID()
        let load = Task { [weak self] in
            guard let self else { return }
            if self.ocrLanguages.isEmpty { self.ocrLanguages = (try? await self.ocr.supportedLanguages()) ?? [] }
            guard !Task.isCancelled else { return }
            await self.translation.loadLanguages(quality: quality)
            guard !Task.isCancelled else { return }
            self.loadedLanguageQuality = quality
        }
        languageOptionsTask = load
        languageOptionsID = id
        await withTaskCancellationHandler {
            await load.value
        } onCancel: {
            load.cancel()
        }
        if languageOptionsID == id {
            languageOptionsTask = nil
            languageOptionsID = nil
        }
    }

    private func configureHotKeys() {
        hotKeyError = hotKeys.configure(capture: settings.captureShortcut, stop: settings.stopShortcut)
    }

    func selectRegion() {
        let action = UUID()
        permissionAction = action
        Task { [self] in
            guard await ensurePermission(), permissionAction == action else { return }
            beginSelection()
            windowsController?.selection.begin { [weak self] rect, displayID in
                self?.activate(.region(displayID: displayID, rect: rect))
            }
        }
    }

    func chooseWindow() {
        let action = UUID()
        permissionAction = action
        Task { [self] in
            guard await ensurePermission(), permissionAction == action else { return }
            beginSelection(status: "인식할 창을 클릭하세요. 선택 취소는 화면 위 버튼이나 메뉴에서 할 수 있습니다.")
            let token = generation
            do {
                let choices = try await capture.windows()
                guard isSelecting, generation == token else { return }
                guard !choices.isEmpty else {
                    cancelSelection()
                    errorMessage = "선택할 수 있는 창이 없습니다. 대상 프로그램을 연 뒤 다시 시도해 주세요."
                    showResults()
                    return
                }
                windowsController?.windowSelection.begin(windows: choices,
                    onSelect: { [weak self] window, crop in self?.selectWindow(window, crop: crop) },
                    onCancel: { [weak self] in self?.cancelSelection() },
                    onShowList: { [weak self] in self?.chooseWindowFromList() })
            } catch {
                guard isSelecting, generation == token else { return }
                cancelSelection()
                errorMessage = error.localizedDescription
                showResults()
            }
        }
    }

    func chooseWindowFromList() {
        let action = UUID()
        permissionAction = action
        Task {
            guard await ensurePermission(), permissionAction == action else { return }
            beginSelection(status: "목록에서 인식할 프로그램 창을 선택하세요.")
            windowsController?.showWindowPicker()
        }
    }

    func selectWindow(_ window: WindowChoice, crop: Bool) {
        if crop {
            beginSelection()
            let selectionToken = generation
            NSRunningApplication(processIdentifier: window.processID)?.activate()
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, self.isSelecting, self.generation == selectionToken else { return }
                let target = CaptureTarget.window(id: window.id, processID: window.processID, title: window.label, crop: nil)
                guard let frame = self.capture.visibleFrame(for: target) else {
                    self.isSelecting = false
                    self.errorMessage = LineLensError.targetUnavailable.localizedDescription
                    self.showResults()
                    if self.hasTarget { self.fingerprint = nil; self.requestRefresh() }
                    return
                }
                self.windowsController?.selection.begin(restrictingTo: frame) { [weak self] rect, _ in
                    guard let normalized = CaptureGeometry.normalizedCrop(rect, in: frame) else { return }
                    self?.activate(.window(id: window.id, processID: window.processID, title: window.label, crop: normalized))
                }
            }
        } else {
            activate(.window(id: window.id, processID: window.processID, title: window.label, crop: nil))
            NSRunningApplication(processIdentifier: window.processID)?.activate()
        }
    }

    func adjustRegion() {
        guard let target else { return }
        switch target {
        case .region(let displayID, let rect):
            beginSelection()
            windowsController?.selection.edit(rect: rect, displayID: displayID) { [weak self] rect, id in
                self?.activate(.region(displayID: id, rect: rect))
            }
        case .window(let id, let pid, let title, _):
            guard let frame = capture.visibleFrame(for: .window(id: id, processID: pid, title: title, crop: nil)) else {
                errorMessage = "대상 창을 화면 앞으로 가져온 뒤 다시 시도해 주세요."
                showResults()
                return
            }
            selectWindow(WindowChoice(id: id, processID: pid, application: "", title: title, frame: frame), crop: true)
        }
    }

    private func beginSelection(status: String = "드래그로 영역을 선택하세요. 취소는 메뉴 막대에서 할 수 있습니다.") {
        windowsController?.selection.cancel()
        windowsController?.windowSelection.cancel()
        windowsController?.overlay.hide()
        windowsController?.prepareForSelection()
        cancelWork()
        isSelecting = true
        errorMessage = nil
        self.status = status
    }

    func cancelSelection() {
        windowsController?.selection.cancel()
        windowsController?.windowSelection.cancel()
        windowsController?.closeWindowPicker()
        cancelWork()
        isSelecting = false
        status = target == nil ? "영역이나 프로그램 창을 선택해 주세요." : "선택을 취소했습니다."
        if hasTarget { fingerprint = nil; requestRefresh() }
        showResultsIfNeeded()
    }

    func activate(_ nextTarget: CaptureTarget) {
        windowsController?.selection.cancel()
        windowsController?.windowSelection.cancel()
        windowsController?.closeWindowPicker()
        cancelWork()
        target = nextTarget
        windowsController?.prepareForRecognition()
        isSelecting = false
        isPaused = false
        blocks = []
        errorMessage = nil
        fingerprint = nil
        lastUpdated = nil
        lastCaptureRect = nil
        lastVisibleRect = nil
        status = "인식 중…"
        showResultsIfNeeded()
        requestRefresh()
    }

    func stop() {
        cancelWork()
        target = nil
        resultOptions = ResultRecognitionOptions()
        blocks = []
        isPaused = false
        isSelecting = false
        fingerprint = nil
        lastCaptureRect = nil
        lastVisibleRect = nil
        lastUpdated = nil
        errorMessage = nil
        status = "인식을 해제했습니다."
        windowsController?.selection.cancel()
        windowsController?.windowSelection.cancel()
        windowsController?.closeWindowPicker()
        windowsController?.overlay.hide()
        windowsController?.releaseIdleResources()
    }

    func togglePause() {
        isPaused.toggle()
        if isPaused { cancelWork(); status = "일시정지됨"; windowsController?.overlay.hide() }
        else { fingerprint = nil; requestRefresh() }
    }

    private func cancelWork() {
        monitoring.stop()
        interactions.stop()
        scrollActivity.reset()
        isScrolling = false
        isWaitingForScrollTranslation = false
        hasFreshScrollRecognition = false
        capture.stopLiveCapture()
        interactionRefreshTask?.cancel()
        interactionRefreshTask = nil
        needsTranslation = false
        imageOverlay.reset()
        windowsController?.overlay.clear()
        permissionAction = UUID()
        generation = UUID()
        captureTask?.cancel()
        captureTask = nil
        isCapturing = false
        needsRefresh = false
        translation.cancel()
        ocr = OCRService(stabilizer: imageOverlay.stabilizer)
    }

    func updateRecognitionMonitoring() {
        let active = hasTarget && !isPaused && !isSelecting
        let refresh = active && settings.automaticRefresh
        let overlay = active && settings.translationEnabled && settings.presentation != .panel
        monitoring.configure(refreshInterval: refresh ? settings.refreshInterval : nil,
            overlayInterval: overlay ? 0.1 : nil)
        if refresh { interactions.start() }
        else { interactions.stop() }
    }

    private var fadesOnScroll: Bool {
        settings.automaticRefresh && settings.translationEnabled && settings.presentation != .panel
            && hasTarget && !isPaused && !isSelecting
    }

    func beginScroll() {
        guard !isScrolling else { return }
        isScrolling = true
        isWaitingForScrollTranslation = true
        hasFreshScrollRecognition = false
        windowsController?.overlay.fadeOutAndDiscard()
        // Keep continuous capture and the text-only translation cache. Everything
        // tied to the previous screen (including the OCR/image caches) is dropped.
        generation = UUID()
        captureTask?.cancel()
        captureTask = nil
        interactionRefreshTask?.cancel()
        interactionRefreshTask = nil
        translation.cancel()
        needsTranslation = false
        needsRefresh = false
        isCapturing = false
        blocks = []
        fingerprint = nil
        usedAppText = false
        lastCaptureRect = nil
        imageOverlay.reset()
        ocr = OCRService(stabilizer: imageOverlay.stabilizer)
    }

    func finishScroll() {
        guard isScrolling else { return }
        isScrolling = false
        // Full recognition uses the current capture. No pre-scroll coordinates or
        // block identifiers are reconciled into this layout.
        requestRefresh(force: true)
    }

    private func refreshAfterInteraction(at point: CGPoint, scroll: ScrollInteraction? = nil) {
        if let scroll, fadesOnScroll, isScrolling {
            // Momentum may continue after the pointer leaves the target bounds.
            scrollActivity.note(scroll)
            return
        }
        guard settings.automaticRefresh, let target, !isSelecting, !isPaused,
              let rect = capture.visibleFrame(for: target) else { return }
        let screenPoint = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
        guard rect.contains(screenPoint) else { return }
        // Background windows may be scrolled without becoming active. Allow that
        // when visible, but do not treat input on an overlapping app as this target's.
        if case .window(_, let pid, _, _) = target,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != pid,
           capture.isOccluded(target, rect: rect, overlayWindowID: windowsController?.overlay.window?.windowNumber) { return }
        if let scroll, fadesOnScroll {
            scrollActivity.note(scroll)
            return
        }
        interactionRefreshTask?.cancel()
        let token = generation
        interactionRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.requestRefresh()
        }
    }

    func requestRefresh(force: Bool = false) {
        guard let target, !isSelecting, !isPaused, !isScrolling else { return }
        updateRecognitionMonitoring()
        if force { fingerprint = nil }
        if case .window = target, capture.availableFrame(for: target) == nil {
            status = "대상 창이 닫혔거나 최소화되어 있습니다. 다시 표시되면 인식을 계속합니다."
            windowsController?.overlay.hide()
            return
        }
        guard captureTask == nil else { needsRefresh = true; return }
        let token = generation
        let language = recognitionSettings.ocrLanguage
        let mode = settings.ocrMode
        let recognitionSource = recognitionSettings.recognitionSource
        let previous = fingerprint
        // Background checks stay silent. Show progress for the first capture or an explicit refresh.
        isCapturing = force || lastCaptureRect == nil
        captureTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == token {
                    self.isCapturing = false
                    self.captureTask = nil
                    if self.needsRefresh {
                        self.needsRefresh = false
                        self.requestRefresh()
                    }
                }
            }
            do {
                let captured = try await self.capture.capture(target, continuously: self.settings.automaticRefresh || self.settings.presentation != .panel)
                guard self.generation == token, !Task.isCancelled else { return }
                // At a scroll boundary the pixels may not change, so ScreenCaptureKit
                // may send no new complete frame. The current capture is still a
                // valid input for fresh OCR after discarding the previous layout.
                self.imageOverlay.observe(CapturedFrame(image: captured.image, fingerprint: captured.fingerprint,
                    pixels: captured.pixels, sequence: captured.sequence))
                let newBlocks: [TextBlock]?
                var recognizedFingerprint = captured.fingerprint
                let method: String
                var appBlocks: [TextBlock]?
                if recognitionSource == .automatic,
                   case .window(let id, let processID, _, _) = target,
                   let frame = ScreenCaptureService.windowFrame(id: id) {
                    appBlocks = try await self.accessibleText.read(processID: processID, windowRect: frame, captureRect: captured.screenRect)
                }
                guard self.generation == token, !Task.isCancelled else { return }
                let topInset = self.capture.overlayTopInset(for: target, rect: captured.screenRect)
                if let appBlocks {
                    newBlocks = appBlocks
                    method = "앱 텍스트"
                } else {
                    let result = try await self.ocr.recognize(captured.image, language: language, previousFingerprint: self.usedAppText ? nil : previous,
                        fingerprint: captured.fingerprint, mode: mode, pixels: captured.pixels, sequence: captured.sequence)
                    newBlocks = result.blocks
                    recognizedFingerprint = result.fingerprint
                    method = result.effectiveMode == .fast ? "빠른 OCR" : "정확한 OCR"
                }
                guard self.generation == token, !Task.isCancelled else { return }
                let incoming = newBlocks ?? self.blocks
                guard await self.imageOverlay.accept(captured, blocks: incoming, topInset: topInset),
                      self.generation == token else { return }
                self.lastCaptureRect = captured.screenRect
                self.fingerprint = recognizedFingerprint
                self.usedAppText = appBlocks != nil
                if self.isWaitingForScrollTranslation { self.hasFreshScrollRecognition = true }
                if self.errorMessage != nil { self.errorMessage = nil }
                if let newBlocks {
                    let reconciled = TextSnapshot.reconcile(newBlocks, previous: self.blocks,
                        pixelSize: CGSize(width: captured.image.width, height: captured.image.height))
                    if reconciled != self.blocks {
                        self.blocks = reconciled
                        self.recognitionLogger.notice("Text results changed: \(reconciled.count) paragraphs")
                        self.lastUpdated = .now
                        self.translateCurrentBlocks(clearExisting: false)
                    }
                }
                if self.settings.translationEnabled, self.blocks.contains(where: { $0.translation == nil }),
                   !self.translation.isWorking, force || self.translation.message == nil {
                    self.translateCurrentBlocks(clearExisting: false)
                }
                if self.lastUpdated == nil { self.lastUpdated = .now }
                let status = self.blocks.isEmpty ? "인식된 글자가 없습니다. 영역이나 OCR 언어를 조정해 보세요." : "\(self.blocks.count)개 문단 인식됨 · \(method)"
                if self.status != status { self.status = status }
                self.updateOverlay()
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
                // A transient capture/OCR error must not flash the source screen.
                // Keep the completed translation while the next refresh retries.
                if !self.imageOverlay.hasPresentation { self.showResults() }
                else { self.updateOverlay() }
            }
        }
    }

    func translateCurrentBlocks(clearExisting: Bool = true) {
        guard !isScrolling else { return }
        if clearExisting {
            translation.cancel()
            needsTranslation = false
            var cleared = blocks
            for index in cleared.indices { cleared[index].translation = nil }
            if cleared != blocks { blocks = cleared }
        }
        guard settings.translationEnabled, !blocks.isEmpty, hasTarget, !isSelecting else {
            updateOverlay()
            return
        }
        let pending = blocks.filter { $0.translation == nil }
        guard !pending.isEmpty else { updateOverlay(); return }
        // OCR and preview continue during translation, while the current batch
        // finishes. Queue the latest labels rather than repeatedly cancelling it.
        if translation.isWorking {
            needsTranslation = true
            updateOverlay()
            return
        }
        needsTranslation = false
        let token = generation
        translation.submit(blocks: pending, settings: recognitionSettings, sourceContext: sourceText) { [weak self] values in
            guard let self, self.generation == token else { return }
            var translated = self.blocks
            for index in translated.indices {
                if let value = values[translated[index].id] { translated[index].translation = value }
            }
            if translated != self.blocks { self.blocks = translated }
            self.updateOverlay()
        }
    }

    func updateSource(_ text: String, blockID: UUID) {
        guard let index = blocks.firstIndex(where: { $0.id == blockID }) else { return }
        blocks[index].source = text
        blocks[index].translation = nil
        translateCurrentBlocks()
    }

    func updateOverlay() {
        guard let target, !isSelecting, !isPaused,
              let rect = capture.visibleFrame(for: target) else { windowsController?.overlay.hide(); return }
        guard settings.presentation != .panel, settings.translationEnabled else {
            windowsController?.overlay.hide()
            return
        }
        // Do not interrupt fade-out or revive an old/partially translated layout.
        guard !isScrolling else { return }
        if isWaitingForScrollTranslation {
            guard hasFreshScrollRecognition, blocks.allSatisfy({ $0.translation != nil }) else { return }
        }
        let oldRect = lastVisibleRect
        lastVisibleRect = rect
        // Keep the last completed screen during resizing; the image scales with
        // its window until OCR and translation produce the new layout.
        let matchesCaptureSize = lastCaptureRect?.size == rect.size
        if !matchesCaptureSize, oldRect?.size != rect.size { fingerprint = nil; requestRefresh() }
        if matchesCaptureSize { imageOverlay.prepare(blocks: blocks, settings: settings) }
        guard let presentation = imageOverlay.presentation else {
            // Keep the emptied, transparent window during post-scroll rendering.
            // The next result then appears through opacity alone, without a new
            // native window ordering transition.
            if !isWaitingForScrollTranslation { windowsController?.overlay.hide() }
            return
        }
        let topInset = capture.overlayTopInset(for: target, rect: rect)
        let contentRect = CGRect(x: rect.minX, y: rect.minY + topInset, width: rect.width, height: max(0, rect.height - topInset))
        guard !capture.isOccluded(target, rect: contentRect, overlayWindowID: windowsController?.overlay.window?.windowNumber) else { windowsController?.overlay.hide(); return }
        windowsController?.overlay.show(rect: rect, presentation: presentation,
            livePreview: settings.livePreview && settings.automaticRefresh,
            level: capture.overlayLevel(for: target), topInset: topInset, fadeIn: isWaitingForScrollTranslation)
        isWaitingForScrollTranslation = false
        hasFreshScrollRecognition = false
    }

    func ensurePermission() async -> Bool {
        guard await capture.verifyAccess() else { windowsController?.showWelcome(); return false }
        return true
    }

    func showResults() {
        // Reopening the app or a late translation callback must not bring a
        // hidden result panel back in front of an in-progress selection.
        guard !isSelecting else { return }
        windowsController?.showResults()
    }
    func showSettings() { windowsController?.showSettings() }

    func relaunch() {
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Pass the PID and bundle path as positional arguments, never shell-interpolated text.
        // Wait for this process to exit so the new instance sees fresh TCC state and hot keys.
        launcher.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open \"$2\"",
                              "linelens-relaunch", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        do {
            try launcher.run()
            NSApp.terminate(nil)
        } catch {
            errorMessage = "앱을 다시 실행하지 못했습니다. \(error.localizedDescription)"
            showResults()
        }
    }
    private func showResultsIfNeeded() { if settings.presentation != .overlay { showResults() } }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

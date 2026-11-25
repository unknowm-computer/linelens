import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var recording: ShortcutAction?

    enum ShortcutAction: String, Identifiable { case capture, stop; var id: String { rawValue } }

    var body: some View {
        Form {
            Section("일반") {
                LaunchAtLoginSettingsView(service: model.launchAtLogin)
            }
            Section("프로그램 창 캡처") {
                Picker("캡처 방식", selection: $model.settings.windowCaptureMode) {
                    ForEach(WindowCaptureMode.allCases) { Text($0.title).tag($0) }
                }
                Text("창 직접 캡처는 선택한 창의 내용을 가져옵니다. 창 영역 캡처는 창의 이동·크기 변경을 따라가며 실제 화면에 보이는 영역을 OCR로 읽습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.settings.windowCaptureMode == .screenRegion {
                    Text("겹친 팝업과 다른 창도 포함됩니다. 창 내부의 일부 영역 선택에도 적용되며, 여러 모니터에 걸치면 선택 영역이 가장 많이 보이는 모니터를 사용합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            recognitionAndTranslationSection
            Section("갱신 및 표시") {
                Toggle("자동 갱신", isOn: $model.settings.automaticRefresh)
                Picker("갱신 간격", selection: $model.settings.refreshInterval) {
                    Text("1초").tag(1.0)
                    Text("2초").tag(2.0)
                    Text("3초").tag(3.0)
                    Text("5초").tag(5.0)
                }
                Picker("결과 표시", selection: $model.settings.presentation) {
                    ForEach(ResultPresentation.allCases) { Text($0.title).tag($0) }
                }
                Toggle("결과 창 항상 표시", isOn: $model.settings.alwaysShowResults)
                Text("대상 선택을 마치면 ‘번역 화면’ 모드에서도 인식 결과 창을 엽니다.")
                    .font(.caption).foregroundStyle(.secondary)
                OverlayStylePicker(selection: $model.settings.overlayStyle)
                Toggle("실시간 화면 표시", isOn: $model.settings.livePreview)
                    .disabled(model.settings.overlayStyle != .cover)
                if model.settings.overlayStyle == .cover {
                    Text("캡처한 배경을 실시간으로 갱신하고, 번역 중인 글자는 …로 표시합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.settings.overlayStyle == .inPlace {
                    Text("실제 화면 위에 번역이 준비된 글자 영역만 덮습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("브라우저 링크 주소 표시 영역 제외", isOn: $model.settings.excludeBrowserLinkStatus)
                    .disabled(model.settings.presentation == .panel || model.settings.windowCaptureMode == .screenRegion)
                Text("창 직접 캡처에서 링크 주소와 겹치는 부분만 비웁니다. 창 영역 캡처는 링크 주소를 화면 내용에 포함합니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("번역 화면은 클릭과 스크롤을 통과시킵니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("자동 갱신을 끄면 마지막 번역 화면이 유지됩니다. ‘지금 새로고침’으로 새 내용을 번역할 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("결과 창 항상 위에 표시", isOn: $model.settings.pinResults)
            }
            Section("단축키") {
                shortcutRow("영역 선택", shortcut: model.settings.captureShortcut, action: .capture)
                shortcutRow("인식 해제", shortcut: model.settings.stopShortcut, action: .stop)
                Text("Esc는 창이나 영역을 선택하는 동안 선택을 취소합니다. 인식 해제는 메뉴 막대나 지정한 단축키로 할 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = model.hotKeyError { Text(error).font(.caption).foregroundStyle(.orange) }
            }
            Section("권한") {
                PermissionSettingsView(model: model)
            }
            Section("업데이트") {
                UpdateSettingsView(updater: model.updater)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, minHeight: 580)
        .task(id: model.settings.translationQuality) { await model.loadLanguageOptionsIfNeeded() }
        .onAppear { refreshSystemSettings() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshSystemSettings()
        }
        .sheet(item: $recording) { action in
            ShortcutRecorderView(title: action == .capture ? "영역 선택 단축키" : "인식 해제 단축키") { shortcut in
                if action == .capture { model.settings.captureShortcut = shortcut }
                else { model.settings.stopShortcut = shortcut }
                recording = nil
            } onCancel: { recording = nil }
        }
    }

    private var recognitionAndTranslationSection: some View {
        let downloadedOnly = model.settings.downloadedTranslationLanguagesOnly
        return TranslationLanguageFilter(downloadedOnly: downloadedOnly, settings: model.settings,
            languages: model.translation.supportedLanguages, includeInstalledLanguages: true) { choices, hint in
            recognitionAndTranslationRows(choices: choices, filterHint: hint, downloadedOnly: downloadedOnly)
        }
    }

    private func recognitionAndTranslationRows(choices: TranslationEngine.LanguageChoices, filterHint: String?,
                                                downloadedOnly: Bool) -> some View {
        let ocrLanguages = downloadedOnly
            ? Array(Set(RecognitionLanguages.options(ocrLanguages: model.ocrLanguages,
                translationLanguages: choices.installed).map(\.ocrLanguage))).sorted()
            : model.ocrLanguages
        return Section {
            Picker("텍스트 읽기", selection: $model.settings.recognitionSource) {
                ForEach(TextRecognitionSource.allCases) { Text($0.title).tag($0) }
            }
            Text("앱 텍스트 우선은 접근성 권한을 허용한 프로그램 창에서 사용합니다. 앱이 텍스트를 제공하지 않거나 이미지·게임 화면이면 OCR로 전환합니다.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("OCR 모드", selection: $model.settings.ocrMode) {
                ForEach(OCRMode.allCases) { Text($0.title).tag($0) }
            }
            OCRLanguagePicker(language: $model.settings.ocrLanguage, supportedLanguages: ocrLanguages)
            Text("빠른 OCR은 영어 등 일부 언어를 지원합니다. 미지원 언어를 지정하거나 인식 신뢰도가 낮으면 정확한 OCR을 사용합니다. 한국어·일본어 화면은 OCR 언어를 지정하거나 정확한 OCR을 선택해 주세요.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("자동 번역", isOn: $model.settings.translationEnabled)
            Picker("번역 처리", selection: $model.settings.translationQuality) {
                ForEach(TranslationQuality.allCases) { Text($0.title).tag($0) }
            }
            .disabled(!TranslationEngine.supportsQualitySelection)
            if !TranslationEngine.supportsQualitySelection {
                Text("번역 품질 선택은 macOS 26.4 이상에서 지원합니다. 현재는 시스템 기본 번역을 사용합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TranslationLanguagePickers(source: $model.settings.sourceLanguage, target: $model.settings.targetLanguage,
                choices: choices)
            if let filterHint { Text(filterHint).font(.caption).foregroundStyle(.secondary) }
            Text("번역은 기기에서 처리합니다. 언어 모델이 필요하면 결과 창에서 다운로드할 수 있습니다.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            HStack {
                Text("인식 및 번역")
                Spacer(minLength: 8)
                Toggle("다운로드한 언어만 표시", isOn: $model.settings.downloadedTranslationLanguagesOnly)
                    .toggleStyle(.checkbox).controlSize(.small).font(.caption)
            }
        }
    }

    private func refreshSystemSettings() {
        model.launchAtLogin.refresh()
        model.accessibility.refresh()
        Task { await model.capture.recheckIfAuthorizationChanged() }
    }

    private func shortcutRow(_ title: String, shortcut: KeyboardShortcut?, action: ShortcutAction) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button(shortcut?.label ?? "지정 안 함") { recording = action }
            if shortcut != nil {
                Button("제거") {
                    if action == .capture { model.settings.captureShortcut = nil }
                    else { model.settings.stopShortcut = nil }
                }
            }
        }
    }
}

@MainActor
func openScreenPermissionSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
    NSWorkspace.shared.open(url)
}

@MainActor
func openAccessibilitySettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
    NSWorkspace.shared.open(url)
}

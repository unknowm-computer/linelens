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
            Section("인식 및 번역") {
                Picker("텍스트 읽기", selection: $model.settings.recognitionSource) {
                    ForEach(TextRecognitionSource.allCases) { Text($0.title).tag($0) }
                }
                Text("앱 텍스트 우선은 접근성 권한을 허용한 프로그램 창에서 사용합니다. 앱이 텍스트를 제공하지 않거나 이미지·게임 화면이면 OCR로 전환합니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("OCR 모드", selection: $model.settings.ocrMode) {
                    ForEach(OCRMode.allCases) { Text($0.title).tag($0) }
                }
                OCRLanguagePicker(language: $model.settings.ocrLanguage, supportedLanguages: model.ocrLanguages)
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
                TranslationLanguageFilter(downloadedOnly: $model.settings.downloadedTranslationLanguagesOnly,
                    settings: model.settings, languages: model.translation.supportedLanguages) { toggle in
                    toggle
                } content: { choices in
                    TranslationLanguagePickers(source: $model.settings.sourceLanguage, target: $model.settings.targetLanguage,
                        choices: choices)
                }
                Text("번역은 기기에서 처리합니다. 언어 모델이 없으면 최초 다운로드를 위한 시스템 안내가 표시됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
                    .disabled(model.settings.presentation == .panel)
                Text("브라우저 창을 번역할 때 링크 주소와 겹치는 부분만 비우고 나머지 번역은 유지합니다.")
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
                Text("해제 단축키는 기본 미지정입니다. Escape는 사용하지 않으며, 메뉴 막대에서 선택 취소·인식 해제를 할 수 있습니다.")
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

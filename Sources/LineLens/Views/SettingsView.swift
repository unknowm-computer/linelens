import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var recording: ShortcutAction?

    enum ShortcutAction: String, Identifiable { case capture, stop; var id: String { rawValue } }

    var body: some View {
        Form {
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
                TranslationLanguagePickers(source: $model.settings.sourceLanguage, target: $model.settings.targetLanguage,
                    supportedLanguages: model.translation.supportedLanguages)
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
                Picker("화면 위 번역", selection: $model.settings.overlayStyle) {
                    ForEach(OverlayStyle.allCases) { Text($0.title).tag($0) }
                }
                Toggle("실시간 화면 표시", isOn: $model.settings.livePreview)
                Text("켜면 클릭·스크롤 결과와 배경을 먼저 표시하고 번역된 글자는 조각별로 갱신합니다. 새 위치의 원문은 인식 전 잠깐 보일 수 있습니다. 끄면 다음 인식이 끝날 때까지 이전 번역 화면을 유지합니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("번역 화면은 클릭과 스크롤을 통과시킵니다. 변경된 영역만 인식하고, 번역 중인 글자는 …로 표시합니다.")
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
                Button("화면 기록 권한 설정 열기") { openScreenPermissionSettings() }
                LabeledContent("앱 텍스트 접근", value: model.accessibility.isTrusted ? "허용됨" : "권한 없음 · OCR 사용 중")
                HStack {
                    Button("접근성 권한 허용 안내") { model.accessibility.requestPermission() }
                    Button("권한 상태 확인") { model.accessibility.refresh() }
                }
            }
            Section("업데이트") {
                UpdateSettingsView(updater: model.updater)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, minHeight: 580)
        .onAppear { model.accessibility.refresh() }
        .sheet(item: $recording) { action in
            ShortcutRecorderView(title: action == .capture ? "영역 선택 단축키" : "인식 해제 단축키") { shortcut in
                if action == .capture { model.settings.captureShortcut = shortcut }
                else { model.settings.stopShortcut = shortcut }
                recording = nil
            } onCancel: { recording = nil }
        }
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

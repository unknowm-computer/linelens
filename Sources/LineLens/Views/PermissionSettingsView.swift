import SwiftUI

struct PermissionSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        LabeledContent("화면 기록", value: screenAccessLabel)
        Text("화면 캡처와 OCR에 필요합니다. 시스템 오디오는 녹음하지 않습니다.")
            .font(.caption).foregroundStyle(.secondary)
        HStack {
            if !model.capture.hasPermission {
                Button("화면 기록 권한 요청") { Task { await model.capture.requestPermission() } }
                    .disabled(isBusy || model.capture.requiresRelaunch)
            }
            Button("화면 기록 설정 열기") { openScreenPermissionSettings() }
        }
        if model.capture.requiresRelaunch {
            Button("권한 적용을 위해 앱 다시 실행") { model.relaunch() }
        }
        LabeledContent("접근성", value: model.accessibility.isTrusted ? "허용됨" : "미허용 · OCR 사용 가능")
        Text("프로그램이 제공하는 텍스트를 직접 읽는 선택 권한입니다. 허용하지 않아도 화면 OCR과 번역을 사용할 수 있습니다.")
            .font(.caption).foregroundStyle(.secondary)
        HStack {
            if !model.accessibility.isTrusted {
                Button("접근성 권한 요청") { model.accessibility.requestPermission() }
            }
            Button("접근성 설정 열기") { openAccessibilitySettings() }
        }
        Button("권한 상태 다시 확인") {
            Task {
                model.accessibility.refresh()
                await model.capture.verifyAccess()
            }
        }.disabled(isBusy || model.capture.requiresRelaunch)
    }

    private var isBusy: Bool { model.capture.isCheckingAccess || model.capture.isResettingAccess }

    private var screenAccessLabel: String {
        if model.capture.requiresRelaunch { return "앱 재실행 필요" }
        switch model.capture.accessState {
        case .unchecked: return "확인 전"
        case .checking: return "확인 중…"
        case .allowed: return "허용됨"
        case .needsApproval: return "승인 필요"
        case .failed: return "확인 실패"
        }
    }
}

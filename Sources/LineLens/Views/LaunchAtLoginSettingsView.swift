import ServiceManagement
import SwiftUI

struct LaunchAtLoginSettingsView: View {
    @Bindable var service: LaunchAtLoginService

    var body: some View {
        Toggle("로그인 시 자동 실행", isOn: Binding(
            get: { service.isOn },
            set: { enabled in Task { await service.setEnabled(enabled) } }
        ))
        .disabled(service.isUpdating)
        Text("Mac에 로그인하면 LineLens를 메뉴 막대에서 실행합니다.")
            .font(.caption).foregroundStyle(.secondary)
        if service.status == .requiresApproval {
            Label("시스템 설정에서 허용해야 자동 실행됩니다.", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
            Button("로그인 항목 설정 열기") { service.openSystemSettings() }
        } else if service.status == .notFound, service.errorMessage != nil {
            Text("자동 실행 항목을 찾을 수 없습니다. 앱을 응용 프로그램 폴더에 설치한 뒤 다시 시도해 주세요.")
                .font(.caption).foregroundStyle(.orange)
        }
        if let error = service.errorMessage {
            Text("자동 실행 설정을 변경하지 못했습니다: \(error)")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}

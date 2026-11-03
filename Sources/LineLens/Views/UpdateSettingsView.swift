import SwiftUI

struct CheckForUpdatesButton: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Button("업데이트 확인…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}

struct UpdateSettingsView: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        LabeledContent("현재 버전", value: updater.versionLabel)
        Toggle("자동으로 업데이트 확인", isOn: Binding(
            get: { updater.checksAutomatically },
            set: { updater.setChecksAutomatically($0) }
        ))
        CheckForUpdatesButton(updater: updater)
        Text("업데이트를 확인할 때 인터넷에 연결합니다. 새 버전의 설치는 안내 창에서 선택합니다.")
            .font(.caption).foregroundStyle(.secondary)
        if let error = updater.startupError {
            Text("업데이트 기능을 시작하지 못했습니다: \(error)")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}

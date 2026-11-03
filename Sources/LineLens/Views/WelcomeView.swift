import AppKit
import SwiftUI

struct WelcomeView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "text.viewfinder").font(.system(size: 42)).foregroundStyle(.tint)
            Text("화면의 글자를 읽고, 번역하세요.").font(.title2.bold())
            Text("화면 영역이나 프로그램 창에서 글자를 읽으려면 화면 기록 권한이 필요합니다. 캡처 이미지는 파일로 저장하지 않고 메모리에서 처리합니다.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label("OCR·번역은 Mac 안에서 처리합니다.", systemImage: "lock.shield")
                .font(.callout)
            if model.capture.hasPermission {
                Label("화면 접근이 확인되었습니다.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("화면 영역 선택") {
                    model.windowsController?.dismissWelcome()
                    model.selectRegion()
                }.buttonStyle(.borderedProminent)
            } else {
                if model.capture.isCheckingAccess {
                    ProgressView("화면 접근 확인 중…").controlSize(.small)
                }
                if model.capture.accessState == .needsApproval {
                    Label("현재 앱에 화면 접근 승인이 적용되지 않았습니다.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .failed(let message) = model.capture.accessState {
                    Text("화면 접근 확인에 실패했습니다. \(message)")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("화면 기록 권한 요청") {
                        Task { await model.capture.requestPermission() }
                    }.buttonStyle(.borderedProminent).disabled(isBusy || model.capture.requiresRelaunch)
                    Button("시스템 설정 열기") { openScreenPermissionSettings() }
                }
                Text("시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 녹음에서 LineLens를 허용한 뒤 ‘권한 다시 확인’을 누르세요.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("이미 허용했는데 계속 이 화면이 나오면 ‘권한 연결 초기화’ 후 앱을 다시 실행해 허용해 주세요. LineLens의 화면 기록 승인만 초기화합니다.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = model.capture.recoveryMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.capture.requiresRelaunch {
                    Button("앱 다시 실행") { model.relaunch() }.buttonStyle(.borderedProminent)
                }
                HStack {
                    Button("권한 연결 초기화") { Task { await model.capture.resetAccess() } }
                        .disabled(isBusy || model.capture.requiresRelaunch)
                    Button("진단 정보 복사") { model.copy(model.capture.diagnosticDetails) }
                        .disabled(model.capture.diagnosticDetails.isEmpty)
                }
                HStack {
                    Button("권한 다시 확인") { Task { await model.capture.verifyAccess() } }
                        .disabled(isBusy || model.capture.requiresRelaunch)
                    Spacer()
                    Button("설정") { model.showSettings() }
                }
            }
        }.padding(28)
        }.frame(minWidth: 460, minHeight: 560)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.capture.recheckIfAuthorizationChanged() }
        }
    }

    private var isBusy: Bool { model.capture.isCheckingAccess || model.capture.isResettingAccess }
}

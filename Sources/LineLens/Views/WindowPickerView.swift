import AppKit
import SwiftUI

struct WindowPickerView: View {
    @Bindable var model: AppModel
    let onClose: () -> Void
    @State private var windows: [WindowChoice] = []
    @State private var selected: CGWindowID?
    @State private var crop = false
    @State private var search = ""
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("화면에서 창을 직접 클릭해 선택할 수도 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("화면에서 선택") { onClose(); model.chooseWindow() }
            }
            HStack {
                TextField("프로그램 또는 창 제목 검색", text: $search)
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("창 목록 새로고침").disabled(isLoading)
            }
            if isLoading { ProgressView("창 목록 불러오는 중…").frame(maxWidth: .infinity) }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            List(selection: $selected) {
                ForEach(windows.filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) }) { window in
                    HStack(spacing: 10) {
                        if let icon = NSRunningApplication(processIdentifier: window.processID)?.icon {
                            Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(window.application).font(.headline)
                            Text(window.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.padding(.vertical, 4).tag(window.id)
                }
            }
            Toggle("선택한 창의 일부 영역만 인식", isOn: $crop)
            HStack {
                Text("창은 사용자가 인식 해제할 때까지 유지됩니다.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("닫기") { onClose(); model.cancelSelection() }
                Button(crop ? "영역 지정" : "인식 시작") {
                    guard let window = windows.first(where: { $0.id == selected }) else { return }
                    onClose()
                    model.selectWindow(window, crop: crop)
                }.buttonStyle(.borderedProminent).disabled(selected == nil)
            }
        }.padding(20).frame(minWidth: 500, minHeight: 360).task { await load() }
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            windows = try await model.capture.windows()
            if !windows.contains(where: { $0.id == selected }) { selected = nil }
            if windows.isEmpty { error = "선택할 수 있는 창이 없습니다. 대상 프로그램을 열고 다시 불러와 주세요." }
        } catch { self.error = error.localizedDescription }
    }
}

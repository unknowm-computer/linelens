import AppKit
import SwiftUI

@main
struct LineLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("LineLens", systemImage: "text.viewfinder") {
            MenuContent(model: delegate.model)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: delegate.model.updater)
            }
            CommandGroup(replacing: .appSettings) {
                Button("LineLens 설정…") { delegate.model.showSettings() }
                    .keyboardShortcut(",")
            }
            CommandGroup(after: .newItem) {
                Button("인식 결과 보기") { delegate.model.showResults() }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.showResults()
        return true
    }
}

private struct MenuContent: View {
    @Bindable var model: AppModel

    var body: some View {
        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "LineLens")
        Text(compactTargetTitle)
            .help(targetTitle)
        Divider()
        Button("화면 영역 선택\(shortcutLabel)") { model.selectRegion() }
        Button("프로그램 창 직접 선택…") { model.chooseWindow() }
        Button("프로그램 창 목록에서 선택…") { model.chooseWindowFromList() }
        if model.isSelecting {
            Button("선택 취소") { model.cancelSelection() }
        }
        if model.hasTarget {
            Button("영역 이동·크기 변경…") { model.adjustRegion() }.disabled(model.isSelecting)
            Button("지금 새로고침") { model.requestRefresh(force: true) }
                .disabled(model.isPaused || model.isSelecting)
            Button(model.isPaused ? "인식 재개" : "일시정지") { model.togglePause() }
                .disabled(model.isSelecting)
            Button("인식 해제") { model.stop() }
        }
        Divider()
        Toggle("자동 번역", isOn: $model.settings.translationEnabled)
        Toggle("자동 갱신", isOn: $model.settings.automaticRefresh)
        Button("결과 창 보기") { model.showResults() }
        Button("설정…") { model.showSettings() }
        CheckForUpdatesButton(updater: model.updater)
        Divider()
        Button("LineLens 종료") { NSApp.terminate(nil) }
    }

    private var shortcutLabel: String { model.settings.captureShortcut.map { "  \($0.label)" } ?? "" }

    private var targetTitle: String {
        model.isSelecting ? "대상 선택 중" : model.target?.title ?? "인식 대상 없음"
    }

    private var compactTargetTitle: String {
        // Native menu items use the Text's string rather than SwiftUI's frame
        // constraints. Shorten the actual label before passing it to the menu.
        let title = targetTitle.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0)]
        let maximumWidth: CGFloat = 320
        guard (title as NSString).size(withAttributes: attributes).width > maximumWidth else { return title }
        var prefix = ""
        for character in title {
            let next = prefix + String(character)
            guard ((next + "…") as NSString).size(withAttributes: attributes).width <= maximumWidth else { break }
            prefix = next
        }
        return prefix + "…"
    }
}

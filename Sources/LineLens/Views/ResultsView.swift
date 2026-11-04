import LineLensCore
import SwiftUI
import Translation

struct ResultsView: View {
    @Bindable var model: AppModel
    @State private var editingBlock: TextBlock?
    @State private var editedText = ""
    @State private var isChoosingLanguage = false
    @State private var isChoosingRecognition = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = model.errorMessage { message(error, symbol: "exclamationmark.triangle", color: .orange) }
            if let message = model.translation.message { self.message(message, symbol: "globe", color: .secondary) }
            if model.blocks.isEmpty {
                ContentUnavailableView(
                    model.hasTarget ? "인식 결과를 기다리고 있습니다" : "화면의 글자를 읽어보세요",
                    systemImage: "text.viewfinder",
                    description: Text(model.status)
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(model.blocks) { block in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("원문").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button {
                                        if !model.isPaused { model.togglePause() }
                                        editedText = block.source
                                        editingBlock = block
                                    } label: { Image(systemName: "pencil") }
                                    .help("원문 수정 · 인식을 일시정지합니다")
                                    .accessibilityLabel("원문 수정")
                                    Button { model.copy(block.source) } label: { Image(systemName: "doc.on.doc") }
                                        .help("원문 복사").accessibilityLabel("원문 복사")
                                }
                                .buttonStyle(.borderless)
                                Text(block.source).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                if model.settings.translationEnabled {
                                    Divider()
                                    HStack {
                                        Text("번역").font(.caption).foregroundStyle(.secondary)
                                        Spacer()
                                        if let text = block.translation {
                                            Button { model.copy(text) } label: { Image(systemName: "doc.on.doc") }
                                                .buttonStyle(.borderless).help("번역 복사").accessibilityLabel("번역 복사")
                                        }
                                    }
                                    Text(block.translation ?? (model.translation.isWorking ? "번역 중…" : "번역 결과 없음"))
                                        .foregroundStyle(block.translation == nil ? .secondary : .primary)
                                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(14)
                            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }.padding(16)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 360, minHeight: 320)
        .translationTask(model.translation.configuration) { session in
            await model.translation.run(using: session)
        }
        .sheet(item: $editingBlock) { block in
            VStack(alignment: .leading, spacing: 16) {
                Text("OCR 원문 수정").font(.headline)
                Text("수정 중에는 화면 인식을 일시정지합니다. 저장 후 ‘인식 재개’로 돌아갈 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $editedText).font(.body).border(.separator)
                    .accessibilityLabel("수정할 원문")
                HStack {
                    Button("닫기") { editingBlock = nil }
                    Spacer()
                    Button("저장 및 재번역") {
                        model.updateSource(editedText.trimmingCharacters(in: .whitespacesAndNewlines), blockID: block.id)
                        editingBlock = nil
                    }.buttonStyle(.borderedProminent)
                        .disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 440, height: 330)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "text.viewfinder").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.target?.title ?? "LineLens").font(.headline).lineLimit(1)
                    Text(model.isPaused ? "일시정지됨" : model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if model.isCapturing || model.translation.isWorking { ProgressView().controlSize(.small) }
                Button { model.settings.pinResults.toggle() } label: {
                    Image(systemName: model.settings.pinResults ? "pin.fill" : "pin")
                }.buttonStyle(.borderless).help("결과 창 항상 위에 표시").accessibilityLabel("결과 창 고정 전환")
            }
            HStack {
                Button("영역 선택") { model.selectRegion() }
                Button("창 선택") { model.chooseWindow() }
                Spacer()
                if model.hasTarget {
                    Button { model.requestRefresh(force: true) } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(model.isPaused || model.isSelecting).help("새로고침").accessibilityLabel("새로고침")
                    Button(model.isPaused ? "인식 재개" : "일시정지") { model.togglePause() }
                        .disabled(model.isSelecting)
                }
            }
            HStack {
                Toggle("자동 번역", isOn: $model.settings.translationEnabled)
                    .toggleStyle(.switch).controlSize(.small)
                Spacer()
                Button("텍스트 읽기", systemImage: "text.magnifyingglass") {
                    isChoosingLanguage = false
                    isChoosingRecognition = true
                }
                .help("현재 인식의 텍스트 읽기 선택 · \(model.recognitionSettings.recognitionSource.title)")
                .accessibilityLabel("현재 인식의 텍스트 읽기 설정")
                .popover(isPresented: $isChoosingRecognition, arrowEdge: .bottom) {
                    ResultRecognitionSettingsView(model: model)
                }
                Button("언어", systemImage: "globe") {
                    isChoosingRecognition = false
                    isChoosingLanguage = true
                }
                    .help("인식 언어와 번역 목표 언어 선택")
                    .accessibilityLabel("인식 및 번역 언어 설정")
                    .popover(isPresented: $isChoosingLanguage, arrowEdge: .bottom) {
                        ResultLanguageSettingsView(model: model)
                    }
            }
        }.padding(16)
    }

    private var footer: some View {
        HStack {
            Menu("전체 복사") {
                Button("원문 복사") { model.copy(model.sourceText) }
                Button("번역 복사") { model.copy(model.translatedText) }.disabled(model.translatedText.isEmpty)
            }.fixedSize().disabled(model.blocks.isEmpty)
            Spacer()
            if let date = model.lastUpdated { Text(date, style: .time).font(.caption).foregroundStyle(.secondary) }
            Button("설정") { model.showSettings() }
        }.padding(12)
    }

    private func message(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol).font(.caption).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(color.opacity(0.08))
    }
}

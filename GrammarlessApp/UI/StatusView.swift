import SwiftUI
import GrammarlessCore

struct StatusView: View {
    @ObservedObject var model: AppModel
    var language: GrammarlessLanguageMode = .zh

    private func ui(_ english: String, zh chinese: String) -> String {
        language == .zh ? chinese : english
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(ui("Grammarless Status", zh: "Grammarless 状态"))
                        .font(GrammarlessTheme.font(size: 22, weight: .semibold))
                        .foregroundStyle(GrammarlessTheme.ink)
                    Spacer()
                    if let onReanalyze = model.onReanalyze {
                        Button(ui("Reanalyze", zh: "重新分析"), action: onReanalyze)
                    }
                }

                LabeledContent(ui("Accessibility", zh: "辅助功能权限"), value: model.accessibilityAuthorized ? ui("Granted", zh: "已授权") : ui("Missing", zh: "缺失"))
                LabeledContent(ui("Frontmost App", zh: "前台应用"), value: model.frontmostApp)
                LabeledContent(ui("Focused Role", zh: "焦点角色"), value: model.focusedElementRole)
                LabeledContent(ui("Active Paragraph", zh: "当前段落"), value: model.activeParagraphDescription)
                LabeledContent(ui("Selection", zh: "选区"), value: model.selectionText.isEmpty ? "—" : model.selectionText)

                Group {
                    switch model.llmStatus {
                    case .idle:
                        LabeledContent(ui("LLM", zh: "模型"), value: ui("Idle", zh: "空闲"))
                    case .running(let message):
                        LabeledContent(ui("LLM", zh: "模型"), value: ui("Running · \(message)", zh: "运行中 · \(message)"))
                    case .success(let message):
                        LabeledContent(ui("LLM", zh: "模型"), value: ui("OK · \(message)", zh: "正常 · \(message)"))
                    case .failed(let message):
                        LabeledContent(ui("LLM", zh: "模型"), value: ui("Failed · \(message)", zh: "失败 · \(message)"))
                    }
                }

                if let error = model.lastErrorMessage, !error.isEmpty {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(GrammarlessTheme.error)
                }

                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .background(GrammarlessTheme.panel)
        .tint(GrammarlessTheme.aquaInk)
        .frame(width: 460, height: 640)
    }
}

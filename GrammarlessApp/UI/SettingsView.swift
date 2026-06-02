import SwiftUI
import GrammarlessCore

struct SettingsView: View {
    @ObservedObject var store: ConfigurationStore

    private var configuration: AppConfiguration { store.configuration }
    private var language: GrammarlessLanguageMode { configuration.uiLanguage }

    private func ui(_ english: String, zh chinese: String) -> String {
        language == .zh ? chinese : english
    }

    var body: some View {
        Form {
            Section(ui("Behavior", zh: "功能与语言")) {
                Picker(ui("Interface language", zh: "界面语言"), selection: binding(\.uiLanguage)) {
                    Text(ui("Chinese", zh: "中文")).tag(GrammarlessLanguageMode.zh)
                    Text(ui("English", zh: "英文")).tag(GrammarlessLanguageMode.en)
                }
                Toggle(ui("Ghost text", zh: "Ghost 预测"), isOn: binding(\.isGhostTextEnabled))
                Text(ui(
                    "English mode disables the offline Chinese proofreading.",
                    zh: "英文模式会关闭离线中文校对。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section(ui("OpenAI-compatible API", zh: "OpenAI 兼容 API")) {
                TextField(ui("Base URL", zh: "基础 URL"), text: binding(\.baseURL))
                SecureField(ui("API Key", zh: "API 密钥"), text: binding(\.apiKey))
                TextField(ui("Model", zh: "模型"), text: binding(\.model))
            }

            Section(ui("Timing", zh: "时间")) {
                HStack {
                    Text(ui("Debounce (ms)", zh: "防抖（毫秒）"))
                    Spacer()
                    TextField("700", value: binding(\.debounceMilliseconds), format: .number)
                        .frame(width: 100)
                }
                HStack {
                    Text(ui("Review Timeout (s)", zh: "审阅超时（秒）"))
                    Spacer()
                    TextField("8", value: binding(\.reviewTimeoutSeconds), format: .number)
                        .frame(width: 100)
                }
                HStack {
                    Text(ui("Action Timeout (s)", zh: "操作超时（秒）"))
                    Spacer()
                    TextField("15", value: binding(\.actionTimeoutSeconds), format: .number)
                        .frame(width: 100)
                }
            }

            Section {
                Button(ui("Reset Defaults", zh: "恢复默认")) {
                    store.reset()
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .background(GrammarlessTheme.panel)
        .tint(GrammarlessTheme.aquaInk)
        .frame(width: 480, height: 420)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { configuration[keyPath: keyPath] },
            set: { newValue in
                store.update { $0[keyPath: keyPath] = newValue }
            }
        )
    }
}

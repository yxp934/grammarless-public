import AppKit
import GrammarlessCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum LaunchFlag {
        static let showStatus = "GRAMMARLESS_SHOW_STATUS_ON_LAUNCH"
        static let showSettings = "GRAMMARLESS_SHOW_SETTINGS_ON_LAUNCH"
        static let disableKeychain = "GRAMMARLESS_DISABLE_KEYCHAIN"
    }

    private let appModel = AppModel()
    private lazy var configurationStore = Self.makeConfigurationStore()
    private lazy var controller = GrammarlessController(
        model: appModel,
        configurationStore: configurationStore
    )

    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var openGrammarlessMenuItem: NSMenuItem!
    private var quitGrammarlessMenuItem: NSMenuItem!
    private var qaAutomationBridge: QAAutomationBridge?

    override init() {
        super.init()
        LaunchProbe.log("AppDelegate.init bundle=\(Bundle.main.bundleIdentifier ?? "unknown")")
    }

    deinit {
        LaunchProbe.log("AppDelegate.deinit")
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        LaunchProbe.log("applicationWillFinishLaunching")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchProbe.log("applicationDidFinishLaunching")
        let keychainDisabled = ProcessInfo.processInfo.environment[LaunchFlag.disableKeychain] == "1"
        DebugLogger.startSession(
            note: """
            bundle=\(Bundle.main.bundleIdentifier ?? "unknown")
            showStatus=\(ProcessInfo.processInfo.environment[LaunchFlag.showStatus] ?? "0")
            showSettings=\(ProcessInfo.processInfo.environment[LaunchFlag.showSettings] ?? "0")
            keychainDisabled=\(keychainDisabled)
            debugLogPath=\(DebugLogger.logPath)
            """
        )
        SyntheticInputReset.releaseAllModifiersAndMouseButtons(reason: "app-launch")
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
        controller.start()
        if appModel.qaControlsEnabled {
            let bridge = QAAutomationBridge(controller: controller)
            qaAutomationBridge = bridge
            bridge.start()
        }
        applyLaunchFlags()
    }

    func applicationWillTerminate(_ notification: Notification) {
        LaunchProbe.log("applicationWillTerminate")
        SyntheticInputReset.releaseAllModifiersAndMouseButtons(reason: "app-terminate")
        qaAutomationBridge?.stop()
        controller.stop()
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Grammarless"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        DebugLogger.log("status item installed")

        let menu = NSMenu()
        openGrammarlessMenuItem = NSMenuItem(title: "", action: #selector(openGrammarless), keyEquivalent: "")
        quitGrammarlessMenuItem = NSMenuItem(title: "", action: #selector(quit), keyEquivalent: "q")
        menu.addItem(openGrammarlessMenuItem)
        menu.addItem(quitGrammarlessMenuItem)
        menu.items.forEach { $0.target = self }
        statusMenu = menu
        updateStatusMenuTitles()
    }

    private func updateStatusMenuTitles() {
        openGrammarlessMenuItem?.title = localized("Open Grammarless", zh: "打开 Grammarless")
        quitGrammarlessMenuItem?.title = localized("Quit Grammarless", zh: "退出 Grammarless")
    }

    private func localized(_ english: String, zh chinese: String) -> String {
        configurationStore.configuration.uiLanguage == .zh ? chinese : english
    }

    private static func makeConfigurationStore() -> ConfigurationStore {
        let environment = ProcessInfo.processInfo.environment
        if environment[LaunchFlag.disableKeychain] == "1" {
            LaunchProbe.log("configurationStore using disabled keychain")
            return ConfigurationStore(
                apiKeyStore: DisabledAPIKeyStore(fallbackAPIKey: environment["GRAMMARLESS_DEV_API_KEY"])
            )
        }
        return ConfigurationStore()
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp, let button = statusItem.button {
            updateStatusMenuTitles()
            statusItem.menu = statusMenu
            button.performClick(nil)
            statusItem.menu = nil
            return
        }
        openGrammarless()
    }

    @objc private func reanalyze() {
        controller.reanalyzeNow()
    }

    @objc private func openGrammarless() {
        DebugLogger.log("openGrammarless")
        controller.openGrammarlessChat()
    }

    @objc private func runIncreaseImpact() {
        controller.runImpactAnalysisFromMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func applyLaunchFlags() {
        let environment = ProcessInfo.processInfo.environment
        DebugLogger.log("applyLaunchFlags status=\(environment[LaunchFlag.showStatus] ?? "0") settings=\(environment[LaunchFlag.showSettings] ?? "0")")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let shouldShowStatus = environment[LaunchFlag.showStatus] == "1" ||
                (environment[LaunchFlag.showStatus] == nil && self.appModel.qaControlsEnabled)
            if shouldShowStatus {
                self.controller.openGrammarlessSettings()
            }
            if environment[LaunchFlag.showSettings] == "1" {
                self.controller.openGrammarlessSettings()
            }
        }
    }
}

@MainActor
private final class QAAutomationBridge {
    private struct CommandEnvelope: Decodable {
        let id: String
        let command: String
        let location: Int?
        let length: Int?
        let index: Int?
        let action: String?
        let text: String?
    }

    private struct ResponseEnvelope: Encodable {
        let id: String?
        let ok: Bool
        let error: String?
        let state: QAStateSnapshot
        let axDebug: [QAAXApplicationState]?
        let timestamp: String
    }

    private enum Command: String {
        case getState
        case refresh
        case selectRange
        case acceptSuggestion
        case ignoreSuggestion
        case openAIPanel
        case runAIAction
        case replaceAI
        case openSidebar
        case openSettings
        case setLanguage
        case setGhostEnabled
        case newSession
        case selectSession
        case deleteSession
        case sendAgentMessage
        case runAgentAction
        case runImpactAnalysis
        case applyPatch
        case rollbackLastVersion
        case requestGhost
        case acceptGhost
        case rejectGhost
        case focusCandidate
        case typeText
        case dumpAX
    }

    private let controller: GrammarlessController
    private let commandURL: URL
    private let responseURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var timer: Timer?
    private var lastProcessedID: String?
    private var isProcessing = false

    init(controller: GrammarlessController) {
        self.controller = controller
        let environment = ProcessInfo.processInfo.environment
        let tempDir = NSTemporaryDirectory()
        commandURL = URL(fileURLWithPath: environment["GRAMMARLESS_QA_COMMAND_PATH"] ?? (tempDir as NSString).appendingPathComponent("grammarless-qa-command.json"))
        responseURL = URL(fileURLWithPath: environment["GRAMMARLESS_QA_RESPONSE_PATH"] ?? (tempDir as NSString).appendingPathComponent("grammarless-qa-response.json"))
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func start() {
        DebugLogger.log("qa bridge start commandPath=\(self.commandURL.path) responsePath=\(self.responseURL.path)")
        try? FileManager.default.removeItem(at: commandURL)
        try? FileManager.default.removeItem(at: responseURL)
        writeResponse(id: nil, ok: true, error: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
    }

    func stop() {
        DebugLogger.log("qa bridge stop")
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard !isProcessing else { return }
        guard let data = try? Data(contentsOf: commandURL) else { return }
        guard let envelope = try? decoder.decode(CommandEnvelope.self, from: data) else {
            return
        }
        guard envelope.id != lastProcessedID else { return }

        lastProcessedID = envelope.id
        isProcessing = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.handle(envelope)
            self.isProcessing = false
        }
    }

    private func handle(_ envelope: CommandEnvelope) async {
        DebugLogger.log("qa bridge command id=\(envelope.id) command=\(envelope.command)")
        do {
            guard let command = Command(rawValue: envelope.command) else {
                throw BridgeCommandError.unsupportedCommand(envelope.command)
            }

            switch command {
            case .getState:
                break
            case .refresh:
                controller.qaRefresh()
                try? await Task.sleep(nanoseconds: 220_000_000)
            case .selectRange:
                guard let location = envelope.location, let length = envelope.length else {
                    throw BridgeCommandError.missingField("location/length")
                }
                try await controller.qaSelectRange(location: location, length: length)
            case .acceptSuggestion:
                guard let index = envelope.index else {
                    throw BridgeCommandError.missingField("index")
                }
                try await controller.qaAcceptSuggestion(at: index)
            case .ignoreSuggestion:
                guard let index = envelope.index else {
                    throw BridgeCommandError.missingField("index")
                }
                try controller.qaIgnoreSuggestion(at: index)
            case .openAIPanel:
                try await controller.qaOpenAIPanel()
            case .runAIAction:
                guard let rawValue = envelope.action, let action = ReviewAction(rawValue: rawValue) else {
                    throw BridgeCommandError.invalidAction(envelope.action ?? "nil")
                }
                try await controller.qaRunAIAction(action)
            case .replaceAI:
                try await controller.qaReplaceAISelection()
            case .openSidebar:
                try controller.qaOpenLongformSidebar()
            case .openSettings:
                try controller.qaOpenGrammarlessSettings()
            case .setLanguage:
                guard let text = envelope.text else {
                    throw BridgeCommandError.missingField("text")
                }
                try controller.qaSetLanguage(text)
            case .setGhostEnabled:
                guard let text = envelope.text else {
                    throw BridgeCommandError.missingField("text")
                }
                try controller.qaSetGhostEnabled(text)
            case .newSession:
                try controller.qaCreateConversationSession()
            case .selectSession:
                try controller.qaSelectConversationSession(id: envelope.text, index: envelope.index)
            case .deleteSession:
                try controller.qaDeleteConversationSession(id: envelope.text, index: envelope.index)
            case .sendAgentMessage:
                guard let text = envelope.text else {
                    throw BridgeCommandError.missingField("text")
                }
                try await controller.qaSendAgentMessage(text)
            case .runAgentAction:
                guard let rawValue = envelope.action, let action = AgentAction(rawValue: rawValue) else {
                    throw BridgeCommandError.invalidAction(envelope.action ?? "nil")
                }
                try await controller.qaRunAgentAction(action, instruction: envelope.text ?? "")
            case .runImpactAnalysis:
                try await controller.qaRunImpactAnalysis()
            case .applyPatch:
                guard let index = envelope.index else {
                    throw BridgeCommandError.missingField("index")
                }
                try await controller.qaApplyAgentPatch(at: index)
            case .rollbackLastVersion:
                try await controller.qaRollbackLastVersion()
            case .requestGhost:
                try await controller.qaRequestGhostSuggestion()
            case .acceptGhost:
                try await controller.qaAcceptGhostSuggestion()
            case .rejectGhost:
                controller.qaRejectGhostSuggestion()
            case .focusCandidate:
                guard let index = envelope.index else {
                    throw BridgeCommandError.missingField("index")
                }
                try await controller.qaFocusCandidate(at: index)
            case .typeText:
                guard let text = envelope.text else {
                    throw BridgeCommandError.missingField("text")
                }
                try await controller.qaTypeText(text)
            case .dumpAX:
                break
            }

            writeResponse(
                id: envelope.id,
                ok: true,
                error: nil,
                axDebug: command == .dumpAX ? controller.qaAXDebug() : nil
            )
        } catch {
            DebugLogger.log("qa bridge command failed id=\(envelope.id) error=\(error.localizedDescription)")
            writeResponse(id: envelope.id, ok: false, error: error.localizedDescription)
        }
    }

    private func writeResponse(
        id: String?,
        ok: Bool,
        error: String?,
        axDebug: [QAAXApplicationState]? = nil
    ) {
        let response = ResponseEnvelope(
            id: id,
            ok: ok,
            error: error,
            state: controller.qaState(),
            axDebug: axDebug,
            timestamp: Self.timestamp()
        )
        guard let data = try? encoder.encode(response) else { return }
        let tempURL = responseURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tempURL, options: .atomic)
            if FileManager.default.fileExists(atPath: responseURL.path) {
                try? FileManager.default.removeItem(at: responseURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: responseURL)
        } catch {
            DebugLogger.log("qa bridge write response failed error=\(error.localizedDescription)")
        }
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

private enum BridgeCommandError: LocalizedError {
    case unsupportedCommand(String)
    case missingField(String)
    case invalidAction(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedCommand(let command):
            return "Unsupported QA command: \(command)"
        case .missingField(let field):
            return "Missing required field: \(field)"
        case .invalidAction(let action):
            return "Invalid action: \(action)"
        }
    }
}

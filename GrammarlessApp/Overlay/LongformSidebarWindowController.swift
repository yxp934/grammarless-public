import AppKit
import GrammarlessCore
import SwiftUI

private enum GrammarlessSurface: String, Equatable {
    case chat
    case settings
}

private enum ModelCatalogError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "Invalid Base URL"
        case .invalidResponse:
            "Invalid /models response"
        case let .httpStatus(status):
            "HTTP \(status)"
        }
    }
}

private struct ModelCatalogResponse: Decodable {
    struct Model: Decodable {
        let id: String
    }

    let data: [Model]
}

struct LongformSidebarState: Equatable {
    var isVisible: Bool
    var surface: String
    var documentName: String
    var memoryStatus: String
    var apiConnectionStatus: String
    var apiConnectionMessage: String
    var availableModelIDs: [String]
    var uiLanguage: String
    var isGhostTextEnabled: Bool
    var isLoading: Bool
    var errorMessage: String?
    var pendingPatchCount: Int
    var conversationCount: Int
    var toolEventCount: Int
    var impactReportScore: Int?
    var impactReportGenre: String?
    var impactSegmentCount: Int?
    var impactAnalysisFailureCount: Int
    var impactProgress: String
    var canRollback: Bool
    var inputText: String
    var sessionCount: Int
    var activeSessionID: String?
    var activeSessionTitle: String
    var isSessionListVisible: Bool
    var sessions: [ConversationSession]
}

@MainActor
final class LongformSidebarViewModel: ObservableObject {
    @Published var documentName = "—"
    @Published var memoryStatus = "Memory not initialized"
    @Published var instruction = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var conversation: [ConversationTurn] = [] {
        didSet { conversationRevision &+= 1 }
    }
    @Published private(set) var conversationRevision = 0
    @Published var pendingPatches: [TextPatch] = []
    @Published var outline: [String] = []
    @Published var toolEvents: [AgentToolEvent] = []
    @Published var impactReport: DocumentImpactReport?
    @Published var impactReportGeneratedAt: Date?
    @Published var impactProgress = ""
    @Published var canRollback = false
    @Published var lastVersionSummary = ""
    @Published var ghostSummary = ""
    @Published var sessions: [ConversationSession] = []
    @Published var activeSessionID: UUID?
    @Published var isSessionListVisible = false
    @Published private var selectedSurface: GrammarlessSurface = .chat
    @Published var apiConnectionStatus = "idle"
    @Published var apiConnectionMessage = "Not checked"
    @Published var availableModelIDs: [String] = []

    private var activeModelCatalogKey = ""
    private(set) var streamingAssistantTurnID: UUID?

    var activeSessionTitle: String {
        sessions.first(where: { $0.id == activeSessionID })?.title ?? "新会话"
    }

    var hasConversationSurfaceContent: Bool {
        !conversation.isEmpty || !toolEvents.isEmpty || !pendingPatches.isEmpty || !outline.isEmpty || impactReport != nil || !impactProgress.isEmpty || isLoading || errorMessage != nil
    }

    var isCompactInputOnly: Bool {
        selectedSurface == .chat && !hasConversationSurfaceContent && !isSessionListVisible
    }

    var isSettingsVisible: Bool {
        selectedSurface == .settings
    }

    var isStreamingAssistantReply: Bool {
        streamingAssistantTurnID != nil
    }

    var preferredPanelSize: CGSize {
        if isSettingsVisible {
            return CGSize(width: 560, height: 700)
        }
        if isCompactInputOnly {
            return CGSize(width: 560, height: 76)
        }
        return CGSize(width: isSessionListVisible ? 780 : 560, height: 640)
    }

    var stateSnapshot: LongformSidebarState {
        LongformSidebarState(
            isVisible: false,
            surface: selectedSurface.rawValue,
            documentName: documentName,
            memoryStatus: memoryStatus,
            apiConnectionStatus: apiConnectionStatus,
            apiConnectionMessage: apiConnectionMessage,
            availableModelIDs: availableModelIDs,
            uiLanguage: AppConfiguration().uiLanguage.rawValue,
            isGhostTextEnabled: AppConfiguration().isGhostTextEnabled,
            isLoading: isLoading,
            errorMessage: errorMessage,
            pendingPatchCount: pendingPatches.count,
            conversationCount: conversation.count,
            toolEventCount: toolEvents.count,
            impactReportScore: impactReport?.overallScore,
            impactReportGenre: impactReport?.primaryGenre.label,
            impactSegmentCount: impactReport?.segmentation.segments.count,
            impactAnalysisFailureCount: impactReport?.analysisFailures.count ?? 0,
            impactProgress: impactProgress,
            canRollback: canRollback,
            inputText: instruction,
            sessionCount: sessions.count,
            activeSessionID: activeSessionID?.uuidString,
            activeSessionTitle: activeSessionTitle,
            isSessionListVisible: isSessionListVisible,
            sessions: sessions
        )
    }

    func showChat() {
        selectedSurface = .chat
    }

    func showSettings() {
        selectedSurface = .settings
        isSessionListVisible = false
    }

    func beginLoading() {
        isLoading = true
        errorMessage = nil
        streamingAssistantTurnID = nil
    }

    func beginImpactAnalysis(language: GrammarlessLanguageMode) {
        isLoading = true
        errorMessage = nil
        streamingAssistantTurnID = nil
        impactReport = nil
        impactReportGeneratedAt = nil
        impactProgress = language == .zh ? "正在执行 Impact 分析…" : "Running Impact analysis…"
        pendingPatches = []
        outline = []
        toolEvents = []
    }

    func finishLoading() {
        isLoading = false
        streamingAssistantTurnID = nil
    }

    func setError(_ message: String) {
        isLoading = false
        streamingAssistantTurnID = nil
        errorMessage = message
    }

    func clearPending(preservingImpactPatches: Bool = false) {
        pendingPatches = preservingImpactPatches ? currentPendingImpactPatches() : []
        outline = []
        toolEvents = []
        impactProgress = ""
    }

    func replaceStandalonePendingPatches(_ patches: [TextPatch]) {
        let retainedImpactPatches = currentPendingImpactPatches()
        let retainedIDs = Set(retainedImpactPatches.map(\.id))
        pendingPatches = retainedImpactPatches + patches.filter { !retainedIDs.contains($0.id) }
    }

    private func currentPendingImpactPatches() -> [TextPatch] {
        guard let impactReport else { return [] }
        let impactPatchIDs = Set(impactReport.patchCandidates.map(\.id))
        return pendingPatches.filter { impactPatchIDs.contains($0.id) }
    }

    func resetForActiveSession() {
        instruction = ""
        errorMessage = nil
        impactReport = nil
        impactReportGeneratedAt = nil
        streamingAssistantTurnID = nil
        clearPending()
    }

    func upsertStreamingAssistantTurn(
        id: UUID,
        documentID: String,
        createdAt: Date,
        content: String
    ) {
        let turn = ConversationTurn(
            id: id,
            documentID: documentID,
            createdAt: createdAt,
            role: "assistant",
            content: content
        )
        if let existingIndex = conversation.firstIndex(where: { $0.id == id }) {
            conversation[existingIndex] = turn
            conversationRevision &+= 1
        } else {
            conversation.append(turn)
        }
        streamingAssistantTurnID = id
    }

    func clearStreamingAssistantTurn() {
        streamingAssistantTurnID = nil
    }

    func refreshModelCatalog(configuration: AppConfiguration) async {
        let cleanConfiguration = configuration.sanitized()
        let key = [
            cleanConfiguration.baseURL,
            cleanConfiguration.apiKey,
        ].joined(separator: "\u{1f}")
        activeModelCatalogKey = key
        apiConnectionStatus = "checking"
        apiConnectionMessage = "Checking"

        do {
            let models = try await Self.fetchModelIDs(configuration: cleanConfiguration)
            guard activeModelCatalogKey == key else { return }
            availableModelIDs = models
            apiConnectionStatus = "connected"
            apiConnectionMessage = models.isEmpty ? "Connected · no models returned" : "Connected"
        } catch {
            guard activeModelCatalogKey == key else { return }
            availableModelIDs = []
            apiConnectionStatus = "failed"
            apiConnectionMessage = error.localizedDescription
        }
    }

    private static func fetchModelIDs(configuration: AppConfiguration) async throws -> [String] {
        let cleanConfiguration = configuration.sanitized()
        let baseURL = cleanConfiguration.baseURL
        guard !baseURL.isEmpty, let url = URL(string: "\(baseURL)/models") else {
            throw ModelCatalogError.invalidBaseURL
        }

        var request = URLRequest(url: url, timeoutInterval: max(4, min(20, cleanConfiguration.reviewTimeoutSeconds)))
        request.httpMethod = "GET"
        let apiKey = cleanConfiguration.apiKey
        if !apiKey.isEmpty {
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ModelCatalogError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw ModelCatalogError.httpStatus(httpResponse.statusCode)
        }
        let decoded = try JSONDecoder().decode(ModelCatalogResponse.self, from: data)
        return decoded.data.map(\.id).filter { !$0.isEmpty }.sorted()
    }
}

private struct LongformSidebarView: View {
    @ObservedObject var viewModel: LongformSidebarViewModel
    @ObservedObject var configurationStore: ConfigurationStore
    @ObservedObject var appModel: AppModel
    let sendMessage: (String) -> Void
    let applyPatch: (UUID) -> Void
    let applyAllPatches: () -> Void
    let rejectPatch: (UUID) -> Void
    let runImpactAnalysis: () -> Void
    let rollback: () -> Void
    let redo: () -> Void
    let newSession: () -> Void
    let selectSession: (UUID) -> Void
    let deleteSession: (UUID) -> Void
    let reanalyzeFocusedText: () -> Void
    let quitGrammarless: () -> Void
    let requestLayout: () -> Void
    let close: () -> Void

    @State private var isAPIKeyVisible = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                .fill(panelBackground)

            panelContent
                .frame(width: viewModel.preferredPanelSize.width, height: viewModel.preferredPanelSize.height)
                .background(panelBackground)
                .clipShape(RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous))

            RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                .stroke(GrammarlessTheme.strongBorder, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .frame(width: viewModel.preferredPanelSize.width, height: viewModel.preferredPanelSize.height)
        .background(Color.clear)
    }

    @ViewBuilder
    private var panelContent: some View {
        Group {
            if viewModel.isSettingsVisible {
                settingsPanel
            } else if viewModel.isCompactInputOnly {
                compactInputBar
            } else {
                expandedConversationPanel
            }
        }
    }

    private var panelBackground: Color {
        settingsBackground
    }

    private var panelCornerRadius: CGFloat {
        if viewModel.isCompactInputOnly { return GrammarlessTheme.panelRadius + 6 }
        if viewModel.isSettingsVisible { return GrammarlessTheme.panelRadius + 4 }
        return GrammarlessTheme.panelRadius
    }

    private var settingsBackground: Color {
        GrammarlessTheme.panel
    }

    private var settingsCardBackground: Color {
        GrammarlessTheme.card
    }

    private var settingsInputBackground: Color {
        GrammarlessTheme.input
    }

    private var settingsBorder: Color {
        GrammarlessTheme.border
    }

    private var settingsMutedText: Color {
        GrammarlessTheme.mutedInk
    }

    private var compactInputBar: some View {
        HStack(spacing: 10) {
            grammarlessAvatar(size: 32)
            TextField(ui("Ask Grammarless or tell it to edit your draft", zh: "询问 Grammarless 或让它修改文稿"), text: $viewModel.instruction)
                .textFieldStyle(.plain)
                .font(.system(size: 14.5))
                .onSubmit(sendCurrentMessage)
                .disabled(viewModel.isLoading)
                .accessibilityIdentifier("grammarless-chat-input")
            Button(action: expandConversationPanel) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.grammarlessInteractive)
            .help(ui("Open conversation", zh: "展开对话"))
            .accessibilityIdentifier("grammarless-session-toggle")
            Button(action: showSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.grammarlessInteractive)
            .help(ui("Settings", zh: "设置"))
            .accessibilityIdentifier("grammarless-settings-open-compact")
            Button(action: newSession) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.grammarlessInteractive)
            .disabled(viewModel.isLoading)
            .help(ui("New chat", zh: "新建会话"))
            .accessibilityIdentifier("grammarless-session-new")
            Button(action: runImpactAnalysis) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.grammarlessInteractive)
            .disabled(viewModel.isLoading)
            .help(ui("Increase Impact", zh: "提升影响力"))
            .accessibilityIdentifier("grammarless-impact-run-compact")
            sendButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var expandedConversationPanel: some View {
        HStack(spacing: 0) {
            if viewModel.isSessionListVisible {
                sessionSidebar
                    .frame(width: 220)
                Divider()
            }
            VStack(spacing: 0) {
                header
                Divider()
                transcript
                Divider()
                composer
                footer
            }
        }
    }

    private var sessionSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(ui("Chats", zh: "会话"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: newSession) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                }
                .buttonStyle(.grammarlessInteractive)
                .disabled(viewModel.isLoading)
                .help(ui("New chat", zh: "新建会话"))
                .accessibilityIdentifier("grammarless-session-new-sidebar")
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(viewModel.sessions) { session in
                        sessionRow(session)
                    }
                }
                .padding(.vertical, 2)
            }
            Text(viewModel.memoryStatus)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(12)
        .background(settingsCardBackground.opacity(0.58))
        .accessibilityIdentifier("grammarless-session-list")
    }

    private func sessionRow(_ session: ConversationSession) -> some View {
        let isActive = session.id == viewModel.activeSessionID
        return HStack(spacing: 8) {
            Button(action: { selectSession(session.id) }) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(localizedSessionTitle(session.title))
                        .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                        .lineLimit(1)
                    Text(relativeSessionTime(session.updatedAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.grammarlessInteractive)
            .disabled(viewModel.isLoading)
            .accessibilityIdentifier("grammarless-session-row-\(session.id.uuidString)")
            Button(action: { deleteSession(session.id) }) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.grammarlessInteractive)
            .disabled(viewModel.sessions.count <= 1 || viewModel.isLoading)
            .help(ui("Delete chat", zh: "删除会话"))
            .accessibilityIdentifier("grammarless-session-delete-\(session.id.uuidString)")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(isActive ? GrammarlessTheme.softAqua : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: GrammarlessTheme.controlRadius, style: .continuous)
                .stroke(isActive ? GrammarlessTheme.strongBorder : Color.clear, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GrammarlessTheme.controlRadius, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: toggleSessionList) {
                Image(systemName: viewModel.isSessionListVisible ? "sidebar.left" : "sidebar.left")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.grammarlessInteractive)
            .help(ui("Show or hide chats", zh: "显示/隐藏会话"))
            .accessibilityIdentifier("grammarless-session-toggle-header")
            grammarlessAvatar(size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(localizedSessionTitle(viewModel.activeSessionTitle))
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(viewModel.documentName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: runImpactAnalysis) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.grammarlessInteractive)
            .help(ui("Increase Impact", zh: "提升影响力"))
            .disabled(viewModel.isLoading)
            .accessibilityIdentifier("grammarless-impact-run")
            Button(action: newSession) {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.grammarlessInteractive)
            .help(ui("New chat", zh: "新建会话"))
            .disabled(viewModel.isLoading)
            .accessibilityIdentifier("grammarless-session-new-header")
            Button(action: redo) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.grammarlessInteractive)
            .help(ui("Redo", zh: "一键重做"))
            .disabled(viewModel.isLoading)
            .accessibilityIdentifier("grammarless-chat-redo")
            Button(action: showSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.grammarlessInteractive)
            .help(ui("Settings", zh: "设置"))
            .accessibilityIdentifier("grammarless-settings-open")
            Button(action: close) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.grammarlessInteractive)
            .help(ui("Close", zh: "关闭"))
            .accessibilityIdentifier("grammarless-chat-close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if visibleConversation.isEmpty,
                       viewModel.toolEvents.isEmpty,
                       standalonePendingPatches.isEmpty,
                       viewModel.impactReport == nil,
                       !viewModel.isLoading,
                       viewModel.errorMessage == nil
                    {
                        emptyPrompt
                    }

                    ForEach(preImpactConversation) { turn in
                        chatBubble(turn)
                            .id(turn.id)
                    }

                    if viewModel.isLoading, !viewModel.isStreamingAssistantReply {
                        loadingRow.id("loading")
                    }

                    if let error = viewModel.errorMessage, !error.isEmpty {
                        errorCard(error).id("error")
                    }

                    if !viewModel.impactProgress.isEmpty {
                        impactProgressCard.id("impact-progress")
                    }

                    if let impactReport = viewModel.impactReport {
                        impactReportCard(impactReport).id("impact-report")
                    }

                    ForEach(postImpactConversation) { turn in
                        chatBubble(turn)
                            .id(turn.id)
                    }

                    if !viewModel.toolEvents.isEmpty {
                        toolTimeline.id("tools")
                    }

                    if !viewModel.outline.isEmpty {
                        outlineCard.id("outline")
                    }

                    if !standalonePendingPatches.isEmpty {
                        patchPreviewSection(standalonePendingPatches).id("patches")
                    }

                    if !viewModel.lastVersionSummary.isEmpty {
                        lastVersionCard
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: viewModel.conversation.count) { _ in scrollToBottom(proxy) }
            .onChange(of: viewModel.conversationRevision) { _ in scrollToBottom(proxy) }
            .onChange(of: viewModel.toolEvents.count) { _ in scrollToBottom(proxy) }
            .onChange(of: viewModel.pendingPatches.count) { _ in scrollToBottom(proxy) }
            .onChange(of: viewModel.isLoading) { _ in scrollToBottom(proxy) }
        }
    }

    private var visibleConversation: [ConversationTurn] {
        viewModel.conversation.filter { turn in
            !["impact_context", "tool_context"].contains(turn.role.lowercased())
        }
    }

    private var preImpactConversation: [ConversationTurn] {
        guard let generatedAt = viewModel.impactReportGeneratedAt, viewModel.impactReport != nil else {
            return visibleConversation
        }
        return visibleConversation.filter { $0.createdAt <= generatedAt }
    }

    private var postImpactConversation: [ConversationTurn] {
        guard let generatedAt = viewModel.impactReportGeneratedAt, viewModel.impactReport != nil else {
            return []
        }
        return visibleConversation.filter { $0.createdAt > generatedAt }
    }

    private var standalonePendingPatches: [TextPatch] {
        guard let report = viewModel.impactReport else {
            return viewModel.pendingPatches
        }
        let impactPatchIDs = Set(report.patchCandidates.map(\.id))
        return viewModel.pendingPatches.filter { !impactPatchIDs.contains($0.id) }
    }

    private var emptyPrompt: some View {
        VStack(alignment: .center, spacing: 10) {
            grammarlessAvatar(size: 38)
            Text(ui("How should Grammarless help?", zh: "想让 Grammarless 怎么帮你？"))
                .font(.system(size: 16, weight: .semibold))
            Text(ui(
                "Describe the goal. The model will decide whether to read, draft, preview diffs, or wait for your confirmation. You can also run Impact to analyze the whole draft.",
                zh: "输入需求后，模型会自行决定是否读取、起草、预览差异或等待你确认应用。也可以点击 Impact 一键分析全文影响力。"
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            Image(systemName: "paperclip")
                .foregroundStyle(.secondary)
            TextField(ui("Ask Grammarless or tell it to edit your draft", zh: "询问 Grammarless 或让它修改文稿"), text: $viewModel.instruction)
                .textFieldStyle(.plain)
                .font(.system(size: 14.5))
                .onSubmit(sendCurrentMessage)
                .disabled(viewModel.isLoading)
                .accessibilityIdentifier("grammarless-chat-input")
            Button(action: {}) {
                Image(systemName: "mic")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.grammarlessInteractive)
            .disabled(true)
            sendButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(settingsInputBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(GrammarlessTheme.border, lineWidth: 1)
        )
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var footer: some View {
        Text(ui("AI-generated content. Review before using.", zh: "内容由 AI 生成，请自行判断后使用。"))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
    }

    private var sendButton: some View {
        Button(action: sendCurrentMessage) {
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(canSend ? GrammarlessTheme.aquaInk : GrammarlessTheme.softInk)
                .clipShape(Circle())
                .overlay(Circle().stroke(canSend ? GrammarlessTheme.aqua.opacity(0.78) : GrammarlessTheme.border, lineWidth: 1))
        }
        .buttonStyle(.grammarlessInteractive)
        .disabled(!canSend)
        .help(ui("Send", zh: "发送"))
        .accessibilityIdentifier("grammarless-chat-send")
    }

    private var canSend: Bool {
        !viewModel.isLoading && !viewModel.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendCurrentMessage() {
        let text = viewModel.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !viewModel.isLoading else { return }
        if viewModel.isCompactInputOnly {
            newSession()
        }
        viewModel.beginLoading()
        sendMessage(text)
        viewModel.instruction = ""
    }

    private func grammarlessAvatar(size: CGFloat) -> some View {
        Text("G")
            .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
            .foregroundStyle(GrammarlessTheme.ink)
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [
                        GrammarlessTheme.aqua,
                        GrammarlessTheme.gold,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(Circle())
            .overlay(Circle().stroke(GrammarlessTheme.strongBorder, lineWidth: 1))
    }

    private var settingsPanel: some View {
        VStack(spacing: 0) {
            settingsHeader
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    behaviorSettingsCard
                    apiSettingsCard
                    timingSettingsCard
                    runtimeStatusCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            settingsActions
        }
        .background(settingsBackground)
        .accessibilityIdentifier("grammarless-settings-view")
        .task(id: modelCatalogRefreshKey) {
            await viewModel.refreshModelCatalog(configuration: configuration)
        }
    }

    private var settingsHeader: some View {
        HStack(spacing: 18) {
            Button(action: showChat) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(width: 30, height: 30)
                    .background(settingsInputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: GrammarlessTheme.controlRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: GrammarlessTheme.controlRadius, style: .continuous)
                            .stroke(GrammarlessTheme.border, lineWidth: 1)
                    )
                    .shadow(color: GrammarlessTheme.aqua.opacity(0.16), radius: 10, x: 0, y: 4)
            }
            .buttonStyle(.grammarlessInteractive)
            .help(ui("Back to Grammarless", zh: "返回 Grammarless"))
            .accessibilityIdentifier("grammarless-settings-back-to-chat")

            grammarlessAvatar(size: 34)

                VStack(alignment: .leading, spacing: 4) {
                    Text(ui("Settings", zh: "设置"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Grammarless · \(displayDocumentName)")
                    .font(.system(size: 10.8, weight: .regular))
                    .foregroundStyle(settingsMutedText)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(width: 30, height: 30)
                    .background(settingsInputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: GrammarlessTheme.controlRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: GrammarlessTheme.controlRadius, style: .continuous)
                            .stroke(GrammarlessTheme.border, lineWidth: 1)
                    )
                    .shadow(color: GrammarlessTheme.aqua.opacity(0.16), radius: 10, x: 0, y: 4)
            }
            .buttonStyle(.grammarlessInteractive)
            .help(ui("Close", zh: "关闭"))
            .accessibilityIdentifier("grammarless-settings-close")
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 17)
    }

    private var behaviorSettingsCard: some View {
        settingsCard {
            Label {
                Text(ui("Behavior", zh: "功能与语言"))
                    .font(.system(size: 13.2, weight: .semibold))
            } icon: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .regular))
            }

            settingsRow(ui("Interface language", zh: "界面语言")) {
                Picker("", selection: configBinding(\.uiLanguage)) {
                    Text(ui("Chinese", zh: "中文")).tag(GrammarlessLanguageMode.zh)
                    Text(ui("English", zh: "英文")).tag(GrammarlessLanguageMode.en)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("grammarless-settings-ui-language")
            }

            settingsRow(ui("Ghost text", zh: "Ghost 预测")) {
                Button {
                    configurationStore.update { $0.isGhostTextEnabled.toggle() }
                } label: {
                    HStack(spacing: 9) {
                        Text(configuration.isGhostTextEnabled ? ui("On", zh: "开启") : ui("Off", zh: "关闭"))
                            .font(.system(size: 11.2, weight: .medium))
                            .foregroundStyle(configuration.isGhostTextEnabled ? GrammarlessTheme.aquaInk : settingsMutedText)
                        Spacer()
                        Capsule()
                            .fill(configuration.isGhostTextEnabled ? GrammarlessTheme.aquaInk : GrammarlessTheme.softInk)
                            .frame(width: 36, height: 20)
                            .overlay(alignment: configuration.isGhostTextEnabled ? .trailing : .leading) {
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 16, height: 16)
                                    .padding(.horizontal, 2)
                                    .shadow(color: GrammarlessTheme.panelShadow, radius: 2, x: 0, y: 1)
                            }
                    }
                    .settingsInputChrome()
                }
                .buttonStyle(.grammarlessInteractive)
                .accessibilityIdentifier("grammarless-settings-ghost-toggle")
            }

            Text(ui(
                "Language controls every UI label and model reply. English mode disables the offline Chinese proofreading.",
                zh: "语言会同步控制所有界面文字和模型回复；英文模式会关闭离线中文校对。"
            ))
            .font(.system(size: 9.8))
            .foregroundStyle(settingsMutedText)
            .padding(.top, 2)
        }
        .accessibilityIdentifier("grammarless-settings-behavior-card")
    }

    private var apiSettingsCard: some View {
        settingsCard {
            HStack(alignment: .center) {
                Label {
                    Text(ui("OpenAI-compatible API", zh: "OpenAI 兼容 API"))
                        .font(.system(size: 13.2, weight: .semibold))
                } icon: {
                    Image(systemName: "globe")
                        .font(.system(size: 16, weight: .regular))
                }
                Spacer()
                connectionBadge
            }

            settingsRow(ui("Base URL", zh: "基础 URL")) {
                HStack(spacing: 8) {
                    TextField(ui("Base URL", zh: "基础 URL"), text: configBinding(\.baseURL))
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.2))
                        .accessibilityIdentifier("grammarless-settings-base-url")
                    if !configuration.baseURL.isEmpty {
                        Button {
                            configurationStore.update { $0.baseURL = "" }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.grammarlessInteractive)
                        .accessibilityIdentifier("grammarless-settings-base-url-clear")
                    }
                }
                .settingsInputChrome()
            }

            settingsRow(ui("API Key", zh: "API 密钥")) {
                HStack(spacing: 8) {
                    Group {
                        if isAPIKeyVisible {
                            TextField(ui("API Key", zh: "API 密钥"), text: configBinding(\.apiKey))
                                .accessibilityIdentifier("grammarless-settings-api-key-visible")
                        } else {
                            SecureField(ui("API Key", zh: "API 密钥"), text: configBinding(\.apiKey))
                                .accessibilityIdentifier("grammarless-settings-api-key")
                        }
                    }
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.2))

                    Divider()

                    Button {
                        isAPIKeyVisible.toggle()
                    } label: {
                        Image(systemName: isAPIKeyVisible ? "eye.slash" : "eye")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.grammarlessInteractive)
                    .accessibilityIdentifier("grammarless-settings-api-key-toggle")
                }
                .settingsInputChrome()
            }

            settingsRow(ui("Model", zh: "模型")) {
                Menu {
                    if viewModel.availableModelIDs.isEmpty {
                        Text(modelMenuEmptyText)
                    } else {
                        ForEach(viewModel.availableModelIDs, id: \.self) { modelID in
                            Button(modelID) {
                                configurationStore.update { $0.model = modelID }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Text(configuration.model.isEmpty ? ui("No model selected", zh: "未选择模型") : configuration.model)
                            .font(.system(size: 11.2))
                            .foregroundStyle(configuration.model.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(GrammarlessTheme.aquaInk)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .settingsInputChrome()
                }
                .menuStyle(.borderlessButton)
                .interactiveHover()
                .accessibilityIdentifier("grammarless-settings-model-menu")
            }

            Text(ui("Used for review, ghost suggestions, and rewrite actions.", zh: "用于审阅、Ghost 预测和改写操作。"))
                .font(.system(size: 9.8))
                .foregroundStyle(settingsMutedText)
                .padding(.top, 2)
        }
        .accessibilityIdentifier("grammarless-settings-api-card")
    }

    private var timingSettingsCard: some View {
        settingsCard {
            Label {
                Text(ui("Timing", zh: "时间"))
                    .font(.system(size: 13.2, weight: .semibold))
            } icon: {
                Image(systemName: "clock")
                    .font(.system(size: 16, weight: .regular))
            }

            HStack(alignment: .top, spacing: 24) {
                timingControl(
                    title: ui("Debounce", zh: "防抖"),
                    suffix: "ms",
                    intValue: configBinding(\.debounceMilliseconds),
                    range: 100 ... 5_000,
                    step: 100,
                    identifier: "grammarless-settings-debounce"
                )
                timingControl(
                    title: ui("Review Timeout", zh: "审阅超时"),
                    suffix: "s",
                    doubleValue: configBinding(\.reviewTimeoutSeconds),
                    range: 1 ... 120,
                    step: 1,
                    identifier: "grammarless-settings-review-timeout"
                )
                timingControl(
                    title: ui("Action Timeout", zh: "操作超时"),
                    suffix: "s",
                    doubleValue: configBinding(\.actionTimeoutSeconds),
                    range: 1 ... 180,
                    step: 1,
                    identifier: "grammarless-settings-action-timeout"
                )
            }

            Text(ui("Control responsiveness and timeouts for background operations.", zh: "控制后台操作的响应速度和超时时间。"))
                .font(.system(size: 9.8))
                .foregroundStyle(settingsMutedText)
                .padding(.top, 2)
        }
        .accessibilityIdentifier("grammarless-settings-timing-card")
    }

    private var runtimeStatusCard: some View {
        settingsCard {
            Label {
                Text(ui("Runtime Status", zh: "运行状态"))
                    .font(.system(size: 13.2, weight: .semibold))
            } icon: {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 16, weight: .regular))
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 0) {
                    statusRow(
                        icon: "person.crop.circle",
                        label: ui("Accessibility", zh: "辅助功能权限"),
                        value: appModel.accessibilityAuthorized ? ui("Granted", zh: "已授权") : ui("Missing", zh: "缺失"),
                        isPill: true,
                        isGood: appModel.accessibilityAuthorized
                    )
                    statusRow(icon: "display", label: ui("Frontmost App", zh: "前台应用"), value: appModel.frontmostApp)
                    statusRow(icon: "viewfinder", label: ui("Focused Role", zh: "焦点角色"), value: appModel.focusedElementRole)
                }
                .settingsStatusColumn()

                VStack(spacing: 0) {
                    statusRow(
                        icon: "sparkles",
                        label: ui("LLM", zh: "模型"),
                        value: llmStatusText,
                        isPill: true,
                        isGood: !llmStatusText.lowercased().contains("failed")
                    )
                    statusRow(icon: "cylinder", label: ui("Memory", zh: "记忆"), value: memoryStatusText)
                    statusRow(icon: "textformat.size", label: ui("Selection", zh: "选区预览"), value: selectionPreview)
                }
                .settingsStatusColumn()
            }

            Text(ui("Live diagnostics for accessibility, focus, and runtime health.", zh: "辅助功能、焦点与运行健康的实时诊断。"))
                .font(.system(size: 9.8))
                .foregroundStyle(settingsMutedText)
                .padding(.top, 2)
        }
        .accessibilityIdentifier("grammarless-settings-runtime-card")
    }

    private var settingsActions: some View {
        VStack(spacing: 10) {
            Rectangle()
                .fill(GrammarlessTheme.border)
                .frame(height: 1)
            HStack(spacing: 16) {
                Button(action: reanalyzeFocusedText) {
                    Label(ui("Reanalyze Focused Text", zh: "重新分析焦点文本"), systemImage: "arrow.clockwise")
                        .font(.system(size: 11.2, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                }
                .buttonStyle(.grammarlessInteractive)
                .foregroundStyle(.white)
                .background(GrammarlessTheme.aquaInk)
                .clipShape(RoundedRectangle(cornerRadius: GrammarlessTheme.smallRadius, style: .continuous))
                .interactiveHover()
                .accessibilityIdentifier("grammarless-settings-reanalyze")

                Button {
                    configurationStore.reset()
                    Task {
                        await viewModel.refreshModelCatalog(configuration: configurationStore.configuration)
                    }
                } label: {
                    Text(ui("Reset Defaults", zh: "恢复默认"))
                        .font(.system(size: 11.2, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                }
                .buttonStyle(.grammarlessInteractive)
                .foregroundStyle(GrammarlessTheme.aquaInk)
                .interactiveHover()
                .accessibilityIdentifier("grammarless-settings-reset")

                Button(action: quitGrammarless) {
                    Text(ui("Quit Grammarless", zh: "退出 Grammarless"))
                        .font(.system(size: 11.2, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                }
                .buttonStyle(.grammarlessInteractive)
                .foregroundStyle(GrammarlessTheme.error)
                .overlay(
                    RoundedRectangle(cornerRadius: GrammarlessTheme.smallRadius, style: .continuous)
                        .stroke(GrammarlessTheme.error.opacity(0.75), lineWidth: 1)
                )
                .interactiveHover()
                .accessibilityIdentifier("grammarless-settings-quit")
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 13)
    }

    private var connectionBadge: some View {
        HStack(spacing: 7) {
            if viewModel.apiConnectionStatus == "checking" {
                ProgressView()
                    .controlSize(.small)
            } else {
                Circle()
                    .fill(connectionTint)
                    .frame(width: 8, height: 8)
            }
            Text(connectionLabel)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(connectionTint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(connectionTint.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(connectionTint.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier("grammarless-settings-connection-status")
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(settingsCardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(settingsBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func settingsRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.system(size: 11.2, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 132, alignment: .leading)
            content()
        }
    }

    private func timingControl(
        title: String,
        suffix: String,
        intValue: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10.2))
                .foregroundStyle(.primary)
            HStack(spacing: 8) {
                TextField("", value: intValue, format: .number)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10.8))
                    .frame(width: 72)
                    .accessibilityIdentifier(identifier)
                Stepper("", value: intValue, in: range, step: step)
                    .labelsHidden()
                    .frame(width: 22)
                Text(suffix)
                    .font(.system(size: 10.2))
                    .foregroundStyle(.primary)
            }
            .settingsSmallInputChrome()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timingControl(
        title: String,
        suffix: String,
        doubleValue: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10.2))
                .foregroundStyle(.primary)
            HStack(spacing: 8) {
                TextField("", value: doubleValue, format: .number)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10.8))
                    .frame(width: 72)
                    .accessibilityIdentifier(identifier)
                Stepper("", value: doubleValue, in: range, step: step)
                    .labelsHidden()
                    .frame(width: 22)
                Text(suffix)
                    .font(.system(size: 10.2))
                    .foregroundStyle(.primary)
            }
            .settingsSmallInputChrome()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusRow(
        icon: String,
        label: String,
        value: String,
        isPill: Bool = false,
        isGood: Bool = true
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(icon == "person.crop.circle" ? GrammarlessTheme.aquaInk : GrammarlessTheme.ink)
                .frame(width: 20)
            Text(label)
                .font(.system(size: 10.2))
                .lineLimit(1)
            Spacer(minLength: 8)
            if isPill {
                Text(value)
                    .font(.system(size: 10.2, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundStyle(isGood ? GrammarlessTheme.aquaInk : GrammarlessTheme.error)
                    .background((isGood ? GrammarlessTheme.aqua : GrammarlessTheme.error).opacity(0.13))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                Text(value.isEmpty ? "—" : value)
                    .font(.system(size: 10.2))
                    .foregroundStyle(.primary.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(height: 31)
        .padding(.horizontal, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(GrammarlessTheme.border)
                .frame(height: 1)
        }
    }

    private var configuration: AppConfiguration {
        configurationStore.configuration
    }

    private var uiLanguage: GrammarlessLanguageMode {
        configuration.uiLanguage
    }

    private func ui(_ english: String, zh chinese: String) -> String {
        uiLanguage == .zh ? chinese : english
    }

    private func localizedSessionTitle(_ title: String) -> String {
        title == "新会话" ? ui("New chat", zh: "新会话") : title
    }

    private var modelCatalogRefreshKey: String {
        "\(configuration.baseURL)\u{1f}\(configuration.apiKey)"
    }

    private var displayDocumentName: String {
        viewModel.documentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "—" : viewModel.documentName
    }

    private var modelMenuEmptyText: String {
        switch viewModel.apiConnectionStatus {
        case "checking":
            ui("Loading live models…", zh: "正在加载实时模型…")
        case "failed":
            ui("No live models: \(viewModel.apiConnectionMessage)", zh: "无实时模型：\(viewModel.apiConnectionMessage)")
        default:
            ui("No live models returned", zh: "未返回实时模型")
        }
    }

    private var connectionLabel: String {
        switch viewModel.apiConnectionStatus {
        case "connected":
            ui("Connected", zh: "已连接")
        case "checking":
            ui("Checking", zh: "检查中")
        case "failed":
            ui("Disconnected", zh: "未连接")
        default:
            ui("Not checked", zh: "未检查")
        }
    }

    private var connectionTint: Color {
        switch viewModel.apiConnectionStatus {
        case "connected":
            GrammarlessTheme.aquaInk
        case "failed":
            GrammarlessTheme.error
        case "checking":
            GrammarlessTheme.goldInk
        default:
            .secondary
        }
    }

    private var llmStatusText: String {
        switch appModel.llmStatus {
        case .idle:
            ui("OK · Idle", zh: "正常 · 空闲")
        case let .running(message):
            ui("Running · \(message)", zh: "运行中 · \(message)")
        case let .success(message):
            ui("OK · \(message)", zh: "正常 · \(message)")
        case let .failed(message):
            ui("Failed · \(message)", zh: "失败 · \(message)")
        }
    }

    private var memoryStatusText: String {
        let text = viewModel.memoryStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("sqlite memory:") {
            return ui("SQLite ready", zh: "SQLite 就绪")
        }
        return text.isEmpty ? "—" : text
    }

    private var selectionPreview: String {
        let text = appModel.selectionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "—" }
        if text.count <= 32 {
            return text
        }
        return "\(text.prefix(32))…"
    }

    private func configBinding<Value>(_ keyPath: WritableKeyPath<AppConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { configuration[keyPath: keyPath] },
            set: { newValue in
                configurationStore.update { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    private func toggleSessionList() {
        viewModel.showChat()
        viewModel.isSessionListVisible.toggle()
        requestLayout()
    }

    private func expandConversationPanel() {
        viewModel.showChat()
        viewModel.isSessionListVisible = true
        requestLayout()
    }

    private func showSettings() {
        viewModel.showSettings()
        requestLayout()
    }

    private func showChat() {
        viewModel.showChat()
        requestLayout()
    }

    private func chatBubble(_ turn: ConversationTurn) -> some View {
        let isUser = turn.role.lowercased() == "user"
        let isSystem = turn.role.lowercased() == "system"
        return HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 72) }
            if !isUser, !isSystem { grammarlessAvatar(size: 24) }
            VStack(alignment: .leading, spacing: 5) {
                if isSystem {
                    Text(turn.content)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    if isUser {
                        Text(turn.content)
                            .font(.system(size: 14))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    } else {
                        MarkdownBubbleContent(markdown: turn.content)
                    }
                    Text(timeString(turn.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .opacity(0.75)
                }
            }
            .padding(.horizontal, isSystem ? 0 : 12)
            .padding(.vertical, isSystem ? 0 : 9)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSystem ? Color.clear : (isUser ? GrammarlessTheme.softAqua : Color.clear))
            )
            if !isUser { Spacer(minLength: 72) }
        }
    }

    private struct MarkdownBubbleContent: View {
        let markdown: String

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(MarkdownBubbleBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }

        @ViewBuilder
        private func blockView(_ block: MarkdownBubbleBlock) -> some View {
            switch block {
            case let .paragraph(text):
                inlineMarkdownText(text)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            case let .unorderedList(items):
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•")
                                .font(.system(size: 14, weight: .semibold))
                            inlineMarkdownText(item)
                                .font(.system(size: 14))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            case let .orderedList(items):
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1).")
                                .font(.system(size: 14, weight: .semibold))
                            inlineMarkdownText(item)
                                .font(.system(size: 14))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            case let .codeBlock(code):
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(GrammarlessTheme.softAqua)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        private func inlineMarkdownText(_ text: String) -> Text {
            if let attributed = try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                return Text(attributed)
            }
            return Text(text)
        }
    }

    private enum MarkdownBubbleBlock: Hashable {
        case paragraph(String)
        case unorderedList([String])
        case orderedList([String])
        case codeBlock(String)

        static func parse(_ markdown: String) -> [MarkdownBubbleBlock] {
            let normalized = markdown
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            let lines = normalized.components(separatedBy: "\n")

            var blocks: [MarkdownBubbleBlock] = []
            var paragraphLines: [String] = []
            var unorderedItems: [String] = []
            var orderedItems: [String] = []
            var codeLines: [String] = []
            var isInsideCodeFence = false

            func flushParagraph() {
                guard !paragraphLines.isEmpty else { return }
                let paragraph = paragraphLines.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !paragraph.isEmpty {
                    blocks.append(.paragraph(paragraph))
                }
                paragraphLines.removeAll(keepingCapacity: true)
            }

            func flushLists() {
                if !unorderedItems.isEmpty {
                    blocks.append(.unorderedList(unorderedItems))
                    unorderedItems.removeAll(keepingCapacity: true)
                }
                if !orderedItems.isEmpty {
                    blocks.append(.orderedList(orderedItems))
                    orderedItems.removeAll(keepingCapacity: true)
                }
            }

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if trimmed.hasPrefix("```") {
                    flushParagraph()
                    flushLists()
                    if isInsideCodeFence {
                        blocks.append(.codeBlock(codeLines.joined(separator: "\n")))
                        codeLines.removeAll(keepingCapacity: true)
                    }
                    isInsideCodeFence.toggle()
                    continue
                }

                if isInsideCodeFence {
                    codeLines.append(line)
                    continue
                }

                if trimmed.isEmpty {
                    flushParagraph()
                    flushLists()
                    continue
                }

                if let item = unorderedListItem(from: trimmed) {
                    flushParagraph()
                    if !orderedItems.isEmpty {
                        blocks.append(.orderedList(orderedItems))
                        orderedItems.removeAll(keepingCapacity: true)
                    }
                    unorderedItems.append(item)
                    continue
                }

                if let item = orderedListItem(from: trimmed) {
                    flushParagraph()
                    if !unorderedItems.isEmpty {
                        blocks.append(.unorderedList(unorderedItems))
                        unorderedItems.removeAll(keepingCapacity: true)
                    }
                    orderedItems.append(item)
                    continue
                }

                flushLists()
                paragraphLines.append(line)
            }

            flushParagraph()
            flushLists()

            if isInsideCodeFence {
                blocks.append(.codeBlock(codeLines.joined(separator: "\n")))
            }

            return blocks.isEmpty ? [.paragraph(markdown)] : blocks
        }

        private static func unorderedListItem(from line: String) -> String? {
            guard line.count >= 3 else { return nil }
            let prefix = line.prefix(2)
            guard ["- ", "* ", "+ "].contains(String(prefix)) else { return nil }
            let item = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            return item.isEmpty ? nil : item
        }

        private static func orderedListItem(from line: String) -> String? {
            guard let dotIndex = line.firstIndex(of: ".") else { return nil }
            let numberPart = line[..<dotIndex]
            guard !numberPart.isEmpty, numberPart.allSatisfy({ $0.isNumber }) else { return nil }
            let rest = line[line.index(after: dotIndex)...]
            guard rest.first == " " else { return nil }
            let item = rest.trimmingCharacters(in: .whitespaces)
            return item.isEmpty ? nil : item
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text(ui("The model is choosing and calling tools…", zh: "模型正在选择并调用工具…"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(10)
        .background(GrammarlessTheme.softAqua)
        .clipShape(RoundedRectangle(cornerRadius: GrammarlessTheme.cardRadius, style: .continuous))
    }

    private func errorCard(_ error: String) -> some View {
        Text(error)
            .font(.footnote)
            .foregroundStyle(GrammarlessTheme.error)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GrammarlessTheme.error.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: GrammarlessTheme.cardRadius))
    }

    private var impactProgressCard: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text(ui("Increase Impact", zh: "提升影响力"))
                    .font(.caption.weight(.semibold))
                Text(viewModel.impactProgress)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(GrammarlessTheme.softAqua)
        .clipShape(RoundedRectangle(cornerRadius: GrammarlessTheme.cardRadius, style: .continuous))
    }

    private func impactReportCard(_ report: DocumentImpactReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ui("Increase Impact", zh: "提升影响力"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(genreLabel(report.primaryGenre))
                        .font(.system(size: 16, weight: .semibold))
                    Text(ui("Analyzed \(report.segmentation.segments.count) segments · \(report.documentLengthUTF16) UTF-16", zh: "已分析 \(report.segmentation.segments.count) 个段落 · \(report.documentLengthUTF16) UTF-16"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ZStack {
                    Circle().stroke(GrammarlessTheme.softInk, lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: CGFloat(max(0, min(100, report.overallScore))) / 100)
                        .stroke(GrammarlessTheme.aquaInk, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(report.overallScore)")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                }
                .frame(width: 62, height: 62)
            }

            Text(report.oneSentenceDiagnosis.isEmpty ? report.executiveSummary : report.oneSentenceDiagnosis)
                .font(.system(size: 14.5, weight: .medium))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(report.scores) { score in
                    impactScorePill(score)
                }
            }

            if !report.analysisFailures.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Label(ui("Some paths failed (recorded; no fake analysis)", zh: "部分路径失败（已记录，不生成伪分析）"), systemImage: "exclamationmark.triangle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(GrammarlessTheme.goldInk)
                    ForEach(report.analysisFailures.prefix(3)) { failure in
                        Text("\(impactPathLabel(failure.path))\(failure.segmentID.map { " · \($0)" } ?? "")\(ui(": ", zh: "："))\(failure.message)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(9)
                .background(GrammarlessTheme.softGold)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }

            if !report.topFindings.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(ui("Top priorities", zh: "优先事项"))
                        .font(.caption.weight(.semibold))
                    ForEach(Array(report.topFindings.prefix(5).enumerated()), id: \.element.id) { index, finding in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(index + 1). \(finding.title)")
                                    .font(.caption.weight(.semibold))
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Text(impactDimensionLabel(finding.dimension))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if !finding.explanation.isEmpty {
                                Text(finding.explanation)
                                    .font(.caption)
                                    .foregroundStyle(.primary.opacity(0.86))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if !finding.evidence.isEmpty {
                                Text(ui("Evidence: \(finding.evidence)", zh: "证据：\(finding.evidence)"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text(finding.recommendation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(9)
                        .background(GrammarlessTheme.softInk)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                }
            }

            DisclosureGroup(ui("Path summary", zh: "路径摘要")) {
                VStack(alignment: .leading, spacing: 8) {
                    impactSummaryRow(ui("Structure", zh: "结构"), report.structureSummary)
                    impactSummaryRow(ui("Logic & Evidence", zh: "逻辑与证据"), report.logicSummary)
                    impactSummaryRow(ui("Reader Reaction", zh: "读者反应"), report.readerSummary)
                    if !report.quickWins.isEmpty {
                        impactList(ui("Quick wins", zh: "快速优化"), report.quickWins)
                    }
                    if !report.deeperRevisions.isEmpty {
                        impactList(ui("Deeper revisions", zh: "深度修改"), report.deeperRevisions)
                    }
                }
                .padding(.top, 6)
            }
            .font(.caption.weight(.semibold))

            impactReplacementSection(report)
        }
        .padding(14)
        .background(GrammarlessTheme.card)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(GrammarlessTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func impactScorePill(_ score: ImpactScore) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(impactDimensionLabel(score.dimension))
                    .font(.caption2.weight(.semibold))
                Spacer()
                Text("\(score.score)")
                    .font(.caption.weight(.bold))
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(GrammarlessTheme.softInk)
                    Capsule().fill(GrammarlessTheme.aquaInk.opacity(0.85))
                        .frame(width: geometry.size.width * CGFloat(max(0, min(100, score.score))) / 100)
                }
            }
            .frame(height: 5)
            Text(score.topFix.isEmpty ? score.reason : score.topFix)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !score.reason.isEmpty, !score.topFix.isEmpty, score.reason != score.topFix {
                Text(score.reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.86))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .background(GrammarlessTheme.softInk)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func impactSummaryRow(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold))
            Text(body.isEmpty ? "—" : body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func impactReplacementSection(_ report: DocumentImpactReport) -> some View {
        let patches = pendingImpactPatches(for: report)
        return Group {
            if !patches.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(ui("Language replacement options", zh: "语言替换选项"))
                        .font(.caption.weight(.semibold))
                    Text(ui(
                        "These replacements come from Impact's language clarity path. Apply or reject them one by one.",
                        zh: "这些替换来自 Impact 的语言清晰度路径，可逐条应用或取消。"
                    ))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(patches) { patch in
                        compactImpactPatchCard(patch)
                    }
                }
                .padding(10)
                .background(GrammarlessTheme.softAqua)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func pendingImpactPatches(for report: DocumentImpactReport) -> [TextPatch] {
        let pendingIDs = Set(viewModel.pendingPatches.map(\.id))
        return report.patchCandidates.filter { pendingIDs.contains($0.id) }
    }

    private func compactImpactPatchCard(_ patch: TextPatch) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(patch.reason)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ui("Original", zh: "原文")).font(.caption2.weight(.semibold))
                    Text(patch.originalText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(GrammarlessTheme.error)
                        .strikethrough(color: GrammarlessTheme.error)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Text(ui("Replace with", zh: "替换为")).font(.caption2.weight(.semibold))
                    Text(patch.replacementText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(GrammarlessTheme.aquaInk)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(ui("Cancel", zh: "取消")) { rejectPatch(patch.id) }
                    .buttonStyle(.grammarlessInteractive)
                    .disabled(viewModel.isLoading)
                    .accessibilityIdentifier("grammarless-impact-reject-patch-\(patch.id.uuidString)")
                Spacer()
                Button(ui("Apply replacement", zh: "应用替换")) { applyPatch(patch.id) }
                    .buttonStyle(.grammarlessProminent)
                    .interactiveHover()
                    .disabled(viewModel.isLoading)
                    .accessibilityIdentifier("grammarless-impact-apply-patch-\(patch.id.uuidString)")
            }
        }
        .padding(9)
        .background(GrammarlessTheme.input)
        .clipShape(RoundedRectangle(cornerRadius: GrammarlessTheme.controlRadius, style: .continuous))
    }

    private func impactPathLabel(_ path: ImpactAnalysisPath) -> String {
        switch path {
        case .segmentation: return ui("Segmentation", zh: "切分")
        case .genreClassification: return ui("Genre classification", zh: "文体识别")
        case .structureFormat: return ui("Structure & format", zh: "结构与格式")
        case .globalLogicEvidence: return ui("Cross-paragraph logic & evidence", zh: "跨段逻辑与证据")
        case .localLogicEvidence: return ui("Local logic & evidence", zh: "单段逻辑与证据")
        case .readerReaction: return ui("Reader reaction", zh: "读者反应")
        case .languageClarity: return ui("Language clarity", zh: "语言清晰度")
        case .reducer: return ui("Synthesis", zh: "汇总")
        }
    }

    private func impactDimensionLabel(_ dimension: ImpactDimension) -> String {
        guard uiLanguage == .en else { return dimension.displayName }
        switch dimension {
        case .purposeClarity: return "Purpose clarity"
        case .structureLogic: return "Structure logic"
        case .evidenceSufficiency: return "Evidence"
        case .readerReaction: return "Reader reaction"
        case .genreFit: return "Genre fit"
        case .languageClarity: return "Language clarity"
        }
    }

    private func genreLabel(_ rubric: ImpactGenreRubric) -> String {
        guard uiLanguage == .en else { return rubric.label }
        return rubric.id
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private func toolNameLabel(_ name: AgentToolName) -> String {
        guard uiLanguage == .en else { return name.displayName }
        switch name {
        case .readSelectedText: return "Read selected text"
        case .readVisibleText: return "Read visible text"
        case .readDocumentContext: return "Read document context"
        case .draftEditPatch: return "Draft edit patch"
        case .checkConsistency: return "Check consistency"
        case .previewPatchDiff: return "Preview diff"
        case .stagePatchForUserConfirmation: return "Stage for confirmation"
        case .rollbackLastVersion: return "Rollback"
        case .redoLastAgentRun: return "Redo"
        }
    }

    private func impactList(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                Text("\(index + 1). \(item)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var toolTimeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(ui("Tool calls", zh: "工具调用"))
                    .font(.caption.weight(.semibold))
                Spacer()
            }
            VStack(spacing: 8) {
                ForEach(viewModel.toolEvents) { event in
                    toolEventRow(event)
                }
            }
        }
        .padding(12)
        .background(GrammarlessTheme.softInk)
        .clipShape(RoundedRectangle(cornerRadius: GrammarlessTheme.cardRadius, style: .continuous))
    }

    private func toolEventRow(_ event: AgentToolEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: event.name))
                .frame(width: 20)
                .foregroundStyle(color(for: event.status))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(toolNameLabel(event.name))
                        .font(.caption.weight(.semibold))
                    Spacer()
                    statusGlyph(event.status)
                }
                Text(event.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !event.detail.isEmpty {
                    Text(compact(event.detail))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(9)
        .background(GrammarlessTheme.input)
        .clipShape(RoundedRectangle(cornerRadius: GrammarlessTheme.controlRadius, style: .continuous))
    }

    private var outlineCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ui("Outline", zh: "大纲"))
                .font(.caption.weight(.semibold))
            ForEach(Array(viewModel.outline.enumerated()), id: \.offset) { index, item in
                Text("\(index + 1). \(item)")
                    .font(.caption)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(GrammarlessTheme.softInk)
        .clipShape(RoundedRectangle(cornerRadius: GrammarlessTheme.cardRadius))
    }

    private func patchPreviewSection(_ patches: [TextPatch]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ui("Diff", zh: "差异"))
                .font(.caption.weight(.semibold))
            ForEach(patches) { patch in
                patchCard(patch)
            }
            HStack(spacing: 8) {
                if patches.count == viewModel.pendingPatches.count {
                    Button(action: applyAllPatches) {
                        Label(ui("Apply all", zh: "确认应用"), systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.grammarlessProminent)
                    .interactiveHover()
                    .disabled(viewModel.isLoading)
                    .accessibilityIdentifier("grammarless-apply-all-patches")
                }
                Button(action: rollback) {
                    Label(ui("Rollback", zh: "回滚"), systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.grammarlessSoft)
                .disabled(!viewModel.canRollback || viewModel.isLoading)
                .interactiveHover()
                .accessibilityIdentifier("grammarless-rollback")
            }
            Button(action: redo) {
                Label(ui("Redo", zh: "一键重做"), systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.grammarlessSoft)
            .disabled(viewModel.isLoading)
            .interactiveHover()
            .accessibilityIdentifier("grammarless-redo-patches")
        }
    }

    private func patchCard(_ patch: TextPatch) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ui("Original", zh: "原文"))
                .font(.caption.weight(.semibold))
            Text(patch.originalText.isEmpty ? ui("<insert>", zh: "<插入>") : patch.originalText)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(GrammarlessTheme.error)
                .strikethrough(!patch.originalText.isEmpty, color: GrammarlessTheme.error)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(GrammarlessTheme.error.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: GrammarlessTheme.controlRadius))

            Text(ui("After", zh: "修改后"))
                .font(.caption.weight(.semibold))
            Text(patch.replacementText)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(GrammarlessTheme.aquaInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(GrammarlessTheme.aqua.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: GrammarlessTheme.controlRadius))

            if !patch.reason.isEmpty {
                Text(patch.reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(ui("Cancel", zh: "取消")) { rejectPatch(patch.id) }
                    .buttonStyle(.grammarlessInteractive)
                    .accessibilityIdentifier("grammarless-reject-patch-\(patch.id.uuidString)")
                Spacer()
                Button(ui("Apply edit", zh: "应用修改")) { applyPatch(patch.id) }
                    .buttonStyle(.grammarlessProminent)
                    .interactiveHover()
                    .accessibilityIdentifier("grammarless-apply-patch-\(patch.id.uuidString)")
            }
        }
        .padding(12)
        .background(GrammarlessTheme.softInk)
        .clipShape(RoundedRectangle(cornerRadius: GrammarlessTheme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: GrammarlessTheme.cardRadius)
                .stroke(GrammarlessTheme.border, lineWidth: 1)
        )
    }

    private var lastVersionCard: some View {
        Text(viewModel.lastVersionSummary)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if !standalonePendingPatches.isEmpty {
                proxy.scrollTo("patches", anchor: .bottom)
            } else if viewModel.isStreamingAssistantReply, let last = visibleConversation.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            } else if !viewModel.toolEvents.isEmpty {
                proxy.scrollTo("tools", anchor: .bottom)
            } else if viewModel.isLoading {
                proxy.scrollTo("loading", anchor: .bottom)
            } else if let last = visibleConversation.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            } else if viewModel.impactReport != nil {
                proxy.scrollTo("impact-report", anchor: .bottom)
            }
        }
    }

    private func color(for status: AgentToolStatus) -> Color {
        switch status {
        case .running: GrammarlessTheme.aquaInk
        case .succeeded: GrammarlessTheme.goldInk
        case .failed: GrammarlessTheme.error
        }
    }

    private func statusGlyph(_ status: AgentToolStatus) -> some View {
        Group {
            switch status {
            case .running: ProgressView().controlSize(.mini)
            case .succeeded: Image(systemName: "checkmark")
            case .failed: Image(systemName: "xmark")
            }
        }
        .font(.caption2)
        .foregroundStyle(color(for: status))
    }

    private func icon(for tool: AgentToolName) -> String {
        switch tool {
        case .readSelectedText, .readVisibleText, .readDocumentContext: "doc.text.magnifyingglass"
        case .draftEditPatch: "pencil.and.scribble"
        case .checkConsistency: "checklist"
        case .previewPatchDiff: "rectangle.split.2x1"
        case .stagePatchForUserConfirmation: "square.and.arrow.down"
        case .rollbackLastVersion: "arrow.uturn.backward"
        case .redoLastAgentRun: "arrow.clockwise"
        }
    }

    private func compact(_ text: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        guard oneLine.count > 160 else { return oneLine }
        return String(oneLine.prefix(160)) + "…"
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func relativeSessionTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: uiLanguage == .zh ? "zh_CN" : "en_US")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct GrammarlessInteractiveHoverModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    @State private var isCursorPushed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovered && isEnabled ? 1.025 : 1)
            .brightness(isHovered && isEnabled ? 0.018 : 0)
            .animation(.easeOut(duration: 0.12), value: isHovered && isEnabled)
            .onHover { hovering in
                isHovered = hovering
                updateCursor(hovering && isEnabled)
            }
            .onChange(of: isEnabled) { enabled in
                if !enabled {
                    isHovered = false
                    updateCursor(false)
                }
            }
            .onDisappear {
                updateCursor(false)
            }
    }

    private func updateCursor(_ shouldShowPointer: Bool) {
        if shouldShowPointer, !isCursorPushed {
            NSCursor.pointingHand.push()
            isCursorPushed = true
        } else if !shouldShowPointer, isCursorPushed {
            NSCursor.pop()
            isCursorPushed = false
        }
    }
}

private struct GrammarlessPlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .interactiveHover()
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

private extension ButtonStyle where Self == GrammarlessPlainButtonStyle {
    static var grammarlessInteractive: GrammarlessPlainButtonStyle {
        GrammarlessPlainButtonStyle()
    }
}

private extension View {
    func interactiveHover() -> some View {
        modifier(GrammarlessInteractiveHoverModifier())
    }

    func settingsInputChrome() -> some View {
        self
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(GrammarlessTheme.input)
            .overlay(
                RoundedRectangle(cornerRadius: GrammarlessTheme.smallRadius, style: .continuous)
                    .stroke(GrammarlessTheme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: GrammarlessTheme.smallRadius, style: .continuous))
    }

    func settingsSmallInputChrome() -> some View {
        self
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(GrammarlessTheme.input)
            .overlay(
                RoundedRectangle(cornerRadius: GrammarlessTheme.smallRadius, style: .continuous)
                    .stroke(GrammarlessTheme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: GrammarlessTheme.smallRadius, style: .continuous))
    }

    func settingsStatusColumn() -> some View {
        self
            .background(GrammarlessTheme.input)
            .overlay(
                RoundedRectangle(cornerRadius: GrammarlessTheme.smallRadius, style: .continuous)
                    .stroke(GrammarlessTheme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: GrammarlessTheme.smallRadius, style: .continuous))
    }
}

final class LongformSidebarWindowController: NSWindowController {
    let viewModel = LongformSidebarViewModel()
    private let panel: NSPanel
    private let configurationStore: ConfigurationStore
    private let appModel: AppModel
    private let reanalyzeFocusedText: () -> Void
    private let quitGrammarless: () -> Void
    private var lastAnchorTopLeftRect: CGRect?
    private var isManuallyDismissed = false
    private var outsideMouseEventMonitor: Any?
    private var localOutsideMouseEventMonitor: Any?

    var isVisible: Bool {
        panel.isVisible
    }

    var stateSnapshot: LongformSidebarState {
        var state = viewModel.stateSnapshot
        state.isVisible = isVisible
        state.uiLanguage = configurationStore.configuration.uiLanguage.rawValue
        state.isGhostTextEnabled = configurationStore.configuration.isGhostTextEnabled
        return state
    }

    init(
        configurationStore: ConfigurationStore,
        appModel: AppModel,
        reanalyzeFocusedText: @escaping () -> Void,
        quitGrammarless: @escaping () -> Void
    ) {
        self.configurationStore = configurationStore
        self.appModel = appModel
        self.reanalyzeFocusedText = reanalyzeFocusedText
        self.quitGrammarless = quitGrammarless
        panel = InteractionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 76),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Grammarless"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
    }

    deinit {
        stopOutsideClickMonitor()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(
        anchoredTo anchorTopLeftRect: CGRect,
        sendMessage: @escaping (String) -> Void,
        applyPatch: @escaping (UUID) -> Void,
        applyAllPatches: @escaping () -> Void,
        rejectPatch: @escaping (UUID) -> Void,
        runImpactAnalysis: @escaping () -> Void,
        rollback: @escaping () -> Void,
        redo: @escaping () -> Void,
        newSession: @escaping () -> Void,
        selectSession: @escaping (UUID) -> Void,
        deleteSession: @escaping (UUID) -> Void
    ) {
        isManuallyDismissed = false
        panel.contentView = FirstMouseHostingView(
            rootView: LongformSidebarView(
                viewModel: viewModel,
                configurationStore: configurationStore,
                appModel: appModel,
                sendMessage: sendMessage,
                applyPatch: applyPatch,
                applyAllPatches: applyAllPatches,
                rejectPatch: rejectPatch,
                runImpactAnalysis: runImpactAnalysis,
                rollback: rollback,
                redo: redo,
                newSession: newSession,
                selectSession: selectSession,
                deleteSession: deleteSession,
                reanalyzeFocusedText: reanalyzeFocusedText,
                quitGrammarless: quitGrammarless,
                requestLayout: { [weak self] in
                    DispatchQueue.main.async {
                        self?.refreshLayout()
                    }
                },
                close: { [weak self] in self?.dismiss() }
            )
        )
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView?.layer?.isOpaque = false
        lastAnchorTopLeftRect = anchorTopLeftRect
        refreshLayout()
        DebugLogger.log("agent chat present anchor=\(NSStringFromRect(anchorTopLeftRect))")
        panel.orderFrontRegardless()
        startOutsideClickMonitor()
    }

    func refreshLayout() {
        guard let anchorTopLeftRect = lastAnchorTopLeftRect else { return }
        let size = viewModel.preferredPanelSize
        if panel.isVisible {
            let currentTopLeft = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
            panel.setContentSize(size)
            panel.setFrameTopLeftPoint(clampedAppKitTopLeftPoint(currentTopLeft, size: size))
        } else {
            panel.setContentSize(size)
            panel.setFrameTopLeftPoint(appKitTopLeftPoint(anchoredTo: anchorTopLeftRect, size: size))
        }
        if !isManuallyDismissed {
            panel.orderFrontRegardless()
        }
    }

    func dismiss() {
        DebugLogger.log("agent chat dismiss")
        isManuallyDismissed = true
        stopOutsideClickMonitor()
        panel.orderOut(nil)
    }

    private func startOutsideClickMonitor() {
        guard outsideMouseEventMonitor == nil, localOutsideMouseEventMonitor == nil else { return }
        outsideMouseEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.dismissIfMouseIsOutsidePanel()
            }
        }
        localOutsideMouseEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.dismissIfMouseIsOutsidePanel()
            return event
        }
    }

    private func stopOutsideClickMonitor() {
        if let outsideMouseEventMonitor {
            NSEvent.removeMonitor(outsideMouseEventMonitor)
            self.outsideMouseEventMonitor = nil
        }
        if let localOutsideMouseEventMonitor {
            NSEvent.removeMonitor(localOutsideMouseEventMonitor)
            self.localOutsideMouseEventMonitor = nil
        }
    }

    private func dismissIfMouseIsOutsidePanel() {
        guard panel.isVisible else { return }
        guard !panel.frame.contains(NSEvent.mouseLocation) else { return }
        DebugLogger.log("agent chat outside click dismiss")
        dismiss()
    }

    private func appKitTopLeftPoint(anchoredTo rect: CGRect, size: CGSize) -> CGPoint {
        let screenFrame = topLeftScreenFrame(containing: CGPoint(x: rect.maxX, y: rect.maxY))
        let margin: CGFloat = 10
        var topLeftX = rect.maxX + margin
        if topLeftX + size.width > screenFrame.maxX - margin {
            topLeftX = rect.minX - size.width - margin
        }
        topLeftX = min(max(topLeftX, screenFrame.minX + margin), screenFrame.maxX - size.width - margin)

        var topLeftY = rect.maxY + margin
        if topLeftY + size.height > screenFrame.maxY - margin {
            topLeftY = rect.minY - size.height - margin
        }
        topLeftY = min(max(topLeftY, screenFrame.minY + margin), screenFrame.maxY - size.height - margin)

        let screenHeight = NSScreen.main?.frame.maxY ?? screenFrame.maxY
        return CGPoint(x: topLeftX, y: screenHeight - topLeftY)
    }

    private func clampedAppKitTopLeftPoint(_ point: CGPoint, size: CGSize) -> CGPoint {
        let visibleFrame = NSScreen.screens
            .map(\.visibleFrame)
            .first(where: { $0.insetBy(dx: -120, dy: -120).contains(CGPoint(x: point.x, y: point.y - 1)) })
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 10
        let minX = visibleFrame.minX + margin
        let maxX = visibleFrame.maxX - size.width - margin
        let minY = visibleFrame.minY + size.height + margin
        let maxY = visibleFrame.maxY - margin
        return CGPoint(
            x: min(max(point.x, minX), max(minX, maxX)),
            y: min(max(point.y, minY), max(minY, maxY))
        )
    }

    private func topLeftScreenFrame(containing point: CGPoint) -> CGRect {
        let frames = NSScreen.screens.map { appKitScreenFrameToTopLeftFrame($0.visibleFrame) }
        if let frame = frames.first(where: { $0.insetBy(dx: -120, dy: -120).contains(point) }) {
            return frame
        }
        guard var union = frames.first else {
            return CGRect(x: 0, y: 0, width: 1440, height: 900)
        }
        for frame in frames.dropFirst() {
            union = union.union(frame)
        }
        return union
    }

    private func appKitScreenFrameToTopLeftFrame(_ frame: CGRect) -> CGRect {
        let screenHeight = NSScreen.main?.frame.maxY ?? frame.maxY
        return CGRect(
            x: frame.minX,
            y: screenHeight - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }
}

import AppKit
import Combine
import Foundation
import GrammarlessCore

private final class GhostKeyState: @unchecked Sendable {
    private let lock = NSLock()
    private var visible = false

    func setVisible(_ value: Bool) {
        lock.lock()
        visible = value
        lock.unlock()
    }

    func isVisible() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return visible
    }
}

private final class GhostKeyboardBridge: @unchecked Sendable {
    let state = GhostKeyState()
    weak var controller: GrammarlessController?
}

private enum P4ControllerError: LocalizedError {
    case memoryUnavailable(String)
    case noActiveContext
    case noActiveDocument
    case noPendingPatch(UUID)
    case noConversationSession(UUID)
    case noGhostSuggestion
    case noVersion

    var errorDescription: String? {
        switch self {
        case let .memoryUnavailable(message):
            "Writing memory unavailable: \(message)"
        case .noActiveContext:
            "No active text context."
        case .noActiveDocument:
            "No active document."
        case let .noPendingPatch(id):
            "Pending patch is no longer available: \(id.uuidString)"
        case let .noConversationSession(id):
            "Conversation session is no longer available: \(id.uuidString)"
        case .noGhostSuggestion:
            "No ghost suggestion is available."
        case .noVersion:
            "No recorded version is available to roll back."
        }
    }
}

private func ghostKeyboardEventCallback(
    proxy _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard type == .keyDown,
          let userInfo
    else {
        return Unmanaged.passUnretained(event)
    }
    let bridge = Unmanaged<GhostKeyboardBridge>.fromOpaque(userInfo).takeUnretainedValue()
    guard bridge.state.isVisible() else {
        return Unmanaged.passUnretained(event)
    }
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    guard keyCode == 48 || keyCode == 53 else {
        return Unmanaged.passUnretained(event)
    }
    let controller = bridge.controller
    Task { @MainActor in
        if keyCode == 48 {
            await controller?.acceptGhostSuggestion(trigger: "tab")
        } else {
            controller?.rejectGhostSuggestion(trigger: "esc")
        }
    }
    return nil
}

@MainActor
final class GrammarlessController {
    private let supportedNativeAppBundleIdentifiers: Set<String> = [
        "com.apple.TextEdit",
        "com.apple.Notes",
        "com.apple.mail",
        "com.microsoft.Word",
    ]
    private let model: AppModel
    private let configurationStore: ConfigurationStore
    private let accessibilityService = AccessibilityService()
    private let focusedObserver = FocusedTextObserver()
    private let reviewEngine = ReviewEngine()
    private let overlayManager = OverlayManager()
    private lazy var longformSidebar = LongformSidebarWindowController(
        configurationStore: configurationStore,
        appModel: model,
        reanalyzeFocusedText: { [weak self] in
            self?.reanalyzeNow()
        },
        quitGrammarless: {
            NSApp.terminate(nil)
        }
    )
    private lazy var replacementExecutor = TextReplacementExecutor(accessibilityService: accessibilityService)
    private let memoryStore: WritingMemoryStore?
    private let memoryStoreInitializationError: String?

    private var refreshTimer: Timer?
    private var debounceTask: Task<Void, Never>?
    private var remoteReviewTask: Task<Void, Never>?
    private var aiPreviewTask: Task<Void, Never>?
    private var agentTask: Task<Void, Never>?
    private var ghostTask: Task<Void, Never>?
    private var configurationCancellables = Set<AnyCancellable>()
    private var lastAppliedConfiguration: AppConfiguration?
    private var localKeyMonitor: Any?
    private var keyboardEventTap: CFMachPort?
    private var keyboardRunLoopSource: CFRunLoopSource?
    private let ghostKeyboardBridge = GhostKeyboardBridge()
    private var activeContext: FocusedTextContext?
    private var activeSnapshot: TextSnapshot?
    private var activeBatch: SuggestionBatch?
    private var ignoredSuggestionKeys = Set<String>()
    private var lastTextFingerprint: String?
    private var lastGhostFingerprint: String?
    private var isExecutingReplacement = false
    private var pendingAISelectionRange: NSRange?
    private var pendingAISelectionText: String?
    private var pendingAIRevision: UUID?
    private var currentDocumentRecord: DocumentRecord?
    private var activeConversationSessionID: UUID?
    private var activeConversationSessionByDocumentID: [String: UUID] = [:]
    private var foregroundSuggestionCache: [String: SuggestionBatch] = [:]
    private var pendingAgentResponse: AgentResponse?
    private var lastAgentInstruction: String?
    private var lastGhostSuggestion: GhostSuggestion?
    private var rolledBackVersionIDs = Set<UUID>()

    init(model: AppModel, configurationStore: ConfigurationStore) {
        self.model = model
        self.configurationStore = configurationStore
        do {
            let store = try SQLiteWritingMemoryStore.defaultStore()
            memoryStore = store
            memoryStoreInitializationError = nil
            DebugLogger.log("writing memory store initialized")
        } catch {
            memoryStore = nil
            memoryStoreInitializationError = error.localizedDescription
            DebugLogger.log("writing memory store failed error=\(error.localizedDescription)")
        }
        ghostKeyboardBridge.controller = self
        lastAppliedConfiguration = configurationStore.configuration
        overlayManager.setLanguage(configurationStore.configuration.uiLanguage)

        model.onReanalyze = { [weak self] in
            self?.reanalyzeNow()
        }
        model.onAcceptSuggestion = { [weak self] suggestionID in
            Task { @MainActor [weak self] in
                await self?.acceptSuggestion(withID: suggestionID)
            }
        }
        model.onIgnoreSuggestion = { [weak self] suggestionID in
            self?.ignoreSuggestion(withID: suggestionID)
        }
        model.onRunAIAction = { [weak self] action in
            Task { @MainActor [weak self] in
                await self?.runAIActionFromStatus(action)
            }
        }
        model.onReplaceAI = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.replaceAISelectionFromStatus()
            }
        }
        model.onOpenLongformSidebar = { [weak self] in
            self?.openGrammarlessChat()
        }

        focusedObserver.onEvent = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                refreshFocusContext(trigger: "observer")
            }
        }

        overlayManager.onFallbackActivated = { [weak self] in
            self?.showFallbackSuggestionHover()
        }
        overlayManager.onVBarActivated = { [weak self] in
            self?.showAIPanel()
        }
        overlayManager.onSuggestionAccepted = { [weak self] suggestion in
            Task { @MainActor [weak self] in
                await self?.acceptSuggestion(suggestion)
            }
        }
        overlayManager.onSuggestionIgnored = { [weak self] suggestion in
            self?.ignoreSuggestion(suggestion)
        }
        overlayManager.onAIActionRequested = { [weak self] action in
            Task { @MainActor [weak self] in
                await self?.runAIAction(action)
            }
        }
        overlayManager.onAIReplace = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.replaceAISelection()
            }
        }
        overlayManager.onAICancel = { [weak self] in
            self?.cancelAIInteraction()
        }
        overlayManager.onGLauncherActivated = { [weak self] in
            self?.openGrammarlessChat()
        }

        configurationStore.$configuration
            .dropFirst()
            .sink { [weak self] configuration in
                Task { @MainActor [weak self] in
                    self?.handleConfigurationChange(configuration)
                }
            }
            .store(in: &configurationCancellables)
    }

    private func handleConfigurationChange(_ configuration: AppConfiguration) {
        let previous = lastAppliedConfiguration
        lastAppliedConfiguration = configuration

        if !configuration.isGhostTextEnabled {
            ghostTask?.cancel()
            clearGhostSuggestion(trigger: "ghostDisabled")
        }

        if previous?.uiLanguage != configuration.uiLanguage {
            overlayManager.setLanguage(configuration.uiLanguage)
            if let snapshot = activeSnapshot {
                scheduleAnalysis(for: snapshot, force: true)
            }
            longformSidebar.refreshLayout()
        }
    }

    private var uiLanguage: GrammarlessLanguageMode {
        configurationStore.configuration.uiLanguage
    }

    private func localized(_ english: String, zh chinese: String) -> String {
        uiLanguage == .zh ? chinese : english
    }

    private func localizedError(_ error: P4ControllerError) -> String {
        switch error {
        case let .memoryUnavailable(message):
            return localized("Writing memory unavailable: \(message)", zh: "写作记忆不可用：\(message)")
        case .noActiveContext:
            return localized("No active text context.", zh: "没有可用的文本上下文。")
        case .noActiveDocument:
            return localized("No active document.", zh: "没有可用的文档。")
        case let .noPendingPatch(id):
            return localized("Pending patch is no longer available: \(id.uuidString)", zh: "待应用修改已不可用：\(id.uuidString)")
        case let .noConversationSession(id):
            return localized("Conversation session is no longer available: \(id.uuidString)", zh: "会话已不可用：\(id.uuidString)")
        case .noGhostSuggestion:
            return localized("No ghost suggestion is available.", zh: "没有可用的 Ghost 建议。")
        case .noVersion:
            return localized("No recorded version is available to roll back.", zh: "没有可回滚的记录版本。")
        }
    }

    func start() {
        DebugLogger.log("controller.start")
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(frontmostAppChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshFocusContext(trigger: "poll")
            }
        }
        installLocalKeyMonitor()
        refreshFocusContext(trigger: "start")
    }

    func stop() {
        DebugLogger.log("controller.stop")
        NotificationCenter.default.removeObserver(self)
        refreshTimer?.invalidate()
        debounceTask?.cancel()
        remoteReviewTask?.cancel()
        aiPreviewTask?.cancel()
        agentTask?.cancel()
        ghostTask?.cancel()
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let keyboardEventTap {
            CFMachPortInvalidate(keyboardEventTap)
            self.keyboardEventTap = nil
        }
        keyboardRunLoopSource = nil
        focusedObserver.detach()
        overlayManager.clear()
    }

    func reanalyzeNow() {
        DebugLogger.log("controller.reanalyzeNow")
        refreshFocusContext(trigger: "manual")
        if let snapshot = activeSnapshot {
            scheduleAnalysis(for: snapshot, force: true)
        }
    }

    @objc private func frontmostAppChanged() {
        refreshFocusContext(trigger: "workspace")
    }

    private func refreshFocusContext(trigger: String) {
        let trusted = accessibilityService.isProcessTrusted(prompt: trigger == "start")
        model.accessibilityAuthorized = trusted
        DebugLogger.log("refreshFocusContext trigger=\(trigger) trusted=\(trusted)")
        guard trusted else {
            model.lastErrorMessage = localized("Accessibility permission is required.", zh: "需要开启辅助功能权限。")
            overlayManager.clear()
            return
        }
        guard !isExecutingReplacement else {
            DebugLogger.log("refreshFocusContext skipped during replacement trigger=\(trigger)")
            return
        }

        let frontmost = accessibilityService.frontmostApplication()
        let frontmostBundleID = frontmost?.bundleIdentifier ?? "nil"
        var context = accessibilityService.focusedTextContext()
        if let candidate = context,
           shouldPreferFallbackTextContext(candidate, frontmostBundleID: frontmostBundleID),
           let frontmost,
           let fallback = accessibilityService.documentTextContext(for: frontmost)
        {
            DebugLogger.log(
                "replacing weak focused context with frontmost document context trigger=\(trigger) role=\(candidate.role) textLength=\((candidate.fullText as NSString).length)"
            )
            context = fallback
        }
        if context == nil,
           let frontmost,
           let frontmostBundleIdentifier = frontmost.bundleIdentifier,
           supportedNativeAppBundleIdentifiers.contains(frontmostBundleIdentifier),
           frontmostBundleIdentifier != Bundle.main.bundleIdentifier,
           let documentContext = accessibilityService.documentTextContext(for: frontmost)
        {
            DebugLogger.log(
                "resolved frontmost document context trigger=\(trigger) app=\(frontmostBundleIdentifier) role=\(documentContext.role) textLength=\((documentContext.fullText as NSString).length)"
            )
            context = documentContext
        }
        if context == nil {
            context = fallbackFocusedTextContext(frontmostBundleID: frontmostBundleID, trigger: trigger)
        }

        guard let context else {
            if activeSnapshot != nil,
               activeContext != nil,
               (frontmostBundleID == Bundle.main.bundleIdentifier && shouldPreserveHostContextWhenGrammarlessIsFrontmost()
                   || shouldPreserveHostContextDuringAIInteraction())
            {
                DebugLogger.log(
                    "preserving active host context while interaction surface is visible trigger=\(trigger) frontmost=\(frontmostBundleID) qa=\(self.model.qaControlsEnabled) longform=\(self.longformSidebar.isVisible) ai=\(self.overlayManager.isAIPanelVisible)"
                )
                return
            }
            DebugLogger.log(
                "no focused text context frontmost=\(frontmostBundleID) app=\(frontmost?.localizedName ?? "nil")"
            )
            activeContext = nil
            activeSnapshot = nil
            activeBatch = nil
            model.frontmostApp = accessibilityService.frontmostApplication()?.localizedName ?? "—"
            model.focusedElementRole = "—"
            model.activeParagraphDescription = "—"
            model.selectionText = ""
            overlayManager.clear()
            return
        }

        model.frontmostApp = context.application.localizedName ?? context.application.bundleIdentifier ?? "—"
        model.focusedElementRole = context.role
        DebugLogger.log(
            "focused context app=\(context.application.bundleIdentifier ?? "nil") role=\(context.role) textLength=\((context.fullText as NSString).length) selection=\(context.selectedRange.location):\(context.selectedRange.length) visible=\(context.visibleRange.map { "\($0.location):\($0.length)" } ?? "nil") bounds=\(NSStringFromRect(context.elementBounds))"
        )

        if shouldPreserveHostContextInsteadOf(context) {
            DebugLogger.log(
                "preserving active host context instead of interaction/unsupported input trigger=\(trigger) app=\(context.application.bundleIdentifier ?? "nil") role=\(context.role) qa=\(self.model.qaControlsEnabled) longform=\(self.longformSidebar.isVisible) ai=\(self.overlayManager.isAIPanelVisible)"
            )
            return
        }

        guard isSupportedTextContext(context) else {
            activeContext = context
            model.activeParagraphDescription = "Unsupported app in P1"
            model.selectionText = ""
            overlayManager.clear()
            DebugLogger.log("unsupported app \(context.application.bundleIdentifier ?? "nil")")
            return
        }

        activeContext = context
        focusedObserver.attach(to: context.application, focusedElement: context.element)

        let paragraph = ParagraphContextExtractor.extract(
            from: context.fullText,
            selectedRange: context.selectedRange,
            visibleRange: context.visibleRange
        )
        let language = LanguageRouter.detectLanguage(for: paragraph.analysisText)

        let fingerprint = "\(context.elementIdentity)|\(context.fullText)"
        let revision = lastTextFingerprint == fingerprint ? (activeSnapshot?.revision ?? UUID()) : UUID()
        lastTextFingerprint = fingerprint

        let snapshot = TextSnapshot(
            appBundleId: context.application.bundleIdentifier ?? "com.apple.TextEdit",
            elementIdentity: context.elementIdentity,
            fullText: context.fullText,
            selectedRange: context.selectedRange,
            analysisText: paragraph.analysisText,
            analysisRangeInFullText: paragraph.analysisRangeInFullText,
            elementBounds: context.elementBounds,
            revision: revision,
            languageHint: language
        )
        let preserveCollapsedAISelection = shouldPreserveCollapsedAISelection(for: snapshot)

        model.activeParagraphDescription = paragraph.paragraphIdentity
        model.selectionText = selectedSubstring(from: context.fullText, range: context.selectedRange)
        DebugLogger.log(
            "snapshot revision=\(snapshot.revision.uuidString) lang=\(language.rawValue) paragraph=\(paragraph.paragraphIdentity) analysisLength=\((snapshot.analysisText as NSString).length) needsAnalysisCandidate"
        )

        let needsAnalysis = activeSnapshot?.revision != snapshot.revision ||
            activeSnapshot?.analysisRangeInFullText != snapshot.analysisRangeInFullText

        let previousSnapshot = activeSnapshot
        let canReuseSuggestionGeometry =
            previousSnapshot?.revision == snapshot.revision &&
            previousSnapshot?.analysisRangeInFullText == snapshot.analysisRangeInFullText &&
            previousSnapshot?.fullText == snapshot.fullText &&
            previousSnapshot?.elementBounds == snapshot.elementBounds

        let placeholderBatch: SuggestionBatch = if let batch = activeBatch, batch.isReusable(for: snapshot) {
            batch
        } else {
            SuggestionBatch(
                snapshotRevision: snapshot.revision,
                paragraphIdentity: snapshot.paragraphIdentity,
                suggestions: []
            )
        }

        activeSnapshot = snapshot
        model.activeSnapshot = snapshot
        if snapshot.selectedRange.length == 0,
           !preserveCollapsedAISelection,
           !overlayManager.isAIPanelVisible
        {
            model.lastActionPreview = ""
            model.lastActionExplanation = ""
        }
        updateDocumentMemoryState(for: snapshot, context: context)

        if preserveCollapsedAISelection {
            DebugLogger.log("preserving collapsed AI selection revision=\(snapshot.revision.uuidString)")
            let batch = (activeBatch?.isReusable(for: snapshot) ?? false) ? activeBatch! : placeholderBatch
            activeBatch = batch
            model.activeBatch = batch
            renderOverlay(snapshot: snapshot, batch: batch, reuseCachedSuggestionGeometry: canReuseSuggestionGeometry)
        } else if needsAnalysis {
            ignoredSuggestionKeys.removeAll()
            let cachedBatch = cachedSuggestionBatch(for: snapshot)
            if let cachedBatch {
                activeBatch = cachedBatch
                model.activeBatch = cachedBatch
                renderOverlay(snapshot: snapshot, batch: cachedBatch)
            } else {
                activeBatch = placeholderBatch
                model.activeBatch = placeholderBatch
                renderOverlay(snapshot: snapshot, batch: placeholderBatch)
            }
            let immediateBatch = runImmediateLocalReview(for: snapshot, cachedBatch: cachedBatch)
            scheduleAnalysis(for: snapshot, force: false, seedBatch: immediateBatch)
        } else if let batch = activeBatch, batch.isReusable(for: snapshot) {
            DebugLogger.log("reusing existing batch suggestions=\(batch.suggestions.count)")
            renderOverlay(snapshot: snapshot, batch: batch, reuseCachedSuggestionGeometry: canReuseSuggestionGeometry)
        } else {
            activeBatch = placeholderBatch
            model.activeBatch = placeholderBatch
            renderOverlay(snapshot: snapshot, batch: placeholderBatch)
        }
        scheduleGhostSuggestionIfNeeded(for: snapshot, context: context, trigger: trigger)
    }

    private func shouldPreserveHostContextWhenGrammarlessIsFrontmost() -> Bool {
        overlayManager.isPresentingInteractionSurface || longformSidebar.isVisible || model.qaControlsEnabled
    }

    private func shouldPreserveHostContextDuringAIInteraction() -> Bool {
        overlayManager.isAIPanelVisible || pendingAISelectionRange != nil
    }

    private func shouldPreserveHostContextInsteadOf(_ context: FocusedTextContext) -> Bool {
        guard activeSnapshot != nil,
              activeContext != nil
        else {
            return false
        }
        if context.application.bundleIdentifier == Bundle.main.bundleIdentifier,
           shouldPreserveHostContextWhenGrammarlessIsFrontmost()
        {
            return true
        }
        guard shouldPreserveHostContextDuringAIInteraction() else {
            return false
        }
        return !isSupportedTextContext(context)
    }

    private func fallbackFocusedTextContext(frontmostBundleID: String, trigger: String) -> FocusedTextContext? {
        guard model.qaControlsEnabled else { return nil }
        if frontmostBundleID == Bundle.main.bundleIdentifier, activeSnapshot != nil {
            return nil
        }
        let canFallbackToTextEdit =
            frontmostBundleID == "com.apple.loginwindow" ||
            frontmostBundleID == "nil" ||
            frontmostBundleID == Bundle.main.bundleIdentifier
        guard canFallbackToTextEdit else { return nil }

        guard let context = accessibilityService.fallbackEditableTextContext(
            preferredBundleIdentifiers: supportedPreferredBundleIdentifiers()
        ) else {
            DebugLogger.log(
                "fallback text context unavailable trigger=\(trigger) frontmost=\(frontmostBundleID)"
            )
            return nil
        }

        DebugLogger.log(
            "using fallback text context trigger=\(trigger) app=\(context.application.bundleIdentifier ?? "nil") role=\(context.role)"
        )
        return context
    }

    private func shouldPreferFallbackTextContext(
        _ context: FocusedTextContext,
        frontmostBundleID: String
    ) -> Bool {
        guard supportedNativeAppBundleIdentifiers.contains(frontmostBundleID) else { return false }
        guard context.application.bundleIdentifier == frontmostBundleID else { return false }

        let textLength = (context.fullText as NSString).length
        if context.role == String(kAXTextAreaRole), textLength > 0, context.elementBounds.height >= 80 {
            return false
        }

        return context.role != String(kAXTextAreaRole) ||
            textLength == 0 ||
            context.elementBounds.height < 80
    }

    private func runImmediateLocalReview(for snapshot: TextSnapshot, cachedBatch: SuggestionBatch?) -> SuggestionBatch {
        let localBatch = reviewEngine.localSuggestions(for: snapshot)
        let redCount = localBatch.suggestions.filter { $0.kind == .spelling }.count
        let batch: SuggestionBatch
        if let cachedBatch {
            batch = ReviewEngine.merge(local: localBatch, remote: cachedBatch)
        } else {
            batch = localBatch
        }
        DebugLogger.log(
            "immediate local review suggestions=\(batch.suggestions.count) localRed=\(redCount) cached=\(cachedBatch?.suggestions.count ?? 0)"
        )
        activeBatch = batch
        model.activeBatch = batch
        renderOverlay(snapshot: snapshot, batch: batch)
        persistSuggestionBatch(batch, for: snapshot, stage: "immediateLocal")
        return batch
    }

    private func cachedSuggestionBatch(for snapshot: TextSnapshot) -> SuggestionBatch? {
        guard let memoryStore, let record = currentDocumentRecord else { return nil }
        let segmentHash = suggestionSegmentHash(for: snapshot)
        let key = suggestionCacheKey(documentID: record.id, snapshot: snapshot, segmentHash: segmentHash)
        if var cached = foregroundSuggestionCache[key] {
            cached.snapshotRevision = snapshot.revision
            cached.paragraphIdentity = snapshot.paragraphIdentity
            DebugLogger.log("suggestion cache memory hit segment=\(snapshot.paragraphIdentity) suggestions=\(cached.suggestions.count)")
            return cached
        }
        do {
            guard var batch = try memoryStore.cachedSuggestionBatch(
                documentID: record.id,
                segmentIdentity: snapshot.paragraphIdentity,
                segmentHash: segmentHash
            ) else {
                DebugLogger.log("suggestion cache miss segment=\(snapshot.paragraphIdentity)")
                return nil
            }
            batch.snapshotRevision = snapshot.revision
            batch.paragraphIdentity = snapshot.paragraphIdentity
            foregroundSuggestionCache[key] = batch
            DebugLogger.log("suggestion cache sqlite hit segment=\(snapshot.paragraphIdentity) suggestions=\(batch.suggestions.count)")
            return batch
        } catch {
            DebugLogger.log("suggestion cache read failed error=\(error.localizedDescription)")
            return nil
        }
    }

    private func persistSuggestionBatch(_ batch: SuggestionBatch, for snapshot: TextSnapshot, stage: String) {
        guard let memoryStore, let record = currentDocumentRecord else { return }
        let segmentHash = suggestionSegmentHash(for: snapshot)
        let key = suggestionCacheKey(documentID: record.id, snapshot: snapshot, segmentHash: segmentHash)
        foregroundSuggestionCache[key] = batch
        do {
            try memoryStore.upsertCachedSuggestionBatch(
                documentID: record.id,
                segmentIdentity: snapshot.paragraphIdentity,
                segmentHash: segmentHash,
                language: snapshot.languageHint,
                batch: batch
            )
            DebugLogger.log("suggestion cache persisted stage=\(stage) segment=\(snapshot.paragraphIdentity) suggestions=\(batch.suggestions.count)")
        } catch {
            DebugLogger.log("suggestion cache persist failed stage=\(stage) error=\(error.localizedDescription)")
        }
    }

    private func suggestionSegmentHash(for snapshot: TextSnapshot) -> String {
        DocumentIdentity.normalizedContentHash(snapshot.analysisText)
    }

    private func suggestionCacheKey(documentID: String, snapshot: TextSnapshot, segmentHash: String) -> String {
        "\(documentID)|\(snapshot.paragraphIdentity)|\(segmentHash)"
    }

    private func scheduleAnalysis(for snapshot: TextSnapshot, force: Bool, seedBatch: SuggestionBatch? = nil) {
        debounceTask?.cancel()
        remoteReviewTask?.cancel()
        aiPreviewTask?.cancel()
        overlayManager.dismissPanels()
        if force {
            ignoredSuggestionKeys.removeAll()
        }
        let remoteDebounceNanoseconds = force ? 0 : UInt64(configurationStore.configuration.debounceMilliseconds) * 1_000_000
        DebugLogger.log(
            "scheduleAnalysis revision=\(snapshot.revision.uuidString) force=\(force) remoteDebounceMs=\(force ? 0 : self.configurationStore.configuration.debounceMilliseconds)"
        )
        debounceTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            await performAnalysis(
                for: snapshot,
                seedBatch: seedBatch,
                remoteDebounceNanoseconds: remoteDebounceNanoseconds
            )
        }
    }

    private func performAnalysis(
        for snapshot: TextSnapshot,
        seedBatch: SuggestionBatch? = nil,
        remoteDebounceNanoseconds: UInt64 = 0
    ) async {
        guard activeSnapshot?.revision == snapshot.revision else {
            DebugLogger.log("performAnalysis skipped stale revision=\(snapshot.revision.uuidString)")
            return
        }
        DebugLogger.log("performAnalysis start revision=\(snapshot.revision.uuidString) lang=\(snapshot.languageHint.rawValue)")
        model.llmStatus = .running(localized("Reviewing \(snapshot.languageHint.rawValue)", zh: "正在审阅 \(snapshot.languageHint.rawValue)"))

        let localBatch: SuggestionBatch
        if let seedBatch, seedBatch.isReusable(for: snapshot) {
            localBatch = seedBatch
            DebugLogger.log("performAnalysis using seed suggestions=\(localBatch.suggestions.count)")
        } else {
            localBatch = reviewEngine.localSuggestions(for: snapshot)
            DebugLogger.log("local suggestions=\(localBatch.suggestions.count)")
            activeBatch = localBatch
            model.activeBatch = localBatch
            renderOverlay(snapshot: snapshot, batch: localBatch)
            persistSuggestionBatch(localBatch, for: snapshot, stage: "local")
        }

        remoteReviewTask = Task { [weak self] in
            guard let self else { return }
            var bestBatch = localBatch
            do {
                let offlineChinese = try await reviewEngine.offlineChineseSuggestions(
                    for: snapshot,
                    configuration: configurationStore.configuration
                )
                DebugLogger.log("offline Chinese suggestions success count=\(offlineChinese.suggestions.count)")
                guard !Task.isCancelled else { return }
                if !offlineChinese.suggestions.isEmpty {
                    bestBatch = ReviewEngine.merge(local: bestBatch, remote: offlineChinese)
                    await MainActor.run {
                        guard self.activeSnapshot?.revision == snapshot.revision else { return }
                        self.activeBatch = bestBatch
                        self.model.activeBatch = bestBatch
                        self.model.llmStatus = .success(self.localized("Offline Chinese review found \(bestBatch.suggestions.count) suggestions", zh: "离线中文校对返回 \(bestBatch.suggestions.count) 条建议"))
                        self.renderOverlay(snapshot: snapshot, batch: bestBatch)
                        self.persistSuggestionBatch(bestBatch, for: snapshot, stage: "offline-chinese")
                    }
                }
            } catch {
                DebugLogger.log("offline Chinese suggestions failed error=\(error.localizedDescription)")
            }

            guard reviewEngine.shouldRunRemoteReview(for: snapshot) else {
                DebugLogger.log("remote review skipped for CJK offline-only text")
                await MainActor.run {
                    guard self.activeSnapshot?.revision == snapshot.revision else { return }
                    self.model.llmStatus = .success(self.localized("Offline review found \(bestBatch.suggestions.count) suggestions", zh: "离线校对返回 \(bestBatch.suggestions.count) 条建议"))
                    self.renderOverlay(snapshot: snapshot, batch: bestBatch)
                }
                return
            }

            if remoteDebounceNanoseconds > 0 {
                DebugLogger.log("remote review debounce before LLM ms=\(remoteDebounceNanoseconds / 1_000_000)")
                try? await Task.sleep(nanoseconds: remoteDebounceNanoseconds)
                guard !Task.isCancelled else { return }
            }

            do {
                let remote = try await reviewEngine.remoteSuggestions(
                    for: snapshot,
                    configuration: configurationStore.configuration
                )
                DebugLogger.log("remote suggestions success count=\(remote.suggestions.count)")
                guard !Task.isCancelled else { return }
                let merged = ReviewEngine.merge(local: bestBatch, remote: remote)
                bestBatch = merged
                await MainActor.run {
                    guard self.activeSnapshot?.revision == snapshot.revision else { return }
                    self.activeBatch = merged
                    self.model.activeBatch = merged
                    self.model.llmStatus = .success(self.localized("Received \(merged.suggestions.count) suggestions", zh: "收到 \(merged.suggestions.count) 条建议"))
                    self.renderOverlay(snapshot: snapshot, batch: merged)
                    self.persistSuggestionBatch(merged, for: snapshot, stage: "remote")
                }
            } catch {
                DebugLogger.log("remote suggestions failed error=\(error.localizedDescription)")
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.activeSnapshot?.revision == snapshot.revision else { return }
                    self.model.llmStatus = .failed(error.localizedDescription)
                    self.model.lastErrorMessage = error.localizedDescription
                    self.renderOverlay(snapshot: snapshot, batch: bestBatch)
                }
            }

            do {
                let judgedRed = try await reviewEngine.adjudicateRedSuggestions(
                    for: snapshot,
                    suggestions: bestBatch.suggestions,
                    configuration: configurationStore.configuration
                )
                DebugLogger.log(
                    "red LLM judge success input=\(bestBatch.suggestions.filter { $0.kind == .spelling }.count) output=\(judgedRed.suggestions.count)"
                )
                guard !Task.isCancelled else { return }
                let adjudicated = ReviewEngine.replacingRedSuggestions(in: bestBatch, with: judgedRed)
                bestBatch = adjudicated
                await MainActor.run {
                    guard self.activeSnapshot?.revision == snapshot.revision else { return }
                    self.activeBatch = adjudicated
                    self.model.activeBatch = adjudicated
                    self.model.llmStatus = .success(self.localized("Red suggestions judged · \(adjudicated.suggestions.count) suggestions", zh: "红线已审查 · \(adjudicated.suggestions.count) 条建议"))
                    self.renderOverlay(snapshot: snapshot, batch: adjudicated)
                    self.persistSuggestionBatch(adjudicated, for: snapshot, stage: "redJudge")
                }
            } catch {
                DebugLogger.log("red LLM judge failed error=\(error.localizedDescription)")
            }
        }
    }

    private func renderOverlay(
        snapshot: TextSnapshot,
        batch: SuggestionBatch,
        reuseCachedSuggestionGeometry: Bool = false
    ) {
        guard let context = activeContext else {
            overlayManager.clear()
            return
        }

        let frame = snapshot.elementBounds.insetBy(dx: -20, dy: -20)
        let filtered = batch.suggestions.filter { !ignoredSuggestionKeys.contains($0.stableIdentity) }
        let renderedRects: [RenderedSuggestion]
        let missingBounds: Bool

        if reuseCachedSuggestionGeometry {
            let cachedByStableIdentity = Dictionary(
                uniqueKeysWithValues: overlayManager.lastRenderedSuggestionRects.map { ($0.suggestion.stableIdentity, $0.screenRect) }
            )
            let cachedByID = Dictionary(
                uniqueKeysWithValues: overlayManager.lastRenderedSuggestionRects.map { ($0.suggestion.id, $0.screenRect) }
            )
            let reusedRects = filtered.compactMap { suggestion -> RenderedSuggestion? in
                guard let cachedScreenRect = cachedByStableIdentity[suggestion.stableIdentity] ?? cachedByID[suggestion.id] else {
                    return nil
                }
                return renderedSuggestion(for: suggestion, screenRect: cachedScreenRect, frame: frame)
            }
            if reusedRects.count == filtered.count {
                renderedRects = reusedRects
                missingBounds = false
                DebugLogger.log(
                    "renderOverlay reused cached suggestion geometry count=\(renderedRects.count) revision=\(snapshot.revision.uuidString)"
                )
            } else {
                let computedRects = filtered.compactMap { suggestion -> RenderedSuggestion? in
                    guard let screenRect = accessibilityService.bounds(for: suggestion.rangeInFullText, in: context.element) else {
                        return nil
                    }
                    return renderedSuggestion(for: suggestion, screenRect: screenRect, frame: frame)
                }
                renderedRects = computedRects
                missingBounds = filtered.count != computedRects.count
            }
        } else {
            let computedRects = filtered.compactMap { suggestion -> RenderedSuggestion? in
                guard let screenRect = accessibilityService.bounds(for: suggestion.rangeInFullText, in: context.element) else {
                    return nil
                }
                return renderedSuggestion(for: suggestion, screenRect: screenRect, frame: frame)
            }
            renderedRects = computedRects
            missingBounds = filtered.count != computedRects.count
        }
        DebugLogger.log(
            "renderOverlay filtered=\(filtered.count) renderedRects=\(renderedRects.count) missingBounds=\(missingBounds)"
        )

        var vbarRect: CGRect?
        if let rewriteRange = rewriteTargetRange(for: snapshot),
           let selectedBounds = rewriteRailBounds(for: rewriteRange, snapshot: snapshot, context: context)
        {
            vbarRect = CGRect(
                x: selectedBounds.minX - 8,
                y: selectedBounds.minY,
                width: 4,
                height: max(selectedBounds.height, 16)
            )
            DebugLogger.log(
                "renderOverlay vbar target=\(rewriteRange.location):\(rewriteRange.length) selectedBounds=\(NSStringFromRect(selectedBounds)) vbarScreenRect=\(NSStringFromRect(vbarRect!))"
            )
        }
        let caretRect = snapshot.selectedRange.length == 0 ? caretScreenRect(for: snapshot.selectedRange, in: context) : nil
        let analysisGuideRect = activeAnalysisGuideRect(snapshot: snapshot, context: context)

        overlayManager.updateOverlay(
            snapshot: snapshot,
            suggestions: filtered,
            suggestionRects: renderedRects,
            vbarScreenRect: vbarRect,
            caretScreenRect: caretRect,
            analysisGuideScreenRect: analysisGuideRect,
            showFallbackBadge: missingBounds && !filtered.isEmpty
        )
        DebugLogger.log("overlay updated vbar=\(vbarRect != nil) guide=\(analysisGuideRect != nil)")
    }

    private func activeAnalysisGuideRect(snapshot: TextSnapshot, context: FocusedTextContext) -> CGRect? {
        guard snapshot.analysisRangeInFullText.location != NSNotFound,
              snapshot.analysisRangeInFullText.length > 0,
              NSMaxRange(snapshot.analysisRangeInFullText) <= (snapshot.fullText as NSString).length,
              let bounds = accessibilityService.bounds(for: snapshot.analysisRangeInFullText, in: context.element)
        else {
            return nil
        }
        return CGRect(
            x: bounds.minX,
            y: bounds.minY,
            width: max(bounds.width, 40),
            height: max(bounds.height, 16)
        )
    }

    private func rewriteRailBounds(
        for range: NSRange,
        snapshot: TextSnapshot,
        context: FocusedTextContext
    ) -> CGRect? {
        if let bounds = accessibilityService.bounds(for: range, in: context.element) {
            return bounds
        }
        if snapshot.selectedRange.length == 0 {
            return caretScreenRect(for: snapshot.selectedRange, in: context)
        }
        return nil
    }

    private func showFallbackSuggestionHover() {
        guard let batch = activeBatch else { return }
        guard let selected = batch.suggestions.first(where: { !ignoredSuggestionKeys.contains($0.stableIdentity) }) else { return }
        overlayManager.showSuggestionHover(for: selected)
    }

    private func showAIPanel() {
        guard presentAIPanelForCurrentSelection() else { return }
        aiPreviewTask?.cancel()
        aiPreviewTask = Task { @MainActor [weak self] in
            await self?.runAIAction(.formal)
        }
    }

    @discardableResult
    private func presentAIPanelForCurrentSelection() -> Bool {
        guard let snapshot = activeSnapshot else { return false }
        guard let context = activeContext else { return false }
        guard preparePendingAISelection(from: snapshot) else { return false }
        guard let range = pendingAISelectionRange,
              let selectedText = pendingAISelectionText,
              let selectedBounds = rewriteRailBounds(for: range, snapshot: snapshot, context: context)
        else { return false }
        DebugLogger.log("showAIPanel target=\(range.location):\(range.length)")
        overlayManager.aiViewModel.resetForNewSelection(sourceText: selectedText)
        let anchor = CGPoint(x: selectedBounds.minX - 10, y: selectedBounds.maxY + 12)
        // Collapse Word/TextEdit's native selection before bringing up the
        // floating panel. If the selection is left active under a
        // non-activating panel, Word can enter multi-selection behavior when a
        // stale Command modifier is present or when the user immediately starts
        // selecting another range.
        if snapshot.selectedRange.length > 0 {
            collapsePendingAISelection(in: context, selectionRange: snapshot.selectedRange, trigger: "showAIPanel")
        }
        overlayManager.showAIPanel(at: anchor, originalText: selectedText)
        return true
    }

    private func generateAllAIPreviewsForPendingSelection() async {
        guard let snapshot = activeSnapshot,
              let range = pendingAISelectionRange,
              let selectedText = pendingAISelectionText,
              pendingAIRevision == snapshot.revision
        else {
            setAIError(localized("Selection changed. Re-select text.", zh: "选区已变化，请重新选择文本。"))
            return
        }

        let actions = ReviewAction.allCases
        overlayManager.aiViewModel.beginLoadingAll(actions)
        setAIError(nil)
        DebugLogger.log("generateAllAIPreviews start actions=\(actions.map(\.rawValue).joined(separator: ","))")

        let surroundingContext = ParagraphContextExtractor.surroundingContext(
            from: snapshot.fullText,
            targetRange: range
        )
        let languageHint = snapshot.languageHint
        let configuration = configurationStore.configuration

        for action in actions {
            guard !Task.isCancelled else { return }
            guard activeSnapshot?.revision == snapshot.revision,
                  pendingAIRevision == snapshot.revision
            else {
                DebugLogger.log("generateAllAIPreviews stopped stale before action=\(action.rawValue)")
                return
            }

            let request = AIActionRequest(
                action: action,
                selectedText: selectedText,
                surroundingContext: surroundingContext,
                languageHint: languageHint
            )
            let result = await performAIActionWithRetry(
                request: request,
                configuration: configuration,
                logPrefix: "generateAllAIPreviews action=\(action.rawValue)"
            )

            guard activeSnapshot?.revision == snapshot.revision,
                  pendingAIRevision == snapshot.revision
            else {
                DebugLogger.log("generateAllAIPreviews skipped stale action=\(action.rawValue)")
                return
            }
            applyAIActionResult(result, for: action, selectedText: selectedText)
        }
        DebugLogger.log("generateAllAIPreviews complete")
    }

    private func runAIAction(_ action: ReviewAction) async {
        guard let snapshot = activeSnapshot,
              let range = pendingAISelectionRange,
              let selectedText = pendingAISelectionText,
              pendingAIRevision == snapshot.revision
        else {
            setAIError(localized("Selection changed. Re-select text.", zh: "选区已变化，请重新选择文本。"))
            return
        }

        overlayManager.aiViewModel.beginLoading(action)
        setAIError(nil)
        DebugLogger.log("runAIAction action=\(action.rawValue)")
        let request = AIActionRequest(
            action: action,
            selectedText: selectedText,
            surroundingContext: ParagraphContextExtractor.surroundingContext(from: snapshot.fullText, targetRange: range),
            languageHint: snapshot.languageHint
        )
        let result = await performAIActionWithRetry(
            request: request,
            configuration: configurationStore.configuration,
            logPrefix: "runAIAction action=\(action.rawValue)"
        )
        switch result {
        case let .success(actionResult):
            applyAIActionResult(.success(actionResult), for: action, selectedText: selectedText)
            DebugLogger.log("runAIAction success previewLength=\((actionResult.replacement as NSString).length)")
        case let .failure(error):
            applyAIActionResult(.failure(error), for: action, selectedText: selectedText)
            DebugLogger.log("runAIAction failed error=\(error.localizedDescription)")
        }
    }

    private func performAIActionWithRetry(
        request: AIActionRequest,
        configuration: AppConfiguration,
        logPrefix: String,
        maxAttempts: Int = 3
    ) async -> Result<ReviewActionResult, Error> {
        var lastError: Error?
        for attempt in 1 ... maxAttempts {
            guard !Task.isCancelled else {
                return .failure(CancellationError())
            }
            do {
                let result = try await reviewEngine.performAction(
                    request: request,
                    configuration: configuration
                )
                if attempt > 1 {
                    DebugLogger.log("\(logPrefix) retrySucceeded attempt=\(attempt)")
                }
                return .success(result)
            } catch {
                lastError = error
                DebugLogger.log("\(logPrefix) attempt=\(attempt) failed error=\(error.localizedDescription)")
                guard attempt < maxAttempts else { break }
                try? await Task.sleep(nanoseconds: UInt64(350 * attempt) * 1_000_000)
            }
        }
        return .failure(lastError ?? LLMError.invalidResponse)
    }

    private func applyAIActionResult(
        _ result: Result<ReviewActionResult, Error>,
        for action: ReviewAction,
        selectedText: String
    ) {
        switch result {
        case let .success(actionResult):
            let replacement = actionResult.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !replacement.isEmpty else {
                overlayManager.aiViewModel.setError(localized("Empty preview returned.", zh: "返回的预览为空。"), for: action)
                syncModelSelectedAIState()
                return
            }
            guard replacement != selectedText else {
                overlayManager.aiViewModel.setError(localized("No change suggested.", zh: "没有建议修改。"), for: action)
                syncModelSelectedAIState()
                return
            }
            overlayManager.aiViewModel.setResult(
                ReviewActionResult(replacement: replacement, explanation: actionResult.explanation),
                for: action
            )
        case let .failure(error):
            overlayManager.aiViewModel.setError(error.localizedDescription, for: action)
        }
        syncModelSelectedAIState()
    }

    private func syncModelSelectedAIState() {
        model.lastActionPreview = overlayManager.aiViewModel.preview
        model.lastActionExplanation = overlayManager.aiViewModel.explanation
        model.lastErrorMessage = overlayManager.aiViewModel.errorMessage
    }

    @discardableResult
    private func acceptSuggestion(_ suggestion: Suggestion) async -> Bool {
        guard let snapshot = activeSnapshot else {
            model.lastErrorMessage = localized("Suggestion is stale. Reanalyzing.", zh: "建议已过期，正在重新分析。")
            DebugLogger.log("acceptSuggestion skipped noActiveSnapshot")
            return false
        }
        guard let context = activeContext else {
            model.lastErrorMessage = localized("No active text context.", zh: "没有可用的文本上下文。")
            DebugLogger.log("acceptSuggestion skipped noActiveContext")
            refreshFocusContext(trigger: "acceptNoContext")
            return false
        }
        let commands = preferredReplacementStrategies(for: context)
            .map { ReplacementPlanner.makeCommand(suggestion: suggestion, snapshot: snapshot, strategy: $0) }
        return await executeReplacement(
            commands: commands,
            snapshot: snapshot,
            context: context,
            staleMessage: localized("Suggestion is stale. Reanalyzing.", zh: "建议已过期，正在重新分析。"),
            staleTrigger: "stale",
            successTrigger: "postReplace",
            setError: { [weak self] in self?.model.lastErrorMessage = $0 },
            versionAction: "acceptSuggestion"
        )
    }

    private func acceptSuggestion(withID suggestionID: UUID) async {
        guard let suggestion = activeBatch?.suggestions.first(where: { $0.id == suggestionID }) else {
            model.lastErrorMessage = localized("Suggestion is no longer available.", zh: "该建议已不可用。")
            return
        }
        _ = await acceptSuggestion(suggestion)
    }

    private func ignoreSuggestion(_ suggestion: Suggestion) {
        ignoredSuggestionKeys.insert(suggestion.stableIdentity)
        DebugLogger.log("ignoreSuggestion \(suggestion.stableIdentity)")
        if let snapshot = activeSnapshot, let batch = activeBatch {
            model.activeBatch = SuggestionBatch(
                snapshotRevision: batch.snapshotRevision,
                paragraphIdentity: batch.paragraphIdentity,
                suggestions: batch.suggestions.filter { !ignoredSuggestionKeys.contains($0.stableIdentity) }
            )
            renderOverlay(snapshot: snapshot, batch: batch)
        }
    }

    private func ignoreSuggestion(withID suggestionID: UUID) {
        guard let suggestion = activeBatch?.suggestions.first(where: { $0.id == suggestionID }) else {
            model.lastErrorMessage = localized("Suggestion is no longer available.", zh: "该建议已不可用。")
            return
        }
        ignoreSuggestion(suggestion)
    }

    @discardableResult
    private func replaceAISelection() async -> Bool {
        guard let snapshot = activeSnapshot,
              let range = pendingAISelectionRange,
              let original = pendingAISelectionText,
              pendingAIRevision == snapshot.revision
        else {
            setAIError(localized("Selection changed. Re-select text.", zh: "选区已变化，请重新选择文本。"))
            return false
        }
        guard let context = activeContext else {
            setAIError(localized("No active text context.", zh: "没有可用的文本上下文。"))
            DebugLogger.log("replaceAISelection skipped noActiveContext")
            refreshFocusContext(trigger: "replaceAINoContext")
            return false
        }

        let replacement = overlayManager.aiViewModel.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replacement.isEmpty else {
            setAIError(localized("No preview to replace.", zh: "没有可替换的预览。"))
            return false
        }
        guard replacement != original else {
            setAIError(localized("Preview is identical to the original selection.", zh: "预览与原选中文本相同。"))
            return false
        }
        DebugLogger.log("replaceAISelection replacementLength=\((replacement as NSString).length)")

        let commands = preferredAIReplacementStrategies(for: context).map {
            ReplaceCommand(
                targetRange: range,
                expectedOriginalText: original,
                replacementText: replacement,
                strategy: $0,
                snapshotRevision: snapshot.revision
            )
        }
        let replaced = await executeReplacement(
            commands: commands,
            snapshot: snapshot,
            context: context,
            staleMessage: localized("Selection is stale.", zh: "选区已过期。"),
            staleTrigger: "staleAI",
            successTrigger: "postAIReplace",
            setError: { [weak self] in self?.setAIError($0) },
            versionAction: "aiReplace"
        )
        if replaced {
            clearPendingAISelection()
        }
        return replaced
    }

    private func runAIActionFromStatus(_ action: ReviewAction) async {
        refreshFocusContext(trigger: "statusAI")
        guard let snapshot = activeSnapshot,
              let context = activeContext,
              preparePendingAISelection(from: snapshot)
        else {
            setAIError(localized("Place the cursor in a paragraph before running AI actions.", zh: "请先将光标放在段落中再运行 AI 操作。"))
            return
        }
        if snapshot.selectedRange.length > 0 {
            collapsePendingAISelection(in: context, selectionRange: snapshot.selectedRange, trigger: "statusAI")
        }
        await runAIAction(action)
    }

    private func replaceAISelectionFromStatus() async {
        refreshFocusContext(trigger: "statusReplaceAI")
        _ = await replaceAISelection()
    }

    private func preparePendingAISelection(from snapshot: TextSnapshot) -> Bool {
        guard let targetRange = rewriteTargetRange(for: snapshot) else { return false }
        let targetText = selectedSubstring(from: snapshot.fullText, range: targetRange)
        guard !targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        pendingAISelectionRange = targetRange
        pendingAISelectionText = targetText
        pendingAIRevision = snapshot.revision
        return true
    }

    private func rewriteTargetRange(for snapshot: TextSnapshot) -> NSRange? {
        let nsText = snapshot.fullText as NSString
        guard nsText.length > 0 else { return nil }
        if snapshot.selectedRange.location != NSNotFound,
           snapshot.selectedRange.length > 0,
           NSMaxRange(snapshot.selectedRange) <= nsText.length
        {
            return snapshot.selectedRange
        }

        let safeLocation = min(max(0, snapshot.selectedRange.location), nsText.length)
        let anchorLocation = safeLocation == nsText.length ? max(0, nsText.length - 1) : safeLocation
        let paragraphRange = nsText.paragraphRange(for: NSRange(location: anchorLocation, length: 0))
        guard paragraphRange.location != NSNotFound,
              paragraphRange.length > 0,
              NSMaxRange(paragraphRange) <= nsText.length
        else {
            return nil
        }
        return paragraphRange
    }

    private func clearPendingAISelection() {
        pendingAISelectionRange = nil
        pendingAISelectionText = nil
        pendingAIRevision = nil
    }

    private func collapsePendingAISelection(
        in context: FocusedTextContext,
        selectionRange: NSRange,
        trigger: String
    ) {
        let textLength = (context.fullText as NSString).length
        let caretLocation = min(max(selectionRange.location + selectionRange.length, 0), textLength)
        let caretRange = NSRange(location: caretLocation, length: 0)
        if shouldActivateHostBeforeAXCommand(context) || context.application.bundleIdentifier == "com.apple.TextEdit" {
            let activated = context.application.activate(options: [.activateIgnoringOtherApps])
            DebugLogger.log("collapsePendingAISelection activateHostApp=\(activated) trigger=\(trigger)")
        }
        let focusApplied = accessibilityService.setFocused(context.element)
        let selectionApplied = accessibilityService.setSelectedRange(caretRange, on: context.element)
        DebugLogger.log(
            "collapsePendingAISelection trigger=\(trigger) focusApplied=\(focusApplied) selectionApplied=\(selectionApplied) caret=\(caretLocation)"
        )
        guard selectionApplied else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            self?.refreshFocusContext(trigger: "collapsePendingAISelection")
        }
    }

    private func shouldPreserveCollapsedAISelection(for snapshot: TextSnapshot) -> Bool {
        guard let previousSnapshot = activeSnapshot,
              let pendingRange = pendingAISelectionRange,
              let pendingRevision = pendingAIRevision,
              pendingRevision == snapshot.revision,
              previousSnapshot.revision == snapshot.revision,
              previousSnapshot.elementIdentity == snapshot.elementIdentity,
              previousSnapshot.selectedRange == pendingRange,
              snapshot.selectedRange.length == 0
        else {
            return false
        }
        return pendingAISelectionText == selectedSubstring(from: snapshot.fullText, range: pendingRange)
    }

    private func cancelAIInteraction() {
        aiPreviewTask?.cancel()
        aiPreviewTask = nil
        clearPendingAISelection()
        overlayManager.dismissPanels()
    }

    private func preferredReplacementStrategies(for context: FocusedTextContext) -> [ReplaceStrategy] {
        let strategies = ReplacementPlanner.strategies(for: ReplacementCapabilities())
        guard isSupportedTextContext(context) else {
            return strategies
        }
        if context.application.bundleIdentifier == "com.microsoft.Word" {
            // Word often reports AXSelectedText writes as successful without
            // changing AXValue. Prefer verified paste for Word so Diff apply /
            // rollback do not visibly stop at "selected but not replaced".
            return [.nativePaste, .typingFallback, .axSelectedText].filter { strategies.contains($0) }
        }
        return [.axSelectedText, .nativePaste, .typingFallback].filter { strategies.contains($0) }
    }

    private func preferredAIReplacementStrategies(for context: FocusedTextContext) -> [ReplaceStrategy] {
        let strategies = ReplacementPlanner.strategies(for: ReplacementCapabilities())
        guard isSupportedTextContext(context) else {
            return strategies
        }
        // The AI rewrite panel is a non-activating floating panel. In Notes/Mail/TextEdit,
        // AXSelectedText can report success after only restoring the selection, so the
        // visible result looks like "selected text, panel gone". Prefer host-activated
        // paste/typing for this panel path, and keep AXSelectedText as the final fallback.
        return [.nativePaste, .typingFallback, .axSelectedText].filter { strategies.contains($0) }
    }

    private func shouldUseWordRangeAutomationFallback(for context: FocusedTextContext) -> Bool {
        context.application.bundleIdentifier == "com.microsoft.Word"
    }

    private func setAIError(_ message: String?) {
        overlayManager.aiViewModel.setGlobalError(message)
        model.lastErrorMessage = message
    }

    private func supportedPreferredBundleIdentifiers() -> [String] {
        Array(supportedNativeAppBundleIdentifiers).sorted()
    }

    private func isSupportedTextContext(_ context: FocusedTextContext) -> Bool {
        guard context.application.bundleIdentifier != Bundle.main.bundleIdentifier else { return false }
        if let bundleIdentifier = context.application.bundleIdentifier,
           supportedNativeAppBundleIdentifiers.contains(bundleIdentifier)
        {
            return true
        }
        return context.role == String(kAXTextFieldRole) || context.role == String(kAXComboBoxRole)
    }

    private func renderedSuggestion(for suggestion: Suggestion, screenRect: CGRect, frame: CGRect) -> RenderedSuggestion {
        let localRect = CGRect(
            x: screenRect.origin.x - frame.origin.x,
            y: screenRect.origin.y - frame.origin.y,
            width: screenRect.width,
            height: screenRect.height
        )
        DebugLogger.log(
            "renderOverlay suggestion kind=\(suggestion.kind.rawValue) range=\(suggestion.rangeInFullText.location):\(suggestion.rangeInFullText.length) original=\(suggestion.originalText) screenRect=\(NSStringFromRect(screenRect)) localRect=\(NSStringFromRect(localRect))"
        )
        return RenderedSuggestion(suggestion: suggestion, screenRect: screenRect, localRect: localRect)
    }

    private func executeReplacement(
        commands: [ReplaceCommand],
        snapshot: TextSnapshot,
        context: FocusedTextContext,
        staleMessage: String,
        staleTrigger: String,
        successTrigger: String,
        setError: @escaping @MainActor (String?) -> Void,
        versionAction: String? = nil
    ) async -> Bool {
        if shouldActivateHostBeforeAXCommand(context) {
            let activated = context.application.activate()
            DebugLogger.log("executeReplacement activateHostApp=\(activated)")
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        for command in commands {
            DebugLogger.log(
                "executeReplacement strategy=\(command.strategy.rawValue) target=\(command.targetRange.location):\(command.targetRange.length)"
            )
            guard ReplacementPlanner.validate(command: command, currentText: context.fullText, currentRevision: snapshot.revision) else {
                setError(staleMessage)
                refreshFocusContext(trigger: staleTrigger)
                DebugLogger.log("executeReplacement stale strategy=\(command.strategy.rawValue)")
                return false
            }
            let suggestionsForOptimisticRebase = activeBatch?.suggestions ?? []
            do {
                isExecutingReplacement = true
                try await replacementExecutor.execute(command: command, in: context)
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard replacementAppearsApplied(command, in: context) else {
                    isExecutingReplacement = false
                    DebugLogger.log(
                        "executeReplacement verification failed strategy=\(command.strategy.rawValue) target=\(command.targetRange.location):\(command.targetRange.length); trying next strategy"
                    )
                    continue
                }
                applyOptimisticReplacement(
                    command: command,
                    snapshot: snapshot,
                    context: context,
                    existingSuggestions: suggestionsForOptimisticRebase
                )
                if let versionAction {
                    recordVersionIfNeeded(action: versionAction, command: command, beforeSnapshot: snapshot)
                }
                isExecutingReplacement = false
                overlayManager.dismissPanels()
                setError(nil)
                DebugLogger.log("executeReplacement success strategy=\(command.strategy.rawValue)")
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    self?.refreshFocusContext(trigger: successTrigger)
                }
                return true
            } catch {
                isExecutingReplacement = false
                setError(error.localizedDescription)
                DebugLogger.log("executeReplacement failed strategy=\(command.strategy.rawValue) error=\(error.localizedDescription)")
            }
        }
        if shouldUseWordRangeAutomationFallback(for: context),
           let command = commands.first
        {
            DebugLogger.log(
                "executeReplacement strategy=wordAutomation target=\(command.targetRange.location):\(command.targetRange.length)"
            )
            guard ReplacementPlanner.validate(command: command, currentText: context.fullText, currentRevision: snapshot.revision) else {
                setError(staleMessage)
                refreshFocusContext(trigger: staleTrigger)
                DebugLogger.log("executeReplacement stale strategy=wordAutomation")
                return false
            }
            let suggestionsForOptimisticRebase = activeBatch?.suggestions ?? []
            do {
                isExecutingReplacement = true
                try await replacementExecutor.executeWordRangeReplacement(command: command, in: context)
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard replacementAppearsApplied(command, in: context, attemptLabel: "wordAutomation") else {
                    isExecutingReplacement = false
                    setError(localized("Replacement did not change the Word document.", zh: "Word 文档内容未发生变化。"))
                    DebugLogger.log(
                        "executeReplacement verification failed strategy=wordAutomation target=\(command.targetRange.location):\(command.targetRange.length)"
                    )
                    return false
                }
                applyOptimisticReplacement(
                    command: command,
                    snapshot: snapshot,
                    context: context,
                    existingSuggestions: suggestionsForOptimisticRebase
                )
                if let versionAction {
                    recordVersionIfNeeded(action: versionAction, command: command, beforeSnapshot: snapshot)
                }
                isExecutingReplacement = false
                overlayManager.dismissPanels()
                setError(nil)
                DebugLogger.log("executeReplacement success strategy=wordAutomation")
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    self?.refreshFocusContext(trigger: successTrigger)
                }
                return true
            } catch {
                isExecutingReplacement = false
                setError(error.localizedDescription)
                DebugLogger.log("executeReplacement failed strategy=wordAutomation error=\(error.localizedDescription)")
            }
        }
        return false
    }

    private func replacementAppearsApplied(
        _ command: ReplaceCommand,
        in context: FocusedTextContext,
        attemptLabel: String? = nil
    ) -> Bool {
        guard let currentText = accessibilityService.stringAttribute(kAXValueAttribute as CFString, on: context.element) else {
            DebugLogger.log("executeReplacement verification skipped: unable to read AXValue")
            return true
        }
        let previousText = context.fullText as NSString
        guard command.targetRange.location != NSNotFound,
              command.targetRange.location >= 0,
              NSMaxRange(command.targetRange) <= previousText.length
        else {
            return false
        }
        let expectedText = previousText.replacingCharacters(in: command.targetRange, with: command.replacementText)
        if currentText == expectedText {
            return true
        }
        let currentLength = (currentText as NSString).length
        let strategy = attemptLabel ?? command.strategy.rawValue
        DebugLogger.log(
            "executeReplacement verification mismatch strategy=\(strategy) expectedLength=\((expectedText as NSString).length) actualLength=\(currentLength)"
        )
        return false
    }

    private func applyOptimisticReplacement(
        command: ReplaceCommand,
        snapshot: TextSnapshot,
        context: FocusedTextContext,
        existingSuggestions: [Suggestion]
    ) {
        let nsText = snapshot.fullText as NSString
        guard command.targetRange.location != NSNotFound,
              command.targetRange.location >= 0,
              NSMaxRange(command.targetRange) <= nsText.length
        else { return }

        let replacementLength = (command.replacementText as NSString).length
        let delta = replacementLength - command.targetRange.length
        let newFullText = nsText.replacingCharacters(in: command.targetRange, with: command.replacementText)
        let newAnalysisRange = adjustedAnalysisRange(
            snapshot.analysisRangeInFullText,
            replacing: command.targetRange,
            delta: delta,
            newTextLength: (newFullText as NSString).length
        )
        let newAnalysisText = (newFullText as NSString).substring(with: newAnalysisRange)
        let newRevision = UUID()
        let newSnapshot = TextSnapshot(
            appBundleId: snapshot.appBundleId,
            elementIdentity: snapshot.elementIdentity,
            fullText: newFullText,
            selectedRange: NSRange(location: command.targetRange.location + replacementLength, length: 0),
            analysisText: newAnalysisText,
            analysisRangeInFullText: newAnalysisRange,
            elementBounds: snapshot.elementBounds,
            revision: newRevision,
            languageHint: LanguageRouter.detectLanguage(for: newAnalysisText)
        )
        let optimisticSuggestions = optimisticallyRebasedSuggestions(
            replacing: command.targetRange,
            replacementLength: replacementLength,
            in: existingSuggestions
        )
        let optimisticBatch = SuggestionBatch(
            snapshotRevision: newRevision,
            paragraphIdentity: newSnapshot.paragraphIdentity,
            suggestions: optimisticSuggestions
        )

        lastTextFingerprint = "\(context.elementIdentity)|\(newFullText)"
        activeSnapshot = newSnapshot
        model.activeSnapshot = newSnapshot
        activeBatch = optimisticBatch
        model.activeBatch = optimisticBatch
        renderOverlay(snapshot: newSnapshot, batch: optimisticBatch, reuseCachedSuggestionGeometry: true)
        DebugLogger.log(
            "optimistic replacement applied target=\(command.targetRange.location):\(command.targetRange.length) delta=\(delta) remainingSuggestions=\(optimisticSuggestions.count)"
        )
    }

    private func adjustedAnalysisRange(
        _ analysisRange: NSRange,
        replacing targetRange: NSRange,
        delta: Int,
        newTextLength: Int
    ) -> NSRange {
        var location = analysisRange.location
        var length = analysisRange.length
        if NSMaxRange(targetRange) <= analysisRange.location {
            location += delta
        } else if targetRange.location < NSMaxRange(analysisRange) {
            length += delta
        }
        location = min(max(location, 0), newTextLength)
        length = min(max(length, 0), newTextLength - location)
        return NSRange(location: location, length: length)
    }

    private func optimisticallyRebasedSuggestions(
        replacing targetRange: NSRange,
        replacementLength: Int,
        in suggestions: [Suggestion]
    ) -> [Suggestion] {
        let delta = replacementLength - targetRange.length
        let targetEnd = NSMaxRange(targetRange)
        return suggestions.compactMap { suggestion in
            guard NSIntersectionRange(suggestion.rangeInFullText, targetRange).length == 0 else {
                return nil
            }
            var shifted = suggestion
            if shifted.rangeInFullText.location >= targetEnd {
                shifted.rangeInFullText.location += delta
            }
            return shifted
        }
    }

    private func selectedSubstring(from text: String, range: NSRange) -> String {
        let nsText = text as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= nsText.length else { return "" }
        return nsText.substring(with: range)
    }

    private func shouldActivateHostBeforeAXCommand(_ context: FocusedTextContext) -> Bool {
        guard let bundleIdentifier = context.application.bundleIdentifier else { return false }
        return supportedNativeAppBundleIdentifiers.contains(bundleIdentifier)
    }

    private func installLocalKeyMonitor() {
        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: ghostKeyboardEventCallback,
            userInfo: Unmanaged.passUnretained(ghostKeyboardBridge).toOpaque()
        ) {
            keyboardEventTap = tap
            keyboardRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let keyboardRunLoopSource {
                CFRunLoopAddSource(CFRunLoopGetMain(), keyboardRunLoopSource, .commonModes)
            }
            CGEvent.tapEnable(tap: tap, enable: true)
            DebugLogger.log("ghost key event tap installed")
            return
        }

        DebugLogger.log("ghost key event tap unavailable; installing local key monitor")
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self,
                  ghostKeyboardBridge.state.isVisible(),
                  event.keyCode == 48 || event.keyCode == 53
            else {
                return event
            }
            Task { @MainActor [weak self] in
                if event.keyCode == 48 {
                    await self?.acceptGhostSuggestion(trigger: "localTab")
                } else {
                    self?.rejectGhostSuggestion(trigger: "localEsc")
                }
            }
            return nil
        }
    }

    private func currentDocumentIdentity(snapshot: TextSnapshot, context: FocusedTextContext) -> DocumentIdentity {
        let title = context.window.flatMap {
            accessibilityService.stringAttribute(kAXTitleAttribute as CFString, on: $0)
        }
        return DocumentIdentity.resolve(snapshot: snapshot, windowTitle: title)
    }

    private func updateDocumentMemoryState(for snapshot: TextSnapshot, context: FocusedTextContext) {
        guard let memoryStore else {
            let message = memoryStoreInitializationError ?? "unknown SQLite initialization error"
            longformSidebar.viewModel.memoryStatus = "Memory error: \(message)"
            return
        }
        do {
            let identity = currentDocumentIdentity(snapshot: snapshot, context: context)
            let summary = conciseDocumentSummary(snapshot.fullText)
            let record = try memoryStore.upsertDocument(identity: identity, summary: summary)
            currentDocumentRecord = record
            longformSidebar.viewModel.documentName = record.identity.displayName
            longformSidebar.viewModel.memoryStatus = "SQLite memory: \(SQLiteWritingMemoryStore.defaultDatabaseURLForDisplay)"
            let activeSession = try ensureActiveConversationSession(
                for: record,
                preferredSessionID: longformSidebar.isVisible ? longformSidebar.viewModel.activeSessionID : nil
            )
            activeConversationSessionID = activeSession.id
            longformSidebar.viewModel.activeSessionID = activeSession.id
            longformSidebar.viewModel.sessions = try memoryStore.listConversationSessions(documentID: record.id)
            let lastVersion = try memoryStore.lastVersion(documentID: record.id)
            longformSidebar.viewModel.canRollback = lastVersion.map { !rolledBackVersionIDs.contains($0.id) } ?? false
            longformSidebar.viewModel.lastVersionSummary = lastVersion.map {
                "\($0.createdAt): \($0.action), patches=\($0.patches.count)"
            } ?? ""
            if longformSidebar.isVisible {
                longformSidebar.viewModel.conversation = try memoryStore.conversationTurns(inSession: activeSession.id, limit: 40)
            }
        } catch {
            longformSidebar.viewModel.memoryStatus = "Memory error: \(error.localizedDescription)"
            model.lastErrorMessage = error.localizedDescription
            DebugLogger.log("updateDocumentMemoryState failed error=\(error.localizedDescription)")
        }
    }

    private func ensureActiveConversationSession(
        for record: DocumentRecord,
        preferredSessionID: UUID? = nil
    ) throws -> ConversationSession {
        guard let memoryStore else {
            throw P4ControllerError.memoryUnavailable(memoryStoreInitializationError ?? "unknown SQLite initialization error")
        }
        let sessions = try memoryStore.listConversationSessions(documentID: record.id)
        if let preferredSessionID,
           let preferred = sessions.first(where: { $0.id == preferredSessionID })
        {
            activeConversationSessionByDocumentID[record.id] = preferred.id
            activeConversationSessionID = preferred.id
            return preferred
        }
        if let sessionID = activeConversationSessionByDocumentID[record.id],
           let active = sessions.first(where: { $0.id == sessionID })
        {
            activeConversationSessionID = active.id
            return active
        }
        if let active = activeConversationSessionID.flatMap({ id in sessions.first(where: { $0.id == id }) }) {
            activeConversationSessionByDocumentID[record.id] = active.id
            return active
        }
        if let latest = sessions.first {
            activeConversationSessionByDocumentID[record.id] = latest.id
            activeConversationSessionID = latest.id
            return latest
        }
        let created = try memoryStore.createConversationSession(documentID: record.id, title: "新会话")
        activeConversationSessionByDocumentID[record.id] = created.id
        activeConversationSessionID = created.id
        return created
    }

    private func refreshConversationSessions(record: DocumentRecord) {
        guard let memoryStore else { return }
        do {
            let activeSession = try ensureActiveConversationSession(
                for: record,
                preferredSessionID: longformSidebar.viewModel.activeSessionID
            )
            activeConversationSessionID = activeSession.id
            longformSidebar.viewModel.activeSessionID = activeSession.id
            longformSidebar.viewModel.sessions = try memoryStore.listConversationSessions(documentID: record.id)
            longformSidebar.viewModel.conversation = try memoryStore.conversationTurns(inSession: activeSession.id, limit: 40)
            longformSidebar.refreshLayout()
        } catch {
            longformSidebar.viewModel.setError(error.localizedDescription)
            model.lastErrorMessage = error.localizedDescription
        }
    }

    private func createNewConversationSession() {
        guard let record = currentDocumentRecord, let memoryStore else {
            longformSidebar.viewModel.setError(localizedError(.noActiveDocument))
            return
        }
        do {
            let session = try memoryStore.createConversationSession(documentID: record.id, title: "新会话")
            activeConversationSessionByDocumentID[record.id] = session.id
            activeConversationSessionID = session.id
            longformSidebar.viewModel.activeSessionID = session.id
            longformSidebar.viewModel.conversation = []
            longformSidebar.viewModel.resetForActiveSession()
            longformSidebar.viewModel.sessions = try memoryStore.listConversationSessions(documentID: record.id)
            longformSidebar.refreshLayout()
            DebugLogger.log("conversation session created id=\(session.id.uuidString)")
        } catch {
            longformSidebar.viewModel.setError(error.localizedDescription)
            model.lastErrorMessage = error.localizedDescription
        }
    }

    private func selectConversationSession(_ sessionID: UUID) {
        guard let record = currentDocumentRecord, let memoryStore else {
            longformSidebar.viewModel.setError(localizedError(.noActiveDocument))
            return
        }
        do {
            let sessions = try memoryStore.listConversationSessions(documentID: record.id)
            guard sessions.contains(where: { $0.id == sessionID }) else {
                throw P4ControllerError.noConversationSession(sessionID)
            }
            activeConversationSessionByDocumentID[record.id] = sessionID
            activeConversationSessionID = sessionID
            longformSidebar.viewModel.activeSessionID = sessionID
            longformSidebar.viewModel.conversation = try memoryStore.conversationTurns(inSession: sessionID, limit: 40)
            longformSidebar.viewModel.resetForActiveSession()
            longformSidebar.viewModel.sessions = sessions
            longformSidebar.refreshLayout()
            DebugLogger.log("conversation session selected id=\(sessionID.uuidString)")
        } catch {
            longformSidebar.viewModel.setError(error.localizedDescription)
            model.lastErrorMessage = error.localizedDescription
        }
    }

    private func deleteConversationSession(_ sessionID: UUID) {
        guard let record = currentDocumentRecord, let memoryStore else {
            longformSidebar.viewModel.setError(localizedError(.noActiveDocument))
            return
        }
        do {
            try memoryStore.deleteConversationSession(id: sessionID)
            if activeConversationSessionByDocumentID[record.id] == sessionID {
                activeConversationSessionByDocumentID[record.id] = nil
            }
            if activeConversationSessionID == sessionID {
                activeConversationSessionID = nil
            }
            refreshConversationSessions(record: record)
            DebugLogger.log("conversation session deleted id=\(sessionID.uuidString)")
        } catch {
            longformSidebar.viewModel.setError(error.localizedDescription)
            model.lastErrorMessage = error.localizedDescription
        }
    }

    private func conciseDocumentSummary(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (trimmed as NSString).length > 240 else { return trimmed }
        return String(trimmed.prefix(240))
    }

    private func memoryContextForActiveDocument(limit: Int = 8) throws -> WritingMemoryContext {
        guard let memoryStore else {
            throw P4ControllerError.memoryUnavailable(memoryStoreInitializationError ?? "unknown SQLite initialization error")
        }
        guard let snapshot = activeSnapshot, let context = activeContext else {
            throw P4ControllerError.noActiveContext
        }
        let record = try memoryStore.upsertDocument(
            identity: currentDocumentIdentity(snapshot: snapshot, context: context),
            summary: conciseDocumentSummary(snapshot.fullText)
        )
        currentDocumentRecord = record
        let session = try ensureActiveConversationSession(
            for: record,
            preferredSessionID: longformSidebar.viewModel.activeSessionID
        )
        activeConversationSessionID = session.id
        longformSidebar.viewModel.activeSessionID = session.id
        longformSidebar.viewModel.sessions = try memoryStore.listConversationSessions(documentID: record.id)
        return try memoryStore.memoryContext(documentID: record.id, sessionID: session.id, limit: limit)
    }

    func openGrammarlessChat() {
        longformSidebar.viewModel.showChat()
        openLongformSidebar()
    }

    func openGrammarlessSettings() {
        longformSidebar.viewModel.showSettings()
        openLongformSidebar()
    }

    func openLongformSidebar() {
        refreshFocusContext(trigger: "openLongformSidebar")
        guard let snapshot = activeSnapshot, let context = activeContext else {
            longformSidebar.viewModel.setError(localizedError(.noActiveContext))
            longformSidebar.present(
                anchoredTo: CGRect(x: 120, y: 120, width: 1, height: 16),
                sendMessage: { _ in },
                applyPatch: { _ in },
                applyAllPatches: {},
                rejectPatch: { _ in },
                runImpactAnalysis: {},
                rollback: {},
                redo: {},
                newSession: {},
                selectSession: { _ in },
                deleteSession: { _ in }
            )
            return
        }
        updateDocumentMemoryState(for: snapshot, context: context)
        if let record = currentDocumentRecord {
            refreshConversationSessions(record: record)
        }
        presentLongformSidebar(anchoredTo: longformAnchorRect(snapshot: snapshot, context: context))
    }

    func runImpactAnalysisFromMenu() {
        openGrammarlessChat()
        Task { @MainActor [weak self] in
            await self?.runImpactAnalysis()
        }
    }

    private func refreshVisibleLongformDocumentState(trigger: String) {
        refreshFocusContext(trigger: trigger)
        guard let snapshot = activeSnapshot, let context = activeContext else {
            if !longformSidebar.isVisible {
                openLongformSidebar()
            }
            return
        }
        updateDocumentMemoryState(for: snapshot, context: context)
        if !longformSidebar.isVisible {
            presentLongformSidebar(anchoredTo: longformAnchorRect(snapshot: snapshot, context: context))
        }
    }

    private func presentLongformSidebar(anchoredTo bounds: CGRect) {
        longformSidebar.present(
            anchoredTo: bounds,
            sendMessage: { [weak self] instruction in
                Task { @MainActor [weak self] in
                    await self?.runAgentChatMessage(instruction)
                }
            },
            applyPatch: { [weak self] patchID in
                Task { @MainActor [weak self] in
                    await self?.applyAgentPatch(id: patchID)
                }
            },
            applyAllPatches: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.applyAllAgentPatches()
                }
            },
            rejectPatch: { [weak self] patchID in
                self?.rejectAgentPatch(id: patchID)
            },
            runImpactAnalysis: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.runImpactAnalysis()
                }
            },
            rollback: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.rollbackLastVersion()
                }
            },
            redo: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.redoLastAgentRun()
                }
            },
            newSession: { [weak self] in
                self?.createNewConversationSession()
            },
            selectSession: { [weak self] sessionID in
                self?.selectConversationSession(sessionID)
            },
            deleteSession: { [weak self] sessionID in
                self?.deleteConversationSession(sessionID)
            }
        )
    }

    private func longformAnchorRect(snapshot: TextSnapshot, context: FocusedTextContext) -> CGRect {
        if snapshot.selectedRange.length > 0,
           let selectedBounds = accessibilityService.bounds(for: snapshot.selectedRange, in: context.element)
        {
            return selectedBounds
        }
        if let caret = caretScreenRect(for: snapshot.selectedRange, in: context) {
            return caret
        }
        return CGRect(x: snapshot.elementBounds.maxX - 1, y: snapshot.elementBounds.maxY - 1, width: 1, height: 1)
    }

    private func runAgentChatMessage(_ instruction: String) async {
        agentTask?.cancel()
        let userInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userInstruction.isEmpty else {
            longformSidebar.viewModel.setError(localized("Enter a writing task for Grammarless.", zh: "请输入要让 Grammarless 完成的写作任务。"))
            return
        }
        guard let snapshot = activeSnapshot else {
            longformSidebar.viewModel.setError(localizedError(.noActiveDocument))
            return
        }
        guard let memoryStore else {
            longformSidebar.viewModel.setError(localizedError(.memoryUnavailable(memoryStoreInitializationError ?? "unknown SQLite initialization error")))
            return
        }
        do {
            let context = try memoryContextForActiveDocument(limit: 8)
            guard let record = currentDocumentRecord else {
                throw P4ControllerError.noActiveDocument
            }
            let session = try ensureActiveConversationSession(
                for: record,
                preferredSessionID: longformSidebar.viewModel.activeSessionID
            )
            activeConversationSessionID = session.id
            longformSidebar.viewModel.activeSessionID = session.id
            lastAgentInstruction = userInstruction
            try memoryStore.appendConversationTurn(
                ConversationTurn(documentID: record.id, role: "user", content: userInstruction),
                toSession: session.id
            )
            if session.title == "新会话" {
                try memoryStore.renameConversationSession(id: session.id, title: sessionTitle(from: userInstruction))
            }
            let contextIncludingUser = try memoryStore.memoryContext(documentID: record.id, sessionID: session.id, limit: 8)
            longformSidebar.viewModel.conversation = contextIncludingUser.recentConversation
            longformSidebar.viewModel.beginLoading()
            longformSidebar.viewModel.clearPending(preservingImpactPatches: true)
            longformSidebar.viewModel.sessions = try memoryStore.listConversationSessions(documentID: record.id)
            longformSidebar.refreshLayout()
            model.llmStatus = .running(localized("Agent chat", zh: "智能对话"))

            let request = AgentToolLoopRequest(
                instruction: userInstruction,
                snapshot: snapshot,
                selectedRange: snapshot.selectedRange,
                memoryContext: contextIncludingUser
            )
            let result = try await reviewEngine.performAgentToolLoop(
                request: request,
                configuration: configurationStore.configuration
            )
            let response = result.response
            pendingAgentResponse = response
            longformSidebar.viewModel.replaceStandalonePendingPatches(response.patches)
            longformSidebar.viewModel.outline = response.outline
            longformSidebar.viewModel.toolEvents = result.events
            let assistantTurnID = UUID()
            let assistantCreatedAt = Date()
            let fallbackAssistantContent = agentConversationContent(response, toolEventCount: result.events.count)
            let assistantContent: String
            do {
                assistantContent = try await reviewEngine.streamAgentFinalMessage(
                    request: AgentFinalMessageRequest(
                        instruction: userInstruction,
                        response: response,
                        toolEvents: result.events,
                        allowsCodeBlocks: allowsAssistantCodeBlocks(for: userInstruction)
                    ),
                    configuration: configurationStore.configuration,
                    onDelta: { [weak self] partial in
                        guard let self else { return }
                        await MainActor.run {
                            guard self.longformSidebar.viewModel.activeSessionID == session.id else { return }
                            self.longformSidebar.viewModel.upsertStreamingAssistantTurn(
                                id: assistantTurnID,
                                documentID: record.id,
                                createdAt: assistantCreatedAt,
                                content: partial
                            )
                            self.longformSidebar.refreshLayout()
                        }
                    }
                )
            } catch {
                DebugLogger.log("agent final markdown stream fallback error=\(error.localizedDescription)")
                assistantContent = fallbackAssistantContent
                if longformSidebar.viewModel.activeSessionID == session.id {
                    longformSidebar.viewModel.upsertStreamingAssistantTurn(
                        id: assistantTurnID,
                        documentID: record.id,
                        createdAt: assistantCreatedAt,
                        content: assistantContent
                    )
                }
            }
            try memoryStore.appendConversationTurn(
                ConversationTurn(
                    id: assistantTurnID,
                    documentID: record.id,
                    createdAt: assistantCreatedAt,
                    role: "assistant",
                    content: assistantContent
                ),
                toSession: session.id
            )
            let toolContextContent = agentToolContextContent(result: result)
            if !toolContextContent.isEmpty {
                try memoryStore.appendConversationTurn(
                    ConversationTurn(documentID: record.id, role: "tool_context", content: toolContextContent),
                    toSession: session.id
                )
            }
            longformSidebar.viewModel.sessions = try memoryStore.listConversationSessions(documentID: record.id)
            if longformSidebar.viewModel.activeSessionID == session.id {
                let updatedContext = try memoryStore.memoryContext(documentID: record.id, sessionID: session.id, limit: 8)
                longformSidebar.viewModel.conversation = updatedContext.recentConversation
            }
            longformSidebar.viewModel.finishLoading()
            longformSidebar.refreshLayout()
            model.llmStatus = .success(localized("Agent response: tools=\(result.events.count) patches=\(response.patches.count)", zh: "对话完成：工具=\(result.events.count)，修改=\(response.patches.count)"))
            model.lastErrorMessage = nil
            DebugLogger.log(
                "agent chat success tools=\(result.events.count) patches=\(response.patches.count) outline=\(response.outline.count)"
            )
        } catch {
            longformSidebar.viewModel.setError(error.localizedDescription)
            longformSidebar.refreshLayout()
            model.llmStatus = .failed(error.localizedDescription)
            model.lastErrorMessage = error.localizedDescription
            DebugLogger.log("agent chat failed error=\(error.localizedDescription)")
        }
    }

    private func agentConversationContent(_ response: AgentResponse, toolEventCount: Int = 0) -> String {
        var parts: [String] = []
        if !response.message.isEmpty { parts.append(response.message) }
        if !response.outline.isEmpty {
            let outlineHeader = localized("**Outline**", zh: "**提纲**")
            let outlineItems = response.outline.enumerated().map { index, item in
                "\(index + 1). \(item)"
            }.joined(separator: "\n")
            parts.append([outlineHeader, outlineItems].joined(separator: "\n"))
        }
        if !response.patches.isEmpty {
            parts.append(localized("- Prepared **\(response.patches.count)** proposed edits.", zh: "- 已准备 **\(response.patches.count)** 处建议修改。"))
        }
        if parts.isEmpty, toolEventCount > 0 {
            parts.append(localized("Tool calls completed: \(toolEventCount)", zh: "已完成工具调用：\(toolEventCount)"))
        }
        return parts.joined(separator: "\n\n")
    }

    private func agentToolContextContent(result: AgentToolLoopResult) -> String {
        guard !result.events.isEmpty || !result.response.patches.isEmpty else { return "" }
        let events = result.events.map { event in
            "\(event.name.rawValue) [\(event.status.rawValue)]: \(event.summary) \(compactForMemory(event.detail, limit: 700))"
        }.joined(separator: "\n")
        let patches = result.response.patches.map { patch in
            "- patchID=\(patch.id.uuidString) range=\(patch.rangeInFullText.location):\(patch.rangeInFullText.length) original=\(patch.originalText) replacement=\(patch.replacementText) reason=\(patch.reason)"
        }.joined(separator: "\n")
        return """
        TOOL_CONTEXT_DO_NOT_SHOW_AS_NORMAL_CHAT
        Use this tool chain as context for follow-up requests, including “继续”, “应用上面的修改”, “刚才的工具调用”, or “根据建议改文档”.
        Tool events:
        \(events.isEmpty ? "none" : events)
        Patches:
        \(patches.isEmpty ? "none" : patches)
        """
    }

    private func compactForMemory(_ text: String, limit: Int) -> String {
        let compact = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard compact.count > limit else { return compact }
        return String(compact.prefix(limit)) + "…"
    }

    private func allowsAssistantCodeBlocks(for instruction: String) -> Bool {
        let normalized = instruction.lowercased()
        let explicitCodeSignals = [
            "```",
            "code block",
            "show code",
            "give code",
            "code example",
            "example code",
            "snippet",
            "完整代码",
            "示例代码",
            "代码示例",
            "代码块",
            "贴代码",
            "给我代码",
            "给出代码",
        ]
        return explicitCodeSignals.contains { normalized.contains($0) }
    }

    private func runImpactAnalysis() async {
        agentTask?.cancel()
        refreshFocusContext(trigger: "runImpactAnalysis")
        guard let snapshot = activeSnapshot else {
            longformSidebar.viewModel.setError(localizedError(.noActiveDocument))
            return
        }
        if let context = activeContext {
            updateDocumentMemoryState(for: snapshot, context: context)
        }

        let memoryContext = (try? memoryContextForActiveDocument(limit: 8)) ?? WritingMemoryContext()
        longformSidebar.viewModel.beginImpactAnalysis(language: uiLanguage)
        longformSidebar.refreshLayout()
        model.llmStatus = .running(localized("Increase Impact", zh: "提升影响力"))
        DebugLogger.log("impact analysis start length=\((snapshot.fullText as NSString).length)")

        do {
            let report = try await reviewEngine.analyzeImpact(
                snapshot: snapshot,
                configuration: configurationStore.configuration,
                memoryContext: memoryContext,
                progressHandler: { [weak self] progress in
                    await MainActor.run {
                        guard let self else { return }
                        self.longformSidebar.viewModel.impactProgress = progress.message
                        self.longformSidebar.refreshLayout()
                    }
                }
            )
            guard activeSnapshot?.revision == snapshot.revision else {
                longformSidebar.viewModel.setError(localized("Document changed. Re-run Increase Impact.", zh: "文档已变化，请重新运行 Impact。"))
                model.llmStatus = .failed(localized("Impact analysis stale", zh: "Impact 分析已过期"))
                return
            }
            let generatedAt = Date()
            longformSidebar.viewModel.impactReport = report
            longformSidebar.viewModel.impactReportGeneratedAt = generatedAt
            longformSidebar.viewModel.impactProgress = ""
            longformSidebar.viewModel.pendingPatches = report.patchCandidates
            persistImpactContext(report, generatedAt: generatedAt)
            longformSidebar.viewModel.finishLoading()
            longformSidebar.refreshLayout()
            model.llmStatus = .success(localized("Impact score \(report.overallScore)", zh: "Impact 分数 \(report.overallScore)"))
            model.lastErrorMessage = nil
            DebugLogger.log("impact analysis success score=\(report.overallScore) segments=\(report.segmentation.segments.count) genre=\(report.primaryGenre.id) failures=\(report.analysisFailures.count) languagePatches=\(report.patchCandidates.count)")
        } catch {
            longformSidebar.viewModel.setError(error.localizedDescription)
            longformSidebar.refreshLayout()
            model.llmStatus = .failed(error.localizedDescription)
            model.lastErrorMessage = error.localizedDescription
            DebugLogger.log("impact analysis failed error=\(error.localizedDescription)")
        }
    }

    private func sessionTitle(from instruction: String) -> String {
        let compact = instruction
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !compact.isEmpty else { return "新会话" }
        guard compact.count > 18 else { return compact }
        return String(compact.prefix(18)) + "…"
    }

    private func persistImpactContext(_ report: DocumentImpactReport, generatedAt: Date) {
        guard let memoryStore, let record = currentDocumentRecord else { return }
        do {
            let session = try ensureActiveConversationSession(
                for: record,
                preferredSessionID: longformSidebar.viewModel.activeSessionID
            )
            activeConversationSessionID = session.id
            longformSidebar.viewModel.activeSessionID = session.id
            let content = impactConversationContent(report)
            try memoryStore.appendConversationTurn(
                ConversationTurn(
                    documentID: record.id,
                    createdAt: generatedAt,
                    role: "impact_context",
                    content: content
                ),
                toSession: session.id
            )
            if session.title == "新会话" {
                try memoryStore.renameConversationSession(id: session.id, title: "Increase Impact")
            }
            longformSidebar.viewModel.sessions = try memoryStore.listConversationSessions(documentID: record.id)
            let context = try memoryStore.memoryContext(documentID: record.id, sessionID: session.id, limit: 10)
            longformSidebar.viewModel.conversation = context.recentConversation
            DebugLogger.log("impact context persisted session=\(session.id.uuidString) chars=\((content as NSString).length)")
        } catch {
            DebugLogger.log("impact context persist failed error=\(error.localizedDescription)")
        }
    }

    private func impactConversationContent(_ report: DocumentImpactReport) -> String {
        let pathChain = [
            "segmentation=\(report.segmentation.segments.count) segments",
            "genreClassification=\(report.primaryGenre.label)",
            "globalLogicEvidence=claims \(report.globalLogicResult.globalClaims.count)",
            "localLogicEvidence=segments \(report.localLogicResults.count)",
            "structureFormat=segments \(report.structureResults.count)",
            "readerReaction=segments \(report.readerReactionResults.count)",
            "languageClarity=segments \(report.languageClarityResults.count)",
            "reducer=score \(report.overallScore)",
            "failures=\(report.analysisFailures.count)",
        ].joined(separator: " -> ")
        let scoreSummary = report.scores.map { score in
            "\(score.dimension.displayName): \(score.score), fix=\(score.topFix.isEmpty ? score.reason : score.topFix)"
        }.joined(separator: "\n")
        let findings = report.topFindings.prefix(8).map { finding in
            "- [\(finding.dimension.displayName)/\(finding.severity.rawValue)] \(finding.title): \(finding.explanation) Recommendation: \(finding.recommendation) Evidence: \(finding.evidence)"
        }.joined(separator: "\n")
        let languagePatches = report.patchCandidates.prefix(12).map { patch in
            "- range=\(patch.rangeInFullText.location):\(patch.rangeInFullText.length) original=\(patch.originalText) replacement=\(patch.replacementText) reason=\(patch.reason)"
        }.joined(separator: "\n")
        let failures = report.analysisFailures.prefix(8).map { failure in
            "- \(impactPathMemoryLabel(failure.path)) \(failure.segmentID ?? "document"): \(failure.message)"
        }.joined(separator: "\n")
        return """
        IMPACT_CONTEXT_DO_NOT_SHOW_AS_NORMAL_CHAT
        The user may refer to this as “上面的建议”, “Impact 分析”, “这些建议”, or “根据建议”. Use this report as actionable context for follow-up chat and edits.

        Impact report:
        genre=\(report.primaryGenre.label) (\(report.primaryGenre.id))
        score=\(report.overallScore)
        diagnosis=\(report.oneSentenceDiagnosis.isEmpty ? report.executiveSummary : report.oneSentenceDiagnosis)
        executiveSummary=\(report.executiveSummary)
        pathChain=\(pathChain)

        Six dimension scores and top fixes:
        \(scoreSummary)

        Top priorities:
        \(findings)

        Quick wins:
        \(report.quickWins.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))

        Deeper revisions:
        \(report.deeperRevisions.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))

        Path summaries:
        structure=\(report.structureSummary)
        logicEvidence=\(report.logicSummary)
        readerReaction=\(report.readerSummary)

        Language replacement candidates:
        \(languagePatches.isEmpty ? "none" : languagePatches)

        Recorded partial failures:
        \(failures.isEmpty ? "none" : failures)
        """
    }

    private func impactPathMemoryLabel(_ path: ImpactAnalysisPath) -> String {
        switch path {
        case .segmentation: return "segmentation"
        case .genreClassification: return "genreClassification"
        case .structureFormat: return "structureFormat"
        case .globalLogicEvidence: return "globalLogicEvidence"
        case .localLogicEvidence: return "localLogicEvidence"
        case .readerReaction: return "readerReaction"
        case .languageClarity: return "languageClarity"
        case .reducer: return "reducer"
        }
    }

    private func applyAgentPatch(id: UUID) async {
        guard let patch = longformSidebar.viewModel.pendingPatches.first(where: { $0.id == id }) else {
            longformSidebar.viewModel.setError(localizedError(.noPendingPatch(id)))
            return
        }
        guard let snapshot = activeSnapshot, let context = activeContext else {
            longformSidebar.viewModel.setError(localizedError(.noActiveContext))
            return
        }
        guard patch.validate(against: snapshot.fullText) else {
            longformSidebar.viewModel.setError(localized("Patch is stale. Re-run the longform action.", zh: "修改已过期，请重新运行长文操作。"))
            return
        }
        let commands = preferredReplacementStrategies(for: context).map {
            ReplaceCommand(
                targetRange: patch.rangeInFullText,
                expectedOriginalText: patch.originalText,
                replacementText: patch.replacementText,
                strategy: $0,
                snapshotRevision: snapshot.revision
            )
        }
        let replaced = await executeReplacement(
            commands: commands,
            snapshot: snapshot,
            context: context,
            staleMessage: localized("Patch is stale.", zh: "修改已过期。"),
            staleTrigger: "staleAgentPatch",
            successTrigger: "postAgentPatch",
            setError: { [weak self] in self?.longformSidebar.viewModel.errorMessage = $0 },
            versionAction: "agentPatch"
        )
        if replaced {
            longformSidebar.viewModel.pendingPatches.removeAll { $0.id == id }
            rolledBackVersionIDs.removeAll()
            if let record = currentDocumentRecord, let memoryStore {
                try? memoryStore.appendConversationTurn(
                    ConversationTurn(documentID: record.id, role: "system", content: "Applied agent patch \(id.uuidString)"),
                    toSession: activeConversationSessionID
                )
                if let context = try? memoryStore.memoryContext(documentID: record.id, sessionID: activeConversationSessionID, limit: 8) {
                    longformSidebar.viewModel.conversation = context.recentConversation
                }
            }
            longformSidebar.refreshLayout()
        }
    }

    private func applyAllAgentPatches() async {
        let patches = longformSidebar.viewModel.pendingPatches
        guard !patches.isEmpty else { return }
        guard let snapshot = activeSnapshot, let context = activeContext else {
            longformSidebar.viewModel.setError(localizedError(.noActiveContext))
            return
        }

        let nsText = snapshot.fullText as NSString
        let sortedPatches = patches.sorted {
            if $0.rangeInFullText.location == $1.rangeInFullText.location {
                return $0.rangeInFullText.length > $1.rangeInFullText.length
            }
            return $0.rangeInFullText.location > $1.rangeInFullText.location
        }
        var occupiedRanges: [NSRange] = []
        var mergedText = snapshot.fullText
        for patch in sortedPatches {
            guard patch.validate(against: snapshot.fullText) else {
                longformSidebar.viewModel.setError(localized("Patch is stale. Re-run the agent chat.", zh: "修改已过期，请重新运行智能对话。"))
                return
            }
            guard !occupiedRanges.contains(where: { NSIntersectionRange($0, patch.rangeInFullText).length > 0 }) else {
                longformSidebar.viewModel.setError(localized("Patch ranges overlap. Apply them one by one.", zh: "修改范围有重叠，请逐条应用。"))
                return
            }
            occupiedRanges.append(patch.rangeInFullText)
            mergedText = (mergedText as NSString).replacingCharacters(in: patch.rangeInFullText, with: patch.replacementText)
        }
        guard mergedText != snapshot.fullText else {
            longformSidebar.viewModel.setError(localized("No effective patch to apply.", zh: "没有可应用的有效修改。"))
            return
        }

        let command = ReplaceCommand(
            targetRange: NSRange(location: 0, length: nsText.length),
            expectedOriginalText: snapshot.fullText,
            replacementText: mergedText,
            strategy: preferredReplacementStrategies(for: context).first ?? .nativePaste,
            snapshotRevision: snapshot.revision
        )
        let commands = preferredReplacementStrategies(for: context).map {
            ReplaceCommand(
                targetRange: command.targetRange,
                expectedOriginalText: command.expectedOriginalText,
                replacementText: command.replacementText,
                strategy: $0,
                snapshotRevision: command.snapshotRevision
            )
        }
        let replaced = await executeReplacement(
            commands: commands,
            snapshot: snapshot,
            context: context,
            staleMessage: localized("Patch set is stale.", zh: "批量修改已过期。"),
            staleTrigger: "staleAgentPatchAll",
            successTrigger: "postAgentPatchAll",
            setError: { [weak self] in self?.longformSidebar.viewModel.errorMessage = $0 },
            versionAction: "agentPatchAll"
        )
        if replaced {
            longformSidebar.viewModel.pendingPatches.removeAll()
            rolledBackVersionIDs.removeAll()
            if let record = currentDocumentRecord, let memoryStore {
                try? memoryStore.appendConversationTurn(
                    ConversationTurn(documentID: record.id, role: "system", content: "Applied all agent patches count=\(patches.count)"),
                    toSession: activeConversationSessionID
                )
                if let context = try? memoryStore.memoryContext(documentID: record.id, sessionID: activeConversationSessionID, limit: 8) {
                    longformSidebar.viewModel.conversation = context.recentConversation
                }
            }
            longformSidebar.refreshLayout()
            DebugLogger.log("agent apply all success patches=\(patches.count)")
        }
    }

    private func rejectAgentPatch(id: UUID) {
        longformSidebar.viewModel.pendingPatches.removeAll { $0.id == id }
        DebugLogger.log("agent patch rejected id=\(id.uuidString)")
    }

    private func redoLastAgentRun() async {
        guard let lastAgentInstruction, !lastAgentInstruction.isEmpty else {
            longformSidebar.viewModel.setError(localized("No previous agent instruction is available to redo.", zh: "没有可重做的上一次智能对话指令。"))
            return
        }
        await runAgentChatMessage(lastAgentInstruction)
    }

    private func rollbackLastVersion() async {
        guard let memoryStore else {
            longformSidebar.viewModel.setError(localizedError(.memoryUnavailable(memoryStoreInitializationError ?? "unknown SQLite initialization error")))
            return
        }
        guard let snapshot = activeSnapshot, let context = activeContext, let record = currentDocumentRecord else {
            longformSidebar.viewModel.setError(localizedError(.noActiveContext))
            return
        }
        do {
            guard let version = try memoryStore.lastVersion(documentID: record.id),
                  !rolledBackVersionIDs.contains(version.id)
            else {
                throw P4ControllerError.noVersion
            }
            let fullRange = NSRange(location: 0, length: (snapshot.fullText as NSString).length)
            let commands = preferredReplacementStrategies(for: context).map {
                ReplaceCommand(
                    targetRange: fullRange,
                    expectedOriginalText: version.afterText,
                    replacementText: version.beforeText,
                    strategy: $0,
                    snapshotRevision: snapshot.revision
                )
            }
            let replaced = await executeReplacement(
                commands: commands,
                snapshot: snapshot,
                context: context,
                staleMessage: localized("Current document no longer matches the last version.", zh: "当前文档已不再匹配上一版本。"),
                staleTrigger: "staleRollback",
                successTrigger: "postRollback",
                setError: { [weak self] in self?.longformSidebar.viewModel.errorMessage = $0 },
                versionAction: nil
            )
            if replaced {
                rolledBackVersionIDs.insert(version.id)
                longformSidebar.viewModel.canRollback = false
                try? memoryStore.appendConversationTurn(
                    ConversationTurn(documentID: record.id, role: "system", content: "Rolled back version \(version.id.uuidString)"),
                    toSession: activeConversationSessionID
                )
                if let context = try? memoryStore.memoryContext(documentID: record.id, sessionID: activeConversationSessionID, limit: 8) {
                    longformSidebar.viewModel.conversation = context.recentConversation
                }
                longformSidebar.refreshLayout()
                DebugLogger.log("rollback success version=\(version.id.uuidString)")
            }
        } catch {
            longformSidebar.viewModel.setError(error.localizedDescription)
            model.lastErrorMessage = error.localizedDescription
            DebugLogger.log("rollback failed error=\(error.localizedDescription)")
        }
    }

    private func recordVersionIfNeeded(action: String, command: ReplaceCommand, beforeSnapshot: TextSnapshot) {
        guard let memoryStore else { return }
        guard let context = activeContext else { return }
        do {
            let record = try memoryStore.upsertDocument(
                identity: currentDocumentIdentity(snapshot: beforeSnapshot, context: context),
                summary: conciseDocumentSummary(beforeSnapshot.fullText)
            )
            currentDocumentRecord = record
            let afterText = (beforeSnapshot.fullText as NSString).replacingCharacters(
                in: command.targetRange,
                with: command.replacementText
            )
            let patch = TextPatch(
                rangeInFullText: command.targetRange,
                originalText: command.expectedOriginalText,
                replacementText: command.replacementText,
                reason: action
            )
            let version = DocumentVersion(
                documentID: record.id,
                action: action,
                beforeText: beforeSnapshot.fullText,
                afterText: afterText,
                patches: [patch]
            )
            try memoryStore.recordVersion(version)
            longformSidebar.viewModel.canRollback = true
            longformSidebar.viewModel.lastVersionSummary = "\(version.createdAt): \(action), patches=1"
            DebugLogger.log("version recorded action=\(action) document=\(record.id)")
        } catch {
            model.lastErrorMessage = error.localizedDescription
            longformSidebar.viewModel.memoryStatus = "Memory error: \(error.localizedDescription)"
            DebugLogger.log("recordVersion failed error=\(error.localizedDescription)")
        }
    }

    private func scheduleGhostSuggestionIfNeeded(for snapshot: TextSnapshot, context: FocusedTextContext, trigger: String) {
        guard configurationStore.configuration.isGhostTextEnabled else {
            clearGhostSuggestion(trigger: "ghostDisabled")
            return
        }
        guard snapshot.selectedRange.length == 0 else {
            clearGhostSuggestion(trigger: "selection")
            return
        }
        guard snapshot.hasCollapsedCaretAtDocumentEnd else {
            clearGhostSuggestion(trigger: "notDocumentEnd")
            model.lastErrorMessage = nil
            longformSidebar.viewModel.errorMessage = nil
            DebugLogger.log(
                "ghost suggestion skipped notDocumentEnd trigger=\(trigger) caret=\(snapshot.selectedRange.location) textLength=\((snapshot.fullText as NSString).length)"
            )
            return
        }
        let fingerprint = ghostFingerprint(for: snapshot)
        guard fingerprint != lastGhostFingerprint else { return }
        lastGhostFingerprint = fingerprint
        ghostTask?.cancel()
        ghostTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled else { return }
            await requestGhostSuggestion(snapshot: snapshot, context: context, trigger: trigger)
        }
    }

    private func ghostFingerprint(for snapshot: TextSnapshot) -> String {
        "\(snapshot.revision.uuidString)|\(snapshot.selectedRange.location)|\(snapshot.fullText)"
    }

    private func requestGhostSuggestionForCurrentCaret(trigger: String) async {
        guard configurationStore.configuration.isGhostTextEnabled else {
            clearGhostSuggestion(trigger: "ghostDisabled")
            longformSidebar.viewModel.setError(localized("Ghost text is disabled.", zh: "Ghost 已关闭。"))
            return
        }
        refreshFocusContext(trigger: "ghostRequest")
        guard let snapshot = activeSnapshot, let context = activeContext else {
            longformSidebar.viewModel.setError(localizedError(.noActiveContext))
            return
        }
        guard snapshot.hasCollapsedCaretAtDocumentEnd else {
            clearGhostSuggestion(trigger: "notDocumentEnd")
            model.lastErrorMessage = nil
            longformSidebar.viewModel.errorMessage = nil
            DebugLogger.log(
                "ghost suggestion request blocked notDocumentEnd trigger=\(trigger) caret=\(snapshot.selectedRange.location) textLength=\((snapshot.fullText as NSString).length)"
            )
            return
        }
        await requestGhostSuggestion(snapshot: snapshot, context: context, trigger: trigger)
    }

    private func requestGhostSuggestion(snapshot: TextSnapshot, context: FocusedTextContext, trigger: String) async {
        guard configurationStore.configuration.isGhostTextEnabled else {
            clearGhostSuggestion(trigger: "ghostDisabled")
            return
        }
        guard snapshot.selectedRange.length == 0 else {
            clearGhostSuggestion(trigger: "ghostNonCollapsed")
            return
        }
        guard snapshot.hasCollapsedCaretAtDocumentEnd else {
            clearGhostSuggestion(trigger: "notDocumentEnd")
            model.lastErrorMessage = nil
            longformSidebar.viewModel.errorMessage = nil
            DebugLogger.log(
                "ghost suggestion skipped notDocumentEnd trigger=\(trigger) caret=\(snapshot.selectedRange.location) textLength=\((snapshot.fullText as NSString).length)"
            )
            return
        }
        do {
            let memoryContext = ghostMemoryContext(from: try memoryContextForActiveDocument(limit: 5))
            let request = GhostSuggestionRequest(
                snapshot: snapshot,
                caretRange: snapshot.selectedRange,
                memoryContext: memoryContext
            )
            let suggestion = try await reviewEngine.requestGhostSuggestion(
                request: request,
                configuration: configurationStore.configuration
            )
            guard activeSnapshot?.revision == snapshot.revision else {
                DebugLogger.log("ghost suggestion dropped stale revision")
                return
            }
            guard suggestion.rangeInFullText == snapshot.selectedRange else {
                DebugLogger.log(
                    "ghost suggestion dropped rangeMismatch suggestion=\(suggestion.rangeInFullText.location):\(suggestion.rangeInFullText.length) snapshot=\(snapshot.selectedRange.location):\(snapshot.selectedRange.length)"
                )
                return
            }
            guard let caretRect = caretScreenRect(for: suggestion.rangeInFullText, in: context) else {
                throw P4ControllerError.noActiveContext
            }
            lastGhostFingerprint = ghostFingerprint(for: snapshot)
            lastGhostSuggestion = suggestion
            ghostKeyboardBridge.state.setVisible(true)
            overlayManager.updateGhostSuggestion(suggestion, screenRect: caretRect, snapshot: snapshot)
            longformSidebar.viewModel.ghostSummary = suggestion.text
            model.llmStatus = .success(localized("Ghost suggestion ready", zh: "Ghost 建议已就绪"))
            model.lastErrorMessage = nil
            DebugLogger.log("ghost suggestion success trigger=\(trigger) length=\((suggestion.text as NSString).length)")
        } catch {
            guard !isCancellation(error) else {
                DebugLogger.log("ghost suggestion cancelled trigger=\(trigger)")
                return
            }
            clearGhostSuggestion(trigger: "ghostError", resetFingerprint: false)
            model.lastErrorMessage = nil
            longformSidebar.viewModel.errorMessage = nil
            DebugLogger.log("ghost suggestion failed trigger=\(trigger) error=\(error.localizedDescription)")
        }
    }

    private func ghostMemoryContext(from context: WritingMemoryContext) -> WritingMemoryContext {
        WritingMemoryContext(
            documentSummary: context.documentSummary,
            recentVersionSummaries: context.recentVersionSummaries,
            recentConversation: [],
            preferences: context.preferences
        )
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func caretScreenRect(for caretRange: NSRange, in context: FocusedTextContext) -> CGRect? {
        let nsText = context.fullText as NSString
        guard caretRange.location >= 0, caretRange.location <= nsText.length else { return nil }
        if caretRange.length == 0,
           let directRect = accessibilityService.bounds(for: caretRange, in: context.element),
           isPlausibleDirectCaretRect(directRect, in: context)
        {
            return CGRect(
                x: directRect.minX,
                y: directRect.minY,
                width: max(directRect.width, 1),
                height: max(directRect.height, 16)
            )
        } else if caretRange.length == 0 {
            DebugLogger.log(
                "ignoring implausible direct caret bounds selection=\(caretRange.location):\(caretRange.length)"
            )
        }
        if caretRange.location > 0,
           let previousRect = accessibilityService.bounds(
               for: NSRange(location: caretRange.location - 1, length: 1),
               in: context.element
           )
        {
            return CGRect(x: previousRect.maxX, y: previousRect.minY, width: 1, height: previousRect.height)
        }
        if caretRange.location < nsText.length,
           let nextRect = accessibilityService.bounds(
               for: NSRange(location: caretRange.location, length: 1),
               in: context.element
           )
        {
            return CGRect(x: nextRect.minX, y: nextRect.minY, width: 1, height: nextRect.height)
        }
        return CGRect(x: context.elementBounds.minX + 8, y: context.elementBounds.minY + 8, width: 1, height: 16)
    }

    private func isPlausibleDirectCaretRect(_ rect: CGRect, in context: FocusedTextContext) -> Bool {
        guard !rect.isNull,
              !rect.isInfinite,
              rect.width >= 0,
              rect.width <= 8,
              rect.height > 0,
              rect.height <= 96
        else {
            return false
        }
        return rect.intersects(context.elementBounds.insetBy(dx: -12, dy: -12))
    }

    @discardableResult
    fileprivate func acceptGhostSuggestion(trigger: String) async -> Bool {
        guard let suggestion = lastGhostSuggestion else {
            model.lastErrorMessage = nil
            longformSidebar.viewModel.errorMessage = nil
            return false
        }
        guard let snapshot = activeSnapshot,
              let context = activeContext,
              snapshot.revision == suggestion.snapshotRevision
        else {
            clearGhostSuggestion(trigger: "ghostStale")
            model.lastErrorMessage = nil
            longformSidebar.viewModel.errorMessage = nil
            return false
        }
        guard snapshot.hasCollapsedCaretAtDocumentEnd,
              suggestion.rangeInFullText == snapshot.selectedRange
        else {
            clearGhostSuggestion(trigger: "notDocumentEnd")
            model.lastErrorMessage = nil
            longformSidebar.viewModel.errorMessage = nil
            DebugLogger.log(
                "ghost suggestion accept blocked notDocumentEnd trigger=\(trigger) caret=\(snapshot.selectedRange.location) suggestion=\(suggestion.rangeInFullText.location):\(suggestion.rangeInFullText.length) textLength=\((snapshot.fullText as NSString).length)"
            )
            return false
        }
        let commands = preferredReplacementStrategies(for: context).map {
            ReplaceCommand(
                targetRange: suggestion.rangeInFullText,
                expectedOriginalText: "",
                replacementText: suggestion.text,
                strategy: $0,
                snapshotRevision: snapshot.revision
            )
        }
        let replaced = await executeReplacement(
            commands: commands,
            snapshot: snapshot,
            context: context,
            staleMessage: localized("Ghost suggestion is stale.", zh: "Ghost 建议已过期。"),
            staleTrigger: "staleGhost",
            successTrigger: "postGhost",
            setError: { [weak self] in self?.model.lastErrorMessage = $0 },
            versionAction: "ghostText"
        )
        if replaced {
            clearGhostSuggestion(trigger: trigger)
        }
        return replaced
    }

    fileprivate func rejectGhostSuggestion(trigger: String) {
        if let snapshot = activeSnapshot {
            lastGhostFingerprint = ghostFingerprint(for: snapshot)
        }
        clearGhostSuggestion(trigger: trigger, resetFingerprint: false)
        DebugLogger.log("ghost suggestion rejected trigger=\(trigger)")
    }

    private func clearGhostSuggestion(trigger: String, resetFingerprint: Bool = true) {
        ghostTask?.cancel()
        if resetFingerprint {
            lastGhostFingerprint = nil
        }
        lastGhostSuggestion = nil
        longformSidebar.viewModel.ghostSummary = ""
        ghostKeyboardBridge.state.setVisible(false)
        overlayManager.clearGhostSuggestion()
        DebugLogger.log("ghost suggestion cleared trigger=\(trigger)")
    }

    func qaRefresh() {
        reanalyzeNow()
    }

    func qaState() -> QAStateSnapshot {
        let documentIdentity = currentDocumentRecord?.identity
        let lastVersion: DocumentVersion? = if let memoryStore, let record = currentDocumentRecord {
            try? memoryStore.lastVersion(documentID: record.id)
        } else {
            nil
        }
        return QAStateSnapshot(
            accessibilityAuthorized: model.accessibilityAuthorized,
            frontmostApp: model.frontmostApp,
            focusedElementRole: model.focusedElementRole,
            activeParagraphDescription: model.activeParagraphDescription,
            selectionText: model.selectionText,
            llmStatus: QALLMStatusSnapshot(model.llmStatus),
            lastErrorMessage: model.lastErrorMessage,
            lastActionPreview: model.lastActionPreview,
            lastActionExplanation: model.lastActionExplanation,
            snapshot: activeSnapshot.map(QASnapshotState.init(snapshot:)),
            documentIdentity: documentIdentity.map(QADocumentIdentityState.init(identity:)),
            memoryStatus: longformSidebar.viewModel.memoryStatus,
            suggestions: (model.activeBatch?.suggestions ?? []).enumerated().map(QASuggestionState.init(index:suggestion:)),
            pendingPatches: longformSidebar.viewModel.pendingPatches.enumerated().map(QATextPatchState.init(index:patch:)),
            ghostSuggestion: lastGhostSuggestion.map(QAGhostSuggestionState.init(suggestion:)),
            lastVersion: lastVersion.map(QADocumentVersionState.init(version:)),
            candidates: accessibilityService
                .editableTextCandidates(preferredBundleIdentifiers: supportedPreferredBundleIdentifiers())
                .prefix(10)
                .map(QAEditableCandidateState.init),
            overlay: QAOverlayState(
                isOverlayVisible: overlayManager.isOverlayVisible,
                isSuggestionCardVisible: overlayManager.isSuggestionCardVisible,
                isAIPanelVisible: overlayManager.isAIPanelVisible,
                frame: overlayManager.lastOverlayFrame.map(QARectState.init),
                suggestionRects: overlayManager.lastRenderedSuggestionRects.enumerated().map(QAOverlaySuggestionState.init(index:renderedSuggestion:)),
                vbarScreenRect: overlayManager.lastVBarScreenRect.map(QARectState.init),
                vbarLocalRect: overlayManager.lastVBarLocalRect.map(QARectState.init),
                fallbackBadgeLocalRect: overlayManager.lastFallbackBadgeRect.map(QARectState.init),
                isGLauncherVisible: overlayManager.isGLauncherVisible,
                gLauncherScreenRect: overlayManager.lastGLauncherTopLeftScreenRect.map(QARectState.init),
                caretScreenRect: overlayManager.lastCaretScreenRect.map(QARectState.init)
            ),
            sidebar: QALongformSidebarState(longformSidebar.stateSnapshot),
            aiActionPreviews: ReviewAction.allCases.compactMap { action in
                overlayManager.aiViewModel.actionPreviews[action].map(QAAIActionPreviewState.init)
            }
        )
    }

    func qaSelectRange(location: Int, length: Int) async throws {
        refreshFocusContext(trigger: "qaSelectBefore")
        guard let context = activeContext else {
            throw QABridgeError.noActiveContext
        }
        let nsText = context.fullText as NSString
        let range = NSRange(location: location, length: length)
        guard location >= 0, length >= 0, NSMaxRange(range) <= nsText.length else {
            throw QABridgeError.invalidRange(length: nsText.length, requested: range)
        }
        if shouldActivateHostBeforeAXCommand(context) {
            let activated = context.application.activate()
            DebugLogger.log("qaSelectRange activateHostApp=\(activated)")
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        _ = accessibilityService.setFocused(context.element)
        guard accessibilityService.setSelectedRange(range, on: context.element) else {
            throw QABridgeError.selectionFailed
        }
        try? await Task.sleep(nanoseconds: 180_000_000)
        refreshFocusContext(trigger: "qaSelectAfter")
    }

    func qaAcceptSuggestion(at index: Int) async throws {
        guard let suggestion = suggestion(at: index) else {
            throw QABridgeError.invalidSuggestionIndex(index)
        }
        refreshFocusContext(trigger: "qaAcceptBefore")
        guard activeContext != nil else {
            throw QABridgeError.noActiveContext
        }
        let replaced = await acceptSuggestion(suggestion)
        guard replaced else {
            throw QABridgeError.replacementFailed(model.lastErrorMessage ?? "Suggestion replace failed.")
        }
        try? await Task.sleep(nanoseconds: 420_000_000)
        refreshFocusContext(trigger: "qaAcceptAfter")
    }

    func qaIgnoreSuggestion(at index: Int) throws {
        guard let suggestion = suggestion(at: index) else {
            throw QABridgeError.invalidSuggestionIndex(index)
        }
        ignoreSuggestion(suggestion)
        refreshFocusContext(trigger: "qaIgnoreAfter")
    }

    func qaRunAIAction(_ action: ReviewAction) async throws {
        refreshFocusContext(trigger: "qaActionBefore")
        guard let snapshot = activeSnapshot,
              let context = activeContext,
              preparePendingAISelection(from: snapshot)
        else {
            throw QABridgeError.noSelection
        }
        if snapshot.selectedRange.length > 0 {
            collapsePendingAISelection(in: context, selectionRange: snapshot.selectedRange, trigger: "qaActionBefore")
        }
        await runAIAction(action)
    }

    func qaOpenAIPanel() async throws {
        refreshFocusContext(trigger: "qaOpenAIPanelBefore")
        guard presentAIPanelForCurrentSelection() else {
            throw QABridgeError.noSelection
        }
        aiPreviewTask?.cancel()
        aiPreviewTask = Task { @MainActor [weak self] in
            await self?.runAIAction(.formal)
        }
        refreshFocusContext(trigger: "qaOpenAIPanelAfter")
    }

    func qaFocusCandidate(at index: Int) async throws {
        guard let context = accessibilityService.editableTextContextCandidate(
            preferredBundleIdentifiers: supportedPreferredBundleIdentifiers(),
            index: index
        ) else {
            throw QABridgeError.invalidCandidateIndex(index)
        }

        let activated = context.application.activate()
        DebugLogger.log("qaFocusCandidate activateHostApp=\(activated) index=\(index)")
        try? await Task.sleep(nanoseconds: 150_000_000)

        var raised = false
        var focusedWindow = false
        var mainWindow = false
        if let window = context.window {
            raised = accessibilityService.raise(window)
            focusedWindow = accessibilityService.setFocusedWindow(window, for: context.application)
            mainWindow = accessibilityService.setMainWindow(window, for: context.application)
            DebugLogger.log(
                "qaFocusCandidate windowActivation raised=\(raised) focusedWindow=\(focusedWindow) mainWindow=\(mainWindow) index=\(index)"
            )
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        let focusApplied = accessibilityService.setFocused(context.element)
        let caretLocation = min(
            max(context.selectedRange.location, 0),
            (context.fullText as NSString).length
        )
        let selectionApplied = accessibilityService.setSelectedRange(
            NSRange(location: caretLocation, length: 0),
            on: context.element
        )
        DebugLogger.log(
            "qaFocusCandidate focusApplied=\(focusApplied) selectionApplied=\(selectionApplied) raised=\(raised) focusedWindow=\(focusedWindow) mainWindow=\(mainWindow) index=\(index)"
        )
        try? await Task.sleep(nanoseconds: 220_000_000)
        refreshFocusContext(trigger: "qaFocusCandidate")
    }

    func qaReplaceAISelection() async throws {
        refreshFocusContext(trigger: "qaReplaceAIBefore")
        if pendingAISelectionRange == nil || pendingAISelectionText == nil {
            guard let snapshot = activeSnapshot, preparePendingAISelection(from: snapshot) else {
                throw QABridgeError.noSelection
            }
        }
        let replaced = await replaceAISelection()
        guard replaced else {
            throw QABridgeError.replacementFailed(model.lastErrorMessage ?? "AI replace failed.")
        }
        try? await Task.sleep(nanoseconds: 420_000_000)
        refreshFocusContext(trigger: "qaReplaceAIAfter")
    }

    func qaOpenLongformSidebar() throws {
        openGrammarlessChat()
        guard longformSidebar.isVisible else {
            throw P4ControllerError.noActiveContext
        }
    }

    func qaOpenGrammarlessSettings() throws {
        openGrammarlessSettings()
        guard longformSidebar.isVisible else {
            throw P4ControllerError.noActiveContext
        }
    }

    func qaSetLanguage(_ rawValue: String) throws {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let language: GrammarlessLanguageMode?
        switch normalized {
        case "zh", "cn", "chinese", "中文":
            language = .zh
        case "en", "english", "英文":
            language = .en
        default:
            language = GrammarlessLanguageMode(rawValue: normalized)
        }
        guard let language else {
            throw P4ControllerError.memoryUnavailable("Invalid language: \(rawValue)")
        }
        configurationStore.update { $0.uiLanguage = language }
        longformSidebar.refreshLayout()
    }

    func qaSetGhostEnabled(_ rawValue: String) throws {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let enabled: Bool
        switch normalized {
        case "1", "true", "yes", "on", "enable", "enabled":
            enabled = true
        case "0", "false", "no", "off", "disable", "disabled":
            enabled = false
        default:
            throw P4ControllerError.memoryUnavailable("Invalid ghost enabled value: \(rawValue)")
        }
        configurationStore.update { $0.isGhostTextEnabled = enabled }
        longformSidebar.refreshLayout()
    }

    func qaRunAgentAction(_ action: AgentAction, instruction: String) async throws {
        refreshVisibleLongformDocumentState(trigger: "qaAgentBefore")
        let message = instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? action.rawValue : instruction
        await runAgentChatMessage(message)
        if let error = longformSidebar.viewModel.errorMessage {
            throw P4ControllerError.memoryUnavailable(error)
        }
    }

    func qaRunImpactAnalysis() async throws {
        refreshVisibleLongformDocumentState(trigger: "qaImpactBefore")
        await runImpactAnalysis()
        if let error = longformSidebar.viewModel.errorMessage {
            throw P4ControllerError.memoryUnavailable(error)
        }
        guard longformSidebar.viewModel.impactReport != nil else {
            throw P4ControllerError.memoryUnavailable("Impact analysis did not produce a report.")
        }
    }

    func qaSendAgentMessage(_ instruction: String) async throws {
        refreshVisibleLongformDocumentState(trigger: "qaAgentMessageBefore")
        await runAgentChatMessage(instruction)
        if let error = longformSidebar.viewModel.errorMessage {
            throw P4ControllerError.memoryUnavailable(error)
        }
    }

    func qaCreateConversationSession() throws {
        refreshVisibleLongformDocumentState(trigger: "qaNewConversationSession")
        createNewConversationSession()
        if let error = longformSidebar.viewModel.errorMessage {
            throw P4ControllerError.memoryUnavailable(error)
        }
    }

    func qaSelectConversationSession(id rawID: String?, index: Int?) throws {
        refreshVisibleLongformDocumentState(trigger: "qaSelectConversationSession")
        let sessionID = try qaConversationSessionID(rawID: rawID, index: index)
        selectConversationSession(sessionID)
        if let error = longformSidebar.viewModel.errorMessage {
            throw P4ControllerError.memoryUnavailable(error)
        }
    }

    func qaDeleteConversationSession(id rawID: String?, index: Int?) throws {
        refreshVisibleLongformDocumentState(trigger: "qaDeleteConversationSession")
        let sessionID = try qaConversationSessionID(rawID: rawID, index: index)
        deleteConversationSession(sessionID)
        if let error = longformSidebar.viewModel.errorMessage {
            throw P4ControllerError.memoryUnavailable(error)
        }
    }

    private func qaConversationSessionID(rawID: String?, index: Int?) throws -> UUID {
        if let rawID, let id = UUID(uuidString: rawID) {
            return id
        }
        let sessions = longformSidebar.viewModel.sessions
        if let index {
            guard index >= 0, index < sessions.count else {
                throw QABridgeError.invalidSuggestionIndex(index)
            }
            return sessions[index].id
        }
        if let rawID {
            throw P4ControllerError.memoryUnavailable("Invalid conversation session id: \(rawID)")
        }
        throw P4ControllerError.memoryUnavailable("Missing conversation session id or index.")
    }

    func qaApplyAgentPatch(at index: Int) async throws {
        let patches = longformSidebar.viewModel.pendingPatches
        guard index >= 0, index < patches.count else {
            throw QABridgeError.invalidSuggestionIndex(index)
        }
        await applyAgentPatch(id: patches[index].id)
        try? await Task.sleep(nanoseconds: 420_000_000)
        refreshFocusContext(trigger: "qaApplyPatchAfter")
        if let error = longformSidebar.viewModel.errorMessage {
            throw QABridgeError.replacementFailed(error)
        }
    }

    func qaRollbackLastVersion() async throws {
        await rollbackLastVersion()
        try? await Task.sleep(nanoseconds: 520_000_000)
        refreshFocusContext(trigger: "qaRollbackAfter")
        if let error = longformSidebar.viewModel.errorMessage {
            throw QABridgeError.replacementFailed(error)
        }
    }

    func qaRequestGhostSuggestion() async throws {
        refreshFocusContext(trigger: "qaGhostBefore")
        await requestGhostSuggestionForCurrentCaret(trigger: "qa")
        guard lastGhostSuggestion != nil else {
            throw QABridgeError.replacementFailed(
                longformSidebar.viewModel.errorMessage ?? model.lastErrorMessage ?? localizedError(.noGhostSuggestion)
            )
        }
    }

    func qaAcceptGhostSuggestion() async throws {
        let replaced = await acceptGhostSuggestion(trigger: "qa")
        guard replaced else {
            throw QABridgeError.replacementFailed(model.lastErrorMessage ?? "Ghost accept failed.")
        }
        try? await Task.sleep(nanoseconds: 420_000_000)
        refreshFocusContext(trigger: "qaGhostAcceptAfter")
    }

    func qaRejectGhostSuggestion() {
        rejectGhostSuggestion(trigger: "qa")
        refreshFocusContext(trigger: "qaGhostRejectAfter")
    }

    func qaTypeText(_ text: String) async throws {
        refreshFocusContext(trigger: "qaTypeBefore")
        guard let context = activeContext else {
            throw QABridgeError.noActiveContext
        }
        if shouldActivateHostBeforeAXCommand(context) {
            let activated = context.application.activate()
            DebugLogger.log("qaTypeText activateHostApp=\(activated) length=\((text as NSString).length)")
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        try replacementExecutor.typeText(text, in: context)
        try? await Task.sleep(nanoseconds: 180_000_000)
        refreshFocusContext(trigger: "qaTypeAfter")
    }

    func qaAXDebug() -> [QAAXApplicationState] {
        accessibilityService
            .debugTree(preferredBundleIdentifiers: supportedPreferredBundleIdentifiers())
            .map(QAAXApplicationState.init)
    }

    private func suggestion(at index: Int) -> Suggestion? {
        let suggestions = model.activeBatch?.suggestions ?? []
        guard index >= 0, index < suggestions.count else { return nil }
        return suggestions[index]
    }
}

struct QAStateSnapshot: Encodable {
    let accessibilityAuthorized: Bool
    let frontmostApp: String
    let focusedElementRole: String
    let activeParagraphDescription: String
    let selectionText: String
    let llmStatus: QALLMStatusSnapshot
    let lastErrorMessage: String?
    let lastActionPreview: String
    let lastActionExplanation: String
    let snapshot: QASnapshotState?
    let documentIdentity: QADocumentIdentityState?
    let memoryStatus: String
    let suggestions: [QASuggestionState]
    let pendingPatches: [QATextPatchState]
    let ghostSuggestion: QAGhostSuggestionState?
    let lastVersion: QADocumentVersionState?
    let candidates: [QAEditableCandidateState]
    let overlay: QAOverlayState
    let sidebar: QALongformSidebarState
    let aiActionPreviews: [QAAIActionPreviewState]
}

struct QADocumentIdentityState: Encodable {
    let kind: String
    let rawValue: String
    let displayName: String

    init(identity: DocumentIdentity) {
        kind = identity.kind.rawValue
        rawValue = identity.rawValue
        displayName = identity.displayName
    }
}

struct QATextPatchState: Encodable {
    let index: Int
    let id: String
    let range: QARangeState
    let originalText: String
    let replacementText: String
    let reason: String

    init(index: Int, patch: TextPatch) {
        self.index = index
        id = patch.id.uuidString
        range = QARangeState(patch.rangeInFullText)
        originalText = patch.originalText
        replacementText = patch.replacementText
        reason = patch.reason
    }
}

struct QAGhostSuggestionState: Encodable {
    let id: String
    let range: QARangeState
    let text: String
    let explanation: String
    let snapshotRevision: String

    init(suggestion: GhostSuggestion) {
        id = suggestion.id.uuidString
        range = QARangeState(suggestion.rangeInFullText)
        text = suggestion.text
        explanation = suggestion.explanation
        snapshotRevision = suggestion.snapshotRevision.uuidString
    }
}

struct QADocumentVersionState: Encodable {
    let id: String
    let documentID: String
    let action: String
    let beforeLength: Int
    let afterLength: Int
    let patchCount: Int

    init(version: DocumentVersion) {
        id = version.id.uuidString
        documentID = version.documentID
        action = version.action
        beforeLength = (version.beforeText as NSString).length
        afterLength = (version.afterText as NSString).length
        patchCount = version.patches.count
    }
}

struct QALongformSidebarState: Encodable {
    let isVisible: Bool
    let surface: String
    let documentName: String
    let memoryStatus: String
    let apiConnectionStatus: String
    let apiConnectionMessage: String
    let availableModelIDs: [String]
    let uiLanguage: String
    let isGhostTextEnabled: Bool
    let isLoading: Bool
    let errorMessage: String?
    let pendingPatchCount: Int
    let conversationCount: Int
    let toolEventCount: Int
    let impactReportScore: Int?
    let impactReportGenre: String?
    let impactSegmentCount: Int?
    let impactAnalysisFailureCount: Int
    let impactProgress: String
    let canRollback: Bool
    let inputText: String
    let sessionCount: Int
    let activeSessionID: String?
    let activeSessionTitle: String
    let isSessionListVisible: Bool
    let sessions: [QAConversationSessionState]

    init(_ state: LongformSidebarState) {
        isVisible = state.isVisible
        surface = state.surface
        documentName = state.documentName
        memoryStatus = state.memoryStatus
        apiConnectionStatus = state.apiConnectionStatus
        apiConnectionMessage = state.apiConnectionMessage
        availableModelIDs = state.availableModelIDs
        uiLanguage = state.uiLanguage
        isGhostTextEnabled = state.isGhostTextEnabled
        isLoading = state.isLoading
        errorMessage = state.errorMessage
        pendingPatchCount = state.pendingPatchCount
        conversationCount = state.conversationCount
        toolEventCount = state.toolEventCount
        impactReportScore = state.impactReportScore
        impactReportGenre = state.impactReportGenre
        impactSegmentCount = state.impactSegmentCount
        impactAnalysisFailureCount = state.impactAnalysisFailureCount
        impactProgress = state.impactProgress
        canRollback = state.canRollback
        inputText = state.inputText
        sessionCount = state.sessionCount
        activeSessionID = state.activeSessionID
        activeSessionTitle = state.activeSessionTitle
        isSessionListVisible = state.isSessionListVisible
        sessions = state.sessions.enumerated().map { QAConversationSessionState(index: $0.offset, session: $0.element) }
    }
}

struct QAConversationSessionState: Encodable {
    let index: Int
    let id: String
    let documentID: String
    let title: String
    let createdAt: String
    let updatedAt: String

    init(index: Int, session: ConversationSession) {
        self.index = index
        id = session.id.uuidString
        documentID = session.documentID
        title = session.title
        createdAt = ISO8601DateFormatter().string(from: session.createdAt)
        updatedAt = ISO8601DateFormatter().string(from: session.updatedAt)
    }
}

struct QAAIActionPreviewState: Encodable {
    let action: String
    let preview: String
    let explanation: String
    let errorMessage: String?
    let isLoading: Bool

    init(_ state: AIActionPreviewState) {
        action = state.action.rawValue
        preview = state.preview
        explanation = state.explanation
        errorMessage = state.errorMessage
        isLoading = state.isLoading
    }
}

struct QAAXApplicationState: Encodable {
    let applicationBundleIdentifier: String
    let localizedName: String
    let focusedWindow: QAAXNodeState?
    let mainWindow: QAAXNodeState?
    let windows: [QAAXNodeState]

    init(_ descriptor: AXDebugApplicationDescriptor) {
        applicationBundleIdentifier = descriptor.applicationBundleIdentifier
        localizedName = descriptor.localizedName
        focusedWindow = descriptor.focusedWindow.map(QAAXNodeState.init)
        mainWindow = descriptor.mainWindow.map(QAAXNodeState.init)
        windows = descriptor.windows.map(QAAXNodeState.init)
    }
}

struct QAAXNodeState: Encodable {
    let role: String
    let title: String
    let frame: QARectState
    let textLength: Int
    let editable: Bool?
    let preview: String
    let children: [QAAXNodeState]

    init(_ descriptor: AXDebugNodeDescriptor) {
        role = descriptor.role
        title = descriptor.title
        frame = QARectState(descriptor.frame)
        textLength = descriptor.textLength
        editable = descriptor.editable
        preview = descriptor.preview
        children = descriptor.children.map(QAAXNodeState.init)
    }
}

struct QALLMStatusSnapshot: Encodable {
    let kind: String
    let message: String?

    init(_ status: LLMStatus) {
        switch status {
        case .idle:
            kind = "idle"
            message = nil
        case let .running(text):
            kind = "running"
            message = text
        case let .success(text):
            kind = "success"
            message = text
        case let .failed(text):
            kind = "failed"
            message = text
        }
    }
}

struct QASnapshotState: Encodable {
    let appBundleId: String
    let elementIdentity: String
    let fullText: String
    let selectedRange: QARangeState
    let analysisText: String
    let analysisRangeInFullText: QARangeState
    let elementBounds: QARectState
    let revision: String
    let languageHint: String

    init(snapshot: TextSnapshot) {
        appBundleId = snapshot.appBundleId
        elementIdentity = snapshot.elementIdentity
        fullText = snapshot.fullText
        selectedRange = QARangeState(snapshot.selectedRange)
        analysisText = snapshot.analysisText
        analysisRangeInFullText = QARangeState(snapshot.analysisRangeInFullText)
        elementBounds = QARectState(snapshot.elementBounds)
        revision = snapshot.revision.uuidString
        languageHint = snapshot.languageHint.rawValue
    }
}

struct QASuggestionState: Encodable {
    let index: Int
    let id: String
    let kind: String
    let source: String
    let rangeInFullText: QARangeState
    let originalText: String
    let replacementText: String
    let explanation: String
    let paragraphIdentity: String
    let proofIssueKind: String?
    let proofIssueSeverity: String?
    let proofIssueConfidence: Double?
    let proofIssueDetectorSource: String?
    let proofIssueAdvancedTip: String?
    let proofIssueAutofixSafe: Bool?

    init(index: Int, suggestion: Suggestion) {
        self.index = index
        id = suggestion.id.uuidString
        kind = suggestion.kind.rawValue
        source = suggestion.source.rawValue
        rangeInFullText = QARangeState(suggestion.rangeInFullText)
        originalText = suggestion.originalText
        replacementText = suggestion.replacementText
        explanation = suggestion.explanation
        paragraphIdentity = suggestion.paragraphIdentity
        proofIssueKind = suggestion.proofIssueKind?.rawValue
        proofIssueSeverity = suggestion.proofIssueSeverity?.rawValue
        proofIssueConfidence = suggestion.proofIssueConfidence
        proofIssueDetectorSource = suggestion.proofIssueDetectorSource
        proofIssueAdvancedTip = suggestion.proofIssueAdvancedTip
        proofIssueAutofixSafe = suggestion.proofIssueAutofixSafe
    }
}

struct QAOverlayState: Encodable {
    let isOverlayVisible: Bool
    let isSuggestionCardVisible: Bool
    let isAIPanelVisible: Bool
    let frame: QARectState?
    let suggestionRects: [QAOverlaySuggestionState]
    let vbarScreenRect: QARectState?
    let vbarLocalRect: QARectState?
    let fallbackBadgeLocalRect: QARectState?
    let isGLauncherVisible: Bool
    let gLauncherScreenRect: QARectState?
    let caretScreenRect: QARectState?
}

struct QAEditableCandidateState: Encodable {
    let applicationBundleIdentifier: String
    let role: String
    let frame: QARectState
    let textLength: Int
    let preview: String

    init(_ descriptor: EditableTextCandidateDescriptor) {
        applicationBundleIdentifier = descriptor.applicationBundleIdentifier
        role = descriptor.role
        frame = QARectState(descriptor.frame)
        textLength = descriptor.textLength
        preview = descriptor.preview
    }
}

struct QAOverlaySuggestionState: Encodable {
    let index: Int
    let kind: String
    let originalText: String
    let replacementText: String
    let screenRect: QARectState
    let localRect: QARectState

    init(index: Int, renderedSuggestion: RenderedSuggestion) {
        self.index = index
        kind = renderedSuggestion.suggestion.kind.rawValue
        originalText = renderedSuggestion.suggestion.originalText
        replacementText = renderedSuggestion.suggestion.replacementText
        screenRect = QARectState(renderedSuggestion.screenRect)
        localRect = QARectState(renderedSuggestion.localRect)
    }
}

struct QARangeState: Encodable {
    let location: Int
    let length: Int

    init(_ range: NSRange) {
        location = range.location
        length = range.length
    }
}

struct QARectState: Encodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }
}

enum QABridgeError: LocalizedError {
    case noActiveContext
    case invalidRange(length: Int, requested: NSRange)
    case selectionFailed
    case invalidSuggestionIndex(Int)
    case invalidCandidateIndex(Int)
    case noSelection
    case replacementFailed(String)

    var errorDescription: String? {
        switch self {
        case .noActiveContext:
            "No active text context."
        case let .invalidRange(length, requested):
            "Invalid range \(requested.location):\(requested.length) for text length \(length)."
        case .selectionFailed:
            "Failed to set AX selected range."
        case let .invalidSuggestionIndex(index):
            "Suggestion index \(index) is out of range."
        case let .invalidCandidateIndex(index):
            "Editable candidate index \(index) is out of range."
        case .noSelection:
            "Select text before running this action."
        case let .replacementFailed(message):
            message
        }
    }
}

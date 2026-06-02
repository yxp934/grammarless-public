import Combine
import Foundation
import GrammarlessCore

final class AppModel: ObservableObject {
    let qaControlsEnabled: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if let explicit = environment["GRAMMARLESS_QA_CONTROLS"] {
            return explicit == "1"
        }
#if DEBUG
        return true
#else
        return false
#endif
    }()

    @Published var accessibilityAuthorized = false
    @Published var frontmostApp = "—"
    @Published var focusedElementRole = "—"
    @Published var activeParagraphDescription = "—"
    @Published var llmStatus: LLMStatus = .idle
    @Published var lastErrorMessage: String?
    @Published var activeSnapshot: TextSnapshot?
    @Published var activeBatch: SuggestionBatch?
    @Published var selectionText = ""
    @Published var lastActionPreview: String = ""
    @Published var lastActionExplanation: String = ""

    var onReanalyze: (() -> Void)?
    var onAcceptSuggestion: ((UUID) -> Void)?
    var onIgnoreSuggestion: ((UUID) -> Void)?
    var onRunAIAction: ((ReviewAction) -> Void)?
    var onReplaceAI: (() -> Void)?
    var onOpenLongformSidebar: (() -> Void)?
}

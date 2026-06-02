import AppKit
import GrammarlessCore
import SwiftUI

struct AIActionPreviewState: Equatable {
    var action: ReviewAction
    var preview: String
    var explanation: String
    var errorMessage: String?
    var isLoading: Bool

    static func idle(action: ReviewAction) -> AIActionPreviewState {
        AIActionPreviewState(
            action: action,
            preview: "",
            explanation: "",
            errorMessage: nil,
            isLoading: false
        )
    }
}

final class AIActionPanelViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var sourceText = ""
    @Published var preview = ""
    @Published var explanation = ""
    @Published var errorMessage: String?
    @Published var selectedAction: ReviewAction = .formal {
        didSet { syncSelectedPreview() }
    }
    @Published private(set) var actionPreviews: [ReviewAction: AIActionPreviewState] = Dictionary(
        uniqueKeysWithValues: ReviewAction.allCases.map { ($0, .idle(action: $0)) }
    )

    var selectedPreviewState: AIActionPreviewState {
        actionPreviews[selectedAction] ?? .idle(action: selectedAction)
    }

    func resetForNewSelection(sourceText: String = "") {
        self.sourceText = sourceText
        selectedAction = .formal
        actionPreviews = Dictionary(uniqueKeysWithValues: ReviewAction.allCases.map { ($0, .idle(action: $0)) })
        isLoading = false
        preview = ""
        explanation = ""
        errorMessage = nil
    }

    func setSourceText(_ sourceText: String) {
        self.sourceText = sourceText
    }

    func select(_ action: ReviewAction) {
        selectedAction = action
    }

    func beginLoading(_ action: ReviewAction, select: Bool = true) {
        if select {
            selectedAction = action
        }
        var state = actionPreviews[action] ?? .idle(action: action)
        state.isLoading = true
        state.errorMessage = nil
        actionPreviews[action] = state
        refreshAggregateState()
    }

    func beginLoadingAll(_ actions: [ReviewAction]) {
        for action in actions {
            var state = actionPreviews[action] ?? .idle(action: action)
            state.isLoading = true
            state.errorMessage = nil
            actionPreviews[action] = state
        }
        refreshAggregateState()
    }

    func setResult(_ result: ReviewActionResult, for action: ReviewAction) {
        actionPreviews[action] = AIActionPreviewState(
            action: action,
            preview: result.replacement,
            explanation: result.explanation,
            errorMessage: nil,
            isLoading: false
        )
        refreshAggregateState()
    }

    func setError(_ message: String, for action: ReviewAction) {
        var state = actionPreviews[action] ?? .idle(action: action)
        state.isLoading = false
        state.errorMessage = message
        actionPreviews[action] = state
        refreshAggregateState()
    }

    func setGlobalError(_ message: String?) {
        errorMessage = message
    }

    private func refreshAggregateState() {
        isLoading = actionPreviews.values.contains { $0.isLoading }
        syncSelectedPreview()
    }

    private func syncSelectedPreview() {
        let state = actionPreviews[selectedAction] ?? .idle(action: selectedAction)
        preview = state.preview
        explanation = state.explanation
        errorMessage = state.errorMessage
    }
}

private enum GrammarlessRewritePalette {
    static let panelBackground = GrammarlessTheme.panel
    static let cardBackground = GrammarlessTheme.card
    static let accent = GrammarlessTheme.aquaInk
    static let accentSoft = GrammarlessTheme.softAqua
    static let goldSoft = GrammarlessTheme.softGold
    static let border = GrammarlessTheme.border
    static let strongBorder = GrammarlessTheme.strongBorder
    static let text = GrammarlessTheme.ink
    static let mutedText = GrammarlessTheme.mutedInk
    static let deletion = GrammarlessTheme.error
    static let insertionBackground = GrammarlessTheme.aqua.opacity(0.35)
}

private struct AIActionPanelView: View {
    private static let panelSize = CGSize(width: 520, height: 330)
    private static let previewHeight: CGFloat = 130

    @ObservedObject var viewModel: AIActionPanelViewModel
    let language: GrammarlessLanguageMode
    let runAction: (ReviewAction) -> Void
    let replace: () -> Void
    let cancel: () -> Void

    private func ui(_ english: String, zh chinese: String) -> String {
        language == .zh ? chinese : english
    }

    var body: some View {
        VStack(spacing: 0) {
            modeTabBar
            contentRegion
            footerBar
        }
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .background(
            RoundedRectangle(cornerRadius: GrammarlessTheme.panelRadius, style: .continuous)
                .fill(GrammarlessRewritePalette.panelBackground)
                .shadow(color: GrammarlessTheme.panelShadow, radius: 24, x: 0, y: 18)
        )
        .overlay(
            RoundedRectangle(cornerRadius: GrammarlessTheme.panelRadius, style: .continuous)
                .stroke(GrammarlessRewritePalette.strongBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GrammarlessTheme.panelRadius, style: .continuous))
    }

    private var modeTabBar: some View {
        HStack(spacing: 24) {
            ForEach(ReviewAction.allCases) { action in
                modeTab(for: action)
            }
            Spacer(minLength: 0)
            closeButton
        }
        .padding(.horizontal, 24)
        .frame(height: 52)
        .background(GrammarlessRewritePalette.panelBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(GrammarlessRewritePalette.border)
                .frame(height: 1)
        }
    }

    private var contentRegion: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [GrammarlessTheme.aquaInk, GrammarlessTheme.aqua],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 4)
                .padding(.top, 3)
                .padding(.bottom, 2)

            mainContent
        }
        .padding(.horizontal, 26)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(viewModel.selectedAction.headlineTitle(language: language))
                .font(GrammarlessTheme.font(size: 16, weight: .semibold))
                .foregroundStyle(GrammarlessRewritePalette.accent)

            previewContent

            if !viewModel.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(viewModel.explanation)
                    .font(GrammarlessTheme.font(size: 11))
                    .foregroundStyle(GrammarlessRewritePalette.mutedText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var closeButton: some View {
        Button(action: cancel) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(GrammarlessRewritePalette.mutedText)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursorPointer()
        .accessibilityLabel(Text(ui("Close", zh: "关闭")))
    }

    private var footerBar: some View {
        HStack(spacing: 10) {
            Button(ui("Accept", zh: "接受"), action: replace)
                .buttonStyle(RewriteActionButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(!canApplySelectedPreview)
                .cursorPointer()
            Button {
                runAction(viewModel.selectedAction)
            } label: {
                Text(ui("Retry", zh: "重试"))
            }
            .buttonStyle(RewriteActionButtonStyle(kind: .secondary))
            .disabled(viewModel.selectedPreviewState.isLoading)
            .cursorPointer()
            Spacer()
            Button(ui("Dismiss", zh: "不接受"), action: cancel)
                .buttonStyle(RewriteActionButtonStyle(kind: .text))
                .cursorPointer()
        }
        .padding(.horizontal, 24)
        .frame(height: 52)
        .background(GrammarlessRewritePalette.panelBackground.opacity(0.98))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(GrammarlessRewritePalette.border)
                .frame(height: 1)
        }
    }

    private var previewContent: some View {
        Group {
            let state = viewModel.selectedPreviewState
            if state.isLoading {
                loadingState(for: state.action)
            } else if let error = state.errorMessage {
                messageState(title: ui("Generation failed", zh: "生成失败"), message: error, isError: true)
            } else if state.preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                loadingState(for: state.action)
            } else {
                UnifiedDiffTextView(
                    segments: RewriteDiff.mergedSegments(original: viewModel.sourceText, revised: state.preview)
                )
                .frame(height: Self.previewHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func modeTab(for action: ReviewAction) -> some View {
        let state = viewModel.actionPreviews[action] ?? .idle(action: action)
        let isSelected = viewModel.selectedAction == action
        return Button {
            viewModel.select(action)
            if state.preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !state.isLoading {
                runAction(action)
            }
        } label: {
            VStack(spacing: 5) {
                HStack(spacing: 6) {
                    Text(action.shortDisplayName(language: language))
                        .font(GrammarlessTheme.font(size: 14, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)

                    if state.isLoading {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                .foregroundStyle(isSelected ? GrammarlessRewritePalette.text : GrammarlessRewritePalette.mutedText)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(isSelected ? GrammarlessRewritePalette.accent : Color.clear)
                    .frame(height: 2.5)
            }
            .padding(.top, 5)
            .frame(minWidth: 60)
            .frame(height: 36)
            .contentShape(RoundedRectangle(cornerRadius: GrammarlessTheme.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(state.isLoading)
        .cursorPointer()
    }

    private func loadingState(for action: ReviewAction) -> some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(ui("Generating: \(action.shortDisplayName(language: language))…", zh: "正在生成：\(action.shortDisplayName(language: language))…"))
                .font(GrammarlessTheme.font(size: 12, weight: .medium))
                .foregroundStyle(GrammarlessRewritePalette.mutedText)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(GrammarlessRewritePalette.border.opacity(0.55))
                    Capsule().fill(GrammarlessRewritePalette.accent).frame(width: max(32, proxy.size.width * 0.58))
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity, minHeight: Self.previewHeight)
        .padding(.horizontal, 16)
        .background(GrammarlessRewritePalette.cardBackground.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func messageState(title: String, message: String, isError: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(GrammarlessTheme.font(size: 13, weight: .semibold))
                .foregroundStyle(isError ? GrammarlessTheme.error.opacity(0.9) : GrammarlessRewritePalette.text)
            Text(message)
                .font(GrammarlessTheme.font(size: 11))
                .foregroundStyle(isError ? GrammarlessTheme.error.opacity(0.8) : GrammarlessRewritePalette.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: Self.previewHeight, alignment: .center)
        .padding(.horizontal, 16)
        .background(GrammarlessRewritePalette.cardBackground.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var canApplySelectedPreview: Bool {
        let state = viewModel.selectedPreviewState
        return !state.isLoading && state.errorMessage == nil && !state.preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct UnifiedDiffTextView: NSViewRepresentable {
    let segments: [RewriteDiffSegment]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.font = NSFont.systemFont(ofSize: 13)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        updateTextView(textView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let textView = context.coordinator.textView ?? nsView.documentView as? NSTextView {
            updateTextView(textView)
        }
    }

    private func updateTextView(_ textView: NSTextView) {
        textView.textStorage?.setAttributedString(attributedString(for: segments))
    }

    private func attributedString(for segments: [RewriteDiffSegment]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let baseFont = NSFont.systemFont(ofSize: 13, weight: .regular)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        paragraphStyle.paragraphSpacing = 5

        for segment in segments where !segment.text.isEmpty {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: baseFont,
                .foregroundColor: GrammarlessTheme.nsInk,
                .paragraphStyle: paragraphStyle,
            ]
            switch segment.operation {
            case .equal:
                break
            case .deletion:
                attributes[.foregroundColor] = GrammarlessTheme.nsError
                attributes[.backgroundColor] = GrammarlessTheme.nsError.withAlphaComponent(0.11)
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case .insertion:
                attributes[.foregroundColor] = GrammarlessTheme.nsAquaInk
                attributes[.backgroundColor] = GrammarlessTheme.nsAqua.withAlphaComponent(0.36)
            }
            result.append(NSAttributedString(string: segment.text, attributes: attributes))
        }
        return result
    }

    final class Coordinator {
        weak var textView: NSTextView?
    }
}

private enum RewriteActionButtonKind {
    case primary
    case secondary
    case text
}

private struct RewriteActionButtonStyle: ButtonStyle {
    let kind: RewriteActionButtonKind

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: GrammarlessTheme.controlRadius, style: .continuous)
        configuration.label
            .font(GrammarlessTheme.font(size: 12, weight: .semibold))
            .padding(.horizontal, kind == .text ? 7 : 13)
            .frame(height: 30)
            .foregroundStyle(foregroundColor)
            .background(backgroundColor(isPressed: configuration.isPressed))
            .clipShape(shape)
            .overlay(shape.stroke(borderColor, lineWidth: kind == .text ? 0 : 1))
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }

    private var foregroundColor: Color {
        switch kind {
        case .primary:
            .white
        case .secondary:
            GrammarlessRewritePalette.text
        case .text:
            GrammarlessRewritePalette.mutedText
        }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        switch kind {
        case .primary:
            return GrammarlessRewritePalette.accent.opacity(isPressed ? 0.84 : 1.0)
        case .secondary:
            return isPressed ? GrammarlessRewritePalette.accentSoft : GrammarlessTheme.input
        case .text:
            return isPressed ? GrammarlessRewritePalette.goldSoft : Color.clear
        }
    }

    private var borderColor: Color {
        switch kind {
        case .primary:
            GrammarlessTheme.aqua.opacity(0.75)
        case .secondary:
            GrammarlessRewritePalette.border
        case .text:
            Color.clear
        }
    }
}

private struct PointingCursorModifier: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering, !isHovering {
                    NSCursor.pointingHand.push()
                    isHovering = true
                } else if !hovering, isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
            .onDisappear {
                if isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
    }
}

private extension View {
    func cursorPointer() -> some View {
        modifier(PointingCursorModifier())
    }
}

final class AIActionPanelWindowController: NSWindowController {
    let viewModel = AIActionPanelViewModel()
    private let panel: NSPanel

    var isVisible: Bool {
        panel.isVisible
    }

    init() {
        panel = InteractionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 330),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Grammarless Rewrite"
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        super.init(window: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(
        at origin: CGPoint,
        originalText: String,
        language: GrammarlessLanguageMode,
        runAction: @escaping (ReviewAction) -> Void,
        replace: @escaping () -> Void,
        cancel: @escaping () -> Void
    ) {
        viewModel.setSourceText(originalText)
        let view = AIActionPanelView(
            viewModel: viewModel,
            language: language,
            runAction: runAction,
            replace: replace,
            cancel: cancel
        )
        panel.title = language == .zh ? "Grammarless 改写" : "Grammarless Rewrite"
        panel.contentView = FirstMouseHostingView(rootView: view)
        let appKitOrigin = convertTopLeftScreenPointToAppKitTopLeftPoint(origin)
        panel.setFrameTopLeftPoint(appKitOrigin)
        DebugLogger.log("ai panel present origin=\(NSStringFromPoint(origin)) appKitOrigin=\(NSStringFromPoint(appKitOrigin))")
        panel.orderFrontRegardless()
    }

    func dismiss() {
        DebugLogger.log("ai panel dismiss")
        panel.orderOut(nil)
        viewModel.resetForNewSelection()
    }

    private func convertTopLeftScreenPointToAppKitTopLeftPoint(_ point: CGPoint) -> CGPoint {
        let screenHeight = NSScreen.main?.frame.maxY ?? 0
        return CGPoint(x: point.x, y: screenHeight - point.y)
    }
}

private extension ReviewAction {
    func shortDisplayName(language: GrammarlessLanguageMode) -> String {
        switch self {
        case .formal:
            return language == .zh ? "正式" : "Formal"
        case .clarity:
            return language == .zh ? "清晰" : "Clear"
        case .shorten:
            return language == .zh ? "缩短" : "Short"
        case .natural:
            return language == .zh ? "自然" : "Natural"
        }
    }

    func headlineTitle(language: GrammarlessLanguageMode) -> String {
        switch self {
        case .formal:
            return language == .zh ? "使用专业表达" : "Use professional language"
        case .clarity:
            return language == .zh ? "让表达更清楚" : "Make it clearer"
        case .shorten:
            return language == .zh ? "压缩为更精炼版本" : "Make it concise"
        case .natural:
            return language == .zh ? "改成更自然的语气" : "Sound more natural"
        }
    }

    var symbolName: String {
        switch self {
        case .formal:
            return "textformat"
        case .clarity:
            return "line.3.horizontal"
        case .shorten:
            return "arrow.down.right.and.arrow.up.left"
        case .natural:
            return "leaf"
        }
    }
}

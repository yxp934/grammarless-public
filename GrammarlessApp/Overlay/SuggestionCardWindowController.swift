import AppKit
import GrammarlessCore
import SwiftUI

private struct SuggestionCardView: View {
    let suggestions: [Suggestion]
    let selectedSuggestionID: UUID
    let language: GrammarlessLanguageMode
    let accept: (Suggestion) -> Void
    let ignore: (Suggestion) -> Void

    @State private var selection: UUID

    init(
        suggestions: [Suggestion],
        selectedSuggestionID: UUID,
        language: GrammarlessLanguageMode,
        accept: @escaping (Suggestion) -> Void,
        ignore: @escaping (Suggestion) -> Void
    ) {
        self.suggestions = suggestions
        self.selectedSuggestionID = selectedSuggestionID
        self.language = language
        self.accept = accept
        self.ignore = ignore
        _selection = State(initialValue: selectedSuggestionID)
    }

    private var selectedSuggestion: Suggestion? {
        suggestions.first(where: { $0.id == selection }) ?? suggestions.first
    }

    private func ui(_ english: String, zh chinese: String) -> String {
        language == .zh ? chinese : english
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            suggestionList
            footer
        }
        .frame(width: 360, height: 292)
        .background(
            RoundedRectangle(cornerRadius: GrammarlessTheme.panelRadius, style: .continuous)
                .fill(GrammarlessTheme.panel)
                .shadow(color: GrammarlessTheme.panelShadow, radius: 18, x: 0, y: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: GrammarlessTheme.panelRadius, style: .continuous)
                .stroke(GrammarlessTheme.strongBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GrammarlessTheme.panelRadius, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(ui("Suggestions", zh: "建议"))
                .font(GrammarlessTheme.font(size: 16, weight: .semibold))
                .foregroundStyle(GrammarlessTheme.ink)
            Spacer()
            Text("\(suggestions.count)")
                .font(GrammarlessTheme.font(size: 11, weight: .semibold))
                .foregroundStyle(GrammarlessTheme.aquaInk)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(GrammarlessTheme.softAqua)
                .clipShape(RoundedRectangle(cornerRadius: GrammarlessTheme.smallRadius, style: .continuous))
        }
        .padding(.horizontal, 18)
        .frame(height: 50)
        .overlay(alignment: .bottom) {
            Rectangle().fill(GrammarlessTheme.border).frame(height: 1)
        }
    }

    private var suggestionList: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 8) {
                ForEach(suggestions) { suggestion in
                    suggestionRow(suggestion)
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let selectedSuggestion {
                Button(ui("Ignore", zh: "忽略")) { ignore(selectedSuggestion) }
                    .buttonStyle(.grammarlessText)
                Spacer()
                Button(ui("Accept", zh: "接受")) { accept(selectedSuggestion) }
                    .buttonStyle(.grammarlessProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
        .overlay(alignment: .top) {
            Rectangle().fill(GrammarlessTheme.border).frame(height: 1)
        }
    }

    private func suggestionRow(_ suggestion: Suggestion) -> some View {
        let isSelected = suggestion.id == selection
        return Button {
            selection = suggestion.id
        } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color(for: suggestion.kind))
                    .frame(width: 4)
                    .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(kindLabel(for: suggestion.kind))
                            .font(GrammarlessTheme.font(size: 11, weight: .semibold))
                            .foregroundStyle(color(for: suggestion.kind))
                        Spacer()
                    }
                    Text("\(suggestion.originalText) → \(suggestion.replacementText)")
                        .font(GrammarlessTheme.font(size: 13, weight: .semibold))
                        .foregroundStyle(GrammarlessTheme.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if isSelected, !suggestion.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(suggestion.explanation)
                            .font(GrammarlessTheme.font(size: 11.5))
                            .foregroundStyle(GrammarlessTheme.mutedInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? GrammarlessTheme.softAqua : GrammarlessTheme.input)
            .overlay(
                RoundedRectangle(cornerRadius: GrammarlessTheme.cardRadius, style: .continuous)
                    .stroke(isSelected ? GrammarlessTheme.strongBorder : GrammarlessTheme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: GrammarlessTheme.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func color(for kind: SuggestionKind) -> Color {
        switch kind {
        case .spelling:
            return GrammarlessTheme.error
        case .grammar:
            return GrammarlessTheme.goldInk
        case .rewrite:
            return GrammarlessTheme.aquaInk
        }
    }

    private func kindLabel(for kind: SuggestionKind) -> String {
        switch kind {
        case .spelling:
            return ui("Spelling", zh: "拼写")
        case .grammar:
            return ui("Grammar", zh: "语法")
        case .rewrite:
            return ui("Rewrite", zh: "改写")
        }
    }
}

final class SuggestionCardWindowController: NSWindowController {
    private let panel: NSPanel

    var isVisible: Bool {
        panel.isVisible
    }

    init() {
        panel = InteractionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 292),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Grammarless Suggestions"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(
        at origin: CGPoint,
        suggestions: [Suggestion],
        selectedSuggestionID: UUID,
        language: GrammarlessLanguageMode,
        accept: @escaping (Suggestion) -> Void,
        ignore: @escaping (Suggestion) -> Void
    ) {
        let view = SuggestionCardView(
            suggestions: suggestions,
            selectedSuggestionID: selectedSuggestionID,
            language: language,
            accept: accept,
            ignore: ignore
        )
        panel.title = language == .zh ? "Grammarless 建议" : "Grammarless Suggestions"
        panel.contentView = FirstMouseHostingView(rootView: view)
        let appKitOrigin = convertTopLeftScreenPointToAppKitTopLeftPoint(origin)
        panel.setFrameTopLeftPoint(appKitOrigin)
        DebugLogger.log(
            "suggestion card present origin=\(NSStringFromPoint(origin)) appKitOrigin=\(NSStringFromPoint(appKitOrigin)) selected=\(selectedSuggestionID.uuidString)"
        )
        panel.orderFrontRegardless()
    }

    func dismiss() {
        DebugLogger.log("suggestion card dismiss")
        panel.orderOut(nil)
    }

    private func convertTopLeftScreenPointToAppKitTopLeftPoint(_ point: CGPoint) -> CGPoint {
        let screenHeight = NSScreen.main?.frame.maxY ?? 0
        return CGPoint(x: point.x, y: screenHeight - point.y)
    }
}

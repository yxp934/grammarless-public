import AppKit
import GrammarlessCore
import SwiftUI

private struct SuggestionHoverView: View {
    let suggestion: Suggestion
    let language: GrammarlessLanguageMode
    let accept: () -> Void
    let ignore: () -> Void

    private func ui(_ english: String, zh chinese: String) -> String {
        language == .zh ? chinese : english
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color(for: suggestion.kind))
                    .frame(width: 5, height: 22)
                Text(kindLabel(for: suggestion.kind))
                    .font(GrammarlessTheme.font(size: 12, weight: .semibold))
                    .foregroundStyle(color(for: suggestion.kind))
                Spacer()
            }

            Text("\(suggestion.originalText) → \(suggestion.replacementText)")
                .font(GrammarlessTheme.font(size: 14, weight: .semibold))
                .foregroundStyle(GrammarlessTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            if !suggestion.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(suggestion.explanation)
                    .font(GrammarlessTheme.font(size: 12))
                    .foregroundStyle(GrammarlessTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button(ui("Ignore", zh: "忽略"), action: ignore)
                    .buttonStyle(.grammarlessText)
                Spacer()
                Button(ui("Accept", zh: "接受"), action: accept)
                    .buttonStyle(.grammarlessProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: GrammarlessTheme.cardRadius, style: .continuous)
                .fill(GrammarlessTheme.panel)
                .shadow(color: GrammarlessTheme.panelShadow, radius: 16, x: 0, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: GrammarlessTheme.cardRadius, style: .continuous)
                .stroke(GrammarlessTheme.strongBorder, lineWidth: 1)
        )
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

final class HoverSuggestionWindowController: NSWindowController {
    private let panel: NSPanel
    private var presentedSuggestionIdentity: String?
    private var presentedTopLeft: CGPoint?

    var isVisible: Bool {
        panel.isVisible
    }

    init() {
        panel = InteractionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
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

    var screenFrame: CGRect {
        panel.frame
    }

    var topLeftScreenFrame: CGRect {
        let screenHeight = NSScreen.main?.frame.maxY ?? 0
        return CGRect(
            x: panel.frame.minX,
            y: screenHeight - panel.frame.maxY,
            width: panel.frame.width,
            height: panel.frame.height
        )
    }

    func present(
        at origin: CGPoint,
        suggestion: Suggestion,
        language: GrammarlessLanguageMode,
        accept: @escaping () -> Void,
        ignore: @escaping () -> Void
    ) {
        let appKitOrigin = convertTopLeftScreenPointToAppKitTopLeftPoint(origin)
        if suggestion.stableIdentity == presentedSuggestionIdentity,
           let presentedTopLeft,
           abs(presentedTopLeft.x - origin.x) <= 0.5,
           abs(presentedTopLeft.y - origin.y) <= 0.5,
           panel.isVisible
        {
            return
        }

        let view = SuggestionHoverView(
            suggestion: suggestion,
            language: language,
            accept: accept,
            ignore: ignore
        )
        panel.contentView = FirstMouseHostingView(rootView: view)
        panel.setFrameTopLeftPoint(appKitOrigin)
        presentedSuggestionIdentity = suggestion.stableIdentity
        presentedTopLeft = origin
        DebugLogger.log(
            "suggestion hover present origin=\(NSStringFromPoint(origin)) appKitOrigin=\(NSStringFromPoint(appKitOrigin)) target=\(suggestion.stableIdentity)"
        )
        panel.orderFrontRegardless()
    }

    func dismiss() {
        guard panel.isVisible else { return }
        DebugLogger.log("suggestion hover dismiss")
        panel.orderOut(nil)
        presentedSuggestionIdentity = nil
        presentedTopLeft = nil
    }

    private func convertTopLeftScreenPointToAppKitTopLeftPoint(_ point: CGPoint) -> CGPoint {
        let screenHeight = NSScreen.main?.frame.maxY ?? 0
        return CGPoint(x: point.x, y: screenHeight - point.y)
    }
}

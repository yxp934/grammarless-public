import AppKit
import GrammarlessCore
import SwiftUI

private struct GLauncherView: View {
    let language: GrammarlessLanguageMode
    let activate: () -> Void

    private func ui(_ english: String, zh chinese: String) -> String {
        language == .zh ? chinese : english
    }

    var body: some View {
        Button(action: activate) {
            Text("G")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(GrammarlessTheme.ink)
                .frame(width: 30, height: 30)
                .background(
                    LinearGradient(
                        colors: [GrammarlessTheme.aqua, GrammarlessTheme.gold],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(Circle())
                .overlay(Circle().stroke(GrammarlessTheme.strongBorder, lineWidth: 1))
                .shadow(color: GrammarlessTheme.aqua.opacity(0.32), radius: 8, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .help(ui("Open Grammarless chat", zh: "打开 Grammarless 对话"))
    }
}

final class GLauncherWindowController: NSWindowController {
    private let panel: NSPanel
    private var lastTopLeft: CGPoint?

    var isVisible: Bool { panel.isVisible }
    var screenFrame: CGRect { panel.frame }

    init() {
        panel = InteractionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 34, height: 34),
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

    func present(atTopLeft origin: CGPoint, language: GrammarlessLanguageMode, activate: @escaping () -> Void) {
        let appKitOrigin = convertTopLeftScreenPointToAppKitTopLeftPoint(origin)
        if let lastTopLeft,
           abs(lastTopLeft.x - origin.x) <= 0.5,
           abs(lastTopLeft.y - origin.y) <= 0.5,
           panel.isVisible {
            return
        }
        panel.contentView = FirstMouseHostingView(rootView: GLauncherView(language: language, activate: activate))
        panel.setFrameTopLeftPoint(appKitOrigin)
        lastTopLeft = origin
        panel.orderFrontRegardless()
    }

    func dismiss() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        lastTopLeft = nil
    }

    private func convertTopLeftScreenPointToAppKitTopLeftPoint(_ point: CGPoint) -> CGPoint {
        let screenHeight = NSScreen.main?.frame.maxY ?? 0
        return CGPoint(x: point.x, y: screenHeight - point.y)
    }
}

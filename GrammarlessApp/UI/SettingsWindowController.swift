import AppKit
import GrammarlessCore
import SwiftUI

final class SettingsWindowController: NSWindowController {
    init(store: ConfigurationStore) {
        let hosting = NSHostingController(rootView: SettingsView(store: store))
        let window = NSWindow(contentViewController: hosting)
        window.title = store.configuration.uiLanguage == .zh ? "Grammarless 设置" : "Grammarless Settings"
        window.setContentSize(NSSize(width: 480, height: 420))
        window.styleMask = [.titled, .closable, .miniaturizable]
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

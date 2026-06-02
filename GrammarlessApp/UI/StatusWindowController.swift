import AppKit
import SwiftUI

final class StatusWindowController: NSWindowController {
    init(model: AppModel) {
        let hosting = NSHostingController(rootView: StatusView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Grammarless 状态"
        window.setContentSize(NSSize(width: 460, height: 640))
        window.styleMask = [.titled, .closable, .miniaturizable]
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

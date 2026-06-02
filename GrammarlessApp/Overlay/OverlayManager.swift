import AppKit
import GrammarlessCore
import SwiftUI

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool {
        false
    }

    override var mouseDownCanMoveWindow: Bool {
        true
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }
}

final class InteractionPanel: NSPanel {
    /// Keep the panel non-activating, but allow it to become key long enough to
    /// receive real mouse clicks while the user is still working inside TextEdit.
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            makeKey()
        }
        if event.type == .keyDown, performStandardEditCommand(from: event) {
            return
        }
        if event.type == .leftMouseDown || event.type == .leftMouseUp {
            DebugLogger.log(
                "interaction panel sendEvent type=\(event.type.rawValue) " +
                    "location=\(NSStringFromPoint(event.locationInWindow)) key=\(self.isKeyWindow)"
            )
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if performStandardEditCommand(from: event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func performStandardEditCommand(from event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              !flags.contains(.control),
              !flags.contains(.option),
              let key = event.charactersIgnoringModifiers?.lowercased()
        else {
            return false
        }

        let selector: Selector?
        switch key {
        case "a":
            selector = #selector(NSText.selectAll(_:))
        case "c":
            selector = #selector(NSText.copy(_:))
        case "v":
            selector = #selector(NSText.paste(_:))
        case "x":
            selector = #selector(NSText.cut(_:))
        default:
            selector = nil
        }

        guard let selector else { return false }
        if firstResponder?.tryToPerform(selector, with: nil) == true {
            return true
        }
        return NSApp.sendAction(selector, to: nil, from: nil)
    }
}

final class OverlayManager {
    var onFallbackActivated: (() -> Void)?
    var onVBarActivated: (() -> Void)?
    var onSuggestionAccepted: ((Suggestion) -> Void)?
    var onSuggestionIgnored: ((Suggestion) -> Void)?
    var onAIActionRequested: ((ReviewAction) -> Void)?
    var onAIReplace: (() -> Void)?
    var onAICancel: (() -> Void)?
    var onGLauncherActivated: (() -> Void)?

    private let overlayWindow: NSPanel
    private let overlayView = OverlayView(frame: .zero)
    private let hoverWindowController = HoverSuggestionWindowController()
    private let aiPanelWindowController = AIActionPanelWindowController()
    private let gLauncherWindowController = GLauncherWindowController()
    private var language: GrammarlessLanguageMode = .zh
    private var globalMouseDownMonitor: Any?
    private var globalMouseMoveMonitor: Any?
    private var hoverTrackingTimer: Timer?
    private var hoverDismissWorkItem: DispatchWorkItem?
    private var hoveredSuggestionIdentity: String?

    private var activeSuggestions: [Suggestion] = []
    private(set) var lastOverlayFrame: CGRect?
    private(set) var lastRenderedSuggestionRects: [RenderedSuggestion] = []
    private(set) var lastVBarScreenRect: CGRect?
    private(set) var lastVBarLocalRect: CGRect?
    private(set) var lastAnalysisGuideScreenRect: CGRect?
    private(set) var lastAnalysisGuideLocalRect: CGRect?
    private(set) var lastFallbackBadgeRect: CGRect?
    private(set) var lastGhostSuggestion: GhostSuggestion?
    private(set) var lastGhostScreenRect: CGRect?
    private(set) var lastGhostLocalRect: CGRect?
    private(set) var lastGLauncherTopLeftScreenRect: CGRect?
    private(set) var lastCaretScreenRect: CGRect?

    var isPresentingInteractionSurface: Bool {
        overlayWindow.isVisible || hoverWindowController.isVisible || aiPanelWindowController.isVisible || gLauncherWindowController.isVisible
    }

    var isOverlayVisible: Bool {
        overlayWindow.isVisible
    }

    var isSuggestionHoverVisible: Bool {
        hoverWindowController.isVisible
    }

    var isSuggestionCardVisible: Bool {
        hoverWindowController.isVisible
    }

    var isAIPanelVisible: Bool {
        aiPanelWindowController.isVisible
    }

    var isGLauncherVisible: Bool {
        gLauncherWindowController.isVisible
    }

    func setLanguage(_ language: GrammarlessLanguageMode) {
        self.language = language
    }

    init() {
        overlayWindow = InteractionPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        overlayWindow.isOpaque = false
        overlayWindow.backgroundColor = .clear
        overlayWindow.becomesKeyOnlyIfNeeded = true
        // The underline/ghost overlay is purely visual. If the transparent
        // window participates in hit testing, macOS consumes clicks across the
        // whole editor rect even when OverlayView.hitTest returns nil, which
        // blocks TextEdit/Word selection and makes floating suggestion panels
        // feel stuck behind the overlay. Global monitors still drive hover and
        // small affordance clicks, so the visual layer must always pass through.
        overlayWindow.ignoresMouseEvents = true
        overlayWindow.acceptsMouseMovedEvents = true
        overlayWindow.hasShadow = false
        overlayWindow.level = .statusBar
        overlayWindow.hidesOnDeactivate = false
        overlayWindow.isFloatingPanel = true
        overlayWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        overlayWindow.contentView = overlayView

        overlayView.onFallbackClick = { [weak self] in
            DebugLogger.log("overlay fallback click")
            self?.onFallbackActivated?()
        }
        overlayView.onVBarClick = { [weak self] in
            DebugLogger.log("overlay vbar click")
            self?.onVBarActivated?()
        }
        installGlobalEventMonitors()
        startHoverTrackingTimer()
    }

    deinit {
        if let globalMouseDownMonitor {
            NSEvent.removeMonitor(globalMouseDownMonitor)
        }
        if let globalMouseMoveMonitor {
            NSEvent.removeMonitor(globalMouseMoveMonitor)
        }
        hoverTrackingTimer?.invalidate()
    }

    var aiViewModel: AIActionPanelViewModel {
        aiPanelWindowController.viewModel
    }

    func updateOverlay(
        snapshot: TextSnapshot,
        suggestions: [Suggestion],
        suggestionRects: [RenderedSuggestion],
        vbarScreenRect: CGRect?,
        caretScreenRect: CGRect?,
        analysisGuideScreenRect: CGRect?,
        showFallbackBadge: Bool
    ) {
        activeSuggestions = suggestions
        lastCaretScreenRect = caretScreenRect
        let frame = snapshot.elementBounds.insetBy(dx: -20, dy: -20)
        guard frame.width > 0, frame.height > 0 else {
            clear()
            return
        }

        lastOverlayFrame = frame

        let appKitFrame = convertTopLeftScreenRectToAppKitFrame(frame)
        if !rectsApproximatelyEqual(overlayWindow.frame, appKitFrame) {
            overlayWindow.setFrame(appKitFrame, display: false)
        }
        let overlayViewFrame = NSRect(origin: .zero, size: frame.size)
        if !rectsApproximatelyEqual(overlayView.frame, overlayViewFrame) {
            overlayView.frame = overlayViewFrame
        }

        let normalizedSuggestionRects = suggestionRects.map { item in
            RenderedSuggestion(
                suggestion: item.suggestion,
                screenRect: item.screenRect,
                localRect: normalizeLocalRect(item.localRect, frameHeight: frame.height)
            )
        }
        if !visuallyMatchesSuggestions(normalizedSuggestionRects, lastRenderedSuggestionRects) {
            overlayView.suggestionRects = normalizedSuggestionRects
        }
        lastRenderedSuggestionRects = normalizedSuggestionRects

        if let vbarScreenRect {
            let localRect = convertToLocal(vbarScreenRect, frame: frame)
            if !rectsApproximatelyEqual(overlayView.vbarRect, localRect) {
                overlayView.vbarRect = localRect
            }
            lastVBarScreenRect = vbarScreenRect
            lastVBarLocalRect = localRect
        } else {
            if overlayView.vbarRect != nil {
                overlayView.vbarRect = nil
            }
            lastVBarScreenRect = nil
            lastVBarLocalRect = nil
        }

        if let analysisGuideScreenRect {
            let localRect = convertToLocal(analysisGuideScreenRect, frame: frame)
            if !rectsApproximatelyEqual(overlayView.analysisGuideRect, localRect) {
                overlayView.analysisGuideRect = localRect
            }
            lastAnalysisGuideScreenRect = analysisGuideScreenRect
            lastAnalysisGuideLocalRect = localRect
        } else {
            if overlayView.analysisGuideRect != nil {
                overlayView.analysisGuideRect = nil
            }
            lastAnalysisGuideScreenRect = nil
            lastAnalysisGuideLocalRect = nil
        }

        if showFallbackBadge {
            let badgeRect = CGRect(x: frame.width - 24, y: frame.height - 24, width: 18, height: 18)
            if !rectsApproximatelyEqual(overlayView.fallbackBadgeRect, badgeRect) {
                overlayView.fallbackBadgeRect = badgeRect
            }
            lastFallbackBadgeRect = badgeRect
        } else {
            if overlayView.fallbackBadgeRect != nil {
                overlayView.fallbackBadgeRect = nil
            }
            lastFallbackBadgeRect = nil
        }

        if let ghostScreenRect = lastGhostScreenRect, lastGhostSuggestion != nil {
            let localRect = convertToLocal(ghostScreenRect, frame: frame)
            if !rectsApproximatelyEqual(overlayView.ghostRect, localRect) {
                overlayView.ghostRect = localRect
            }
            lastGhostLocalRect = localRect
        }
        if !overlayWindow.isVisible {
            overlayWindow.orderFrontRegardless()
        }
        updateGLauncher(for: snapshot, overlayFrame: frame, caretScreenRect: caretScreenRect)
        syncVisibleHoverSuggestionIfNeeded()
    }

    func updateGhostSuggestion(_ suggestion: GhostSuggestion, screenRect: CGRect, snapshot: TextSnapshot) {
        let frame = snapshot.elementBounds.insetBy(dx: -20, dy: -20)
        guard frame.width > 0, frame.height > 0 else {
            clearGhostSuggestion()
            return
        }
        lastOverlayFrame = frame
        let appKitFrame = convertTopLeftScreenRectToAppKitFrame(frame)
        if !rectsApproximatelyEqual(overlayWindow.frame, appKitFrame) {
            overlayWindow.setFrame(appKitFrame, display: false)
        }
        let overlayViewFrame = NSRect(origin: .zero, size: frame.size)
        if !rectsApproximatelyEqual(overlayView.frame, overlayViewFrame) {
            overlayView.frame = overlayViewFrame
        }
        let localRect = convertToLocal(screenRect, frame: frame)
        lastGhostSuggestion = suggestion
        lastGhostScreenRect = screenRect
        lastGhostLocalRect = localRect
        overlayView.ghostText = suggestion.text
        overlayView.ghostRect = localRect
        if !overlayWindow.isVisible {
            overlayWindow.orderFrontRegardless()
        }
        DebugLogger.log("overlay ghost updated textLength=\((suggestion.text as NSString).length) screenRect=\(NSStringFromRect(screenRect))")
    }

    func clearGhostSuggestion() {
        lastGhostSuggestion = nil
        lastGhostScreenRect = nil
        lastGhostLocalRect = nil
        overlayView.ghostText = ""
        overlayView.ghostRect = nil
    }

    func showSuggestionHover(for suggestion: Suggestion, anchor: CGPoint? = nil) {
        cancelScheduledHoverDismiss()
        hoveredSuggestionIdentity = suggestion.stableIdentity
        let resolvedAnchor = anchor ?? suggestionHoverAnchor(for: suggestion) ?? fallbackSuggestionHoverAnchor()
        hoverWindowController.present(
            at: resolvedAnchor,
            suggestion: suggestion,
            language: language,
            accept: { [weak self] in
                self?.dismissSuggestionHover()
                self?.onSuggestionAccepted?(suggestion)
            },
            ignore: { [weak self] in
                self?.dismissSuggestionHover()
                self?.onSuggestionIgnored?(suggestion)
            }
        )
    }

    func showAIPanel(at anchor: CGPoint, originalText: String) {
        cancelScheduledHoverDismiss()
        dismissSuggestionHover()
        DebugLogger.log("overlay showAIPanel")
        aiPanelWindowController.present(
            at: anchor,
            originalText: originalText,
            language: language,
            runAction: { [weak self] action in
                self?.onAIActionRequested?(action)
            },
            replace: { [weak self] in
                self?.onAIReplace?()
            },
            cancel: { [weak self] in
                self?.onAICancel?()
            }
        )
    }

    func dismissPanels() {
        dismissSuggestionHover()
        aiPanelWindowController.dismiss()
    }

    func clear() {
        cancelScheduledHoverDismiss()
        overlayView.suggestionRects = []
        overlayView.vbarRect = nil
        overlayView.analysisGuideRect = nil
        overlayView.fallbackBadgeRect = nil
        overlayView.ghostText = ""
        overlayView.ghostRect = nil
        lastOverlayFrame = nil
        lastRenderedSuggestionRects = []
        lastVBarScreenRect = nil
        lastVBarLocalRect = nil
        lastAnalysisGuideScreenRect = nil
        lastAnalysisGuideLocalRect = nil
        lastFallbackBadgeRect = nil
        lastGhostSuggestion = nil
        lastGhostScreenRect = nil
        lastGhostLocalRect = nil
        lastGLauncherTopLeftScreenRect = nil
        lastCaretScreenRect = nil
        hoveredSuggestionIdentity = nil
        overlayWindow.orderOut(nil)
        gLauncherWindowController.dismiss()
        dismissPanels()
    }

    private func updateGLauncher(for snapshot: TextSnapshot, overlayFrame frame: CGRect, caretScreenRect: CGRect?) {
        let size: CGFloat = 34
        let margin: CGFloat = 7
        // Keep the document entry point visible whenever Grammarless has a valid
        // focused text context. Prefer the caret when available; if the user has
        // selected text or AX does not expose caret geometry, anchor a stable
        // launcher inside the editor's top-right corner instead of hiding it.
        guard frame.width >= size + margin,
              frame.height >= size + margin else {
            gLauncherWindowController.dismiss()
            lastGLauncherTopLeftScreenRect = nil
            return
        }

        let desiredTopLeft: CGPoint
        if let caretScreenRect {
            desiredTopLeft = CGPoint(x: caretScreenRect.maxX + margin, y: caretScreenRect.maxY + margin)
        } else {
            desiredTopLeft = CGPoint(x: frame.maxX - size - margin, y: frame.minY + margin)
        }
        let topLeft = clampedLauncherTopLeft(desiredTopLeft, size: size)
        let topLeftRect = CGRect(origin: topLeft, size: CGSize(width: size, height: size))
        lastGLauncherTopLeftScreenRect = topLeftRect
        gLauncherWindowController.present(
            atTopLeft: topLeft,
            language: language,
            activate: { [weak self] in
                DebugLogger.log("g launcher activated")
                self?.onGLauncherActivated?()
            }
        )
    }

    private func clampedLauncherTopLeft(_ point: CGPoint, size: CGFloat) -> CGPoint {
        let screenFrame = topLeftScreenFrame(containing: point)
        let margin: CGFloat = 4
        return CGPoint(
            x: min(max(point.x, screenFrame.minX + margin), screenFrame.maxX - size - margin),
            y: min(max(point.y, screenFrame.minY + margin), screenFrame.maxY - size - margin)
        )
    }

    private func topLeftScreenFrame(containing point: CGPoint) -> CGRect {
        let frames = NSScreen.screens.map { appKitScreenFrameToTopLeftFrame($0.visibleFrame) }
        if let frame = frames.first(where: { $0.insetBy(dx: -80, dy: -80).contains(point) }) {
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

    private func convertTopLeftScreenRectToAppKitFrame(_ rect: CGRect) -> CGRect {
        let screenHeight = NSScreen.main?.frame.maxY ?? 0
        return CGRect(
            x: rect.origin.x,
            y: screenHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    private func convertToLocal(_ screenRect: CGRect, frame: CGRect) -> CGRect {
        CGRect(
            x: screenRect.origin.x - frame.origin.x,
            y: frame.height - (screenRect.origin.y - frame.origin.y) - screenRect.height,
            width: screenRect.width,
            height: screenRect.height
        )
    }

    private func normalizeLocalRect(_ rect: CGRect, frameHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: frameHeight - rect.origin.y - rect.height,
            width: max(rect.width, 6),
            height: max(rect.height, 10)
        )
    }

    private func installGlobalEventMonitors() {
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            DispatchQueue.main.async { [weak self] in
                self?.handleGlobalMouseDown(event)
            }
        }
        globalMouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            DispatchQueue.main.async { [weak self] in
                self?.handleGlobalMouseMoved(event)
            }
        }
    }

    private func startHoverTrackingTimer() {
        hoverTrackingTimer?.invalidate()
        hoverTrackingTimer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { [weak self] _ in
            self?.handleHoverTrackingTick()
        }
        if let hoverTrackingTimer {
            RunLoop.main.add(hoverTrackingTimer, forMode: .common)
        }
    }

    private func handleGlobalMouseDown(_ event: NSEvent) {
        let screenPoint = event.locationInWindow
        if aiPanelWindowController.isVisible, !NSApp.isActive {
            DebugLogger.log(
                "global mouseDown dismissing ai panel outside point=\(NSStringFromPoint(screenPoint))"
            )
            onAICancel?()
            return
        }
        if hoverWindowController.isVisible, !containsPointInAnyScreenCoordinate(expandedHoverFrame(), point: screenPoint) {
            dismissSuggestionHover()
        }
        guard overlayWindow.isVisible else { return }

        let expandedFrame = overlayWindow.frame.insetBy(dx: -8, dy: -8)
        guard let resolvedScreenPoint = firstMatchingScreenPoint(in: expandedFrame, point: screenPoint) else {
            DebugLogger.log(
                "global mouseDown point=\(NSStringFromPoint(screenPoint)) containsOverlay=false " +
                    "appActive=\(NSApp.isActive) hoverVisible=\(self.hoverWindowController.isVisible) aiVisible=\(self.aiPanelWindowController.isVisible)"
            )
            return
        }
        DebugLogger.log(
            "global mouseDown point=\(NSStringFromPoint(screenPoint)) containsOverlay=true resolvedPoint=\(NSStringFromPoint(resolvedScreenPoint)) " +
                "appActive=\(NSApp.isActive) hoverVisible=\(self.hoverWindowController.isVisible) aiVisible=\(self.aiPanelWindowController.isVisible)"
        )

        guard !NSApp.isActive else { return }
        guard !hoverWindowController.isVisible else { return }
        guard !aiPanelWindowController.isVisible else { return }

        let windowPoint = overlayWindow.convertPoint(fromScreen: resolvedScreenPoint)
        let localPoint = overlayView.convert(windowPoint, from: nil)
        let handled = overlayView.handleClick(atLocalPoint: localPoint, source: "global")
        DebugLogger.log(
            "global mouseDown routed handled=\(handled) localPoint=\(NSStringFromPoint(localPoint))"
        )
    }

    private func handleGlobalMouseMoved(_ event: NSEvent) {
        updateVBarHover(at: event.locationInWindow)
        updateSuggestionHover(at: event.locationInWindow)
    }

    private func handleHoverTrackingTick() {
        updateVBarHover(at: NSEvent.mouseLocation)
        updateSuggestionHover(at: NSEvent.mouseLocation)
    }

    private func updateVBarHover(at screenPoint: CGPoint) {
        guard overlayWindow.isVisible, !aiPanelWindowController.isVisible else {
            overlayView.updateVBarHover(atLocalPoint: nil)
            return
        }
        let expandedOverlayFrame = overlayWindow.frame.insetBy(dx: -8, dy: -8)
        guard let resolvedScreenPoint = firstMatchingScreenPoint(in: expandedOverlayFrame, point: screenPoint) else {
            overlayView.updateVBarHover(atLocalPoint: nil)
            return
        }
        let windowPoint = overlayWindow.convertPoint(fromScreen: resolvedScreenPoint)
        let localPoint = overlayView.convert(windowPoint, from: nil)
        overlayView.updateVBarHover(atLocalPoint: localPoint)
    }

    private func updateSuggestionHover(at screenPoint: CGPoint) {
        guard overlayWindow.isVisible || hoverWindowController.isVisible else { return }
        guard !aiPanelWindowController.isVisible else {
            dismissSuggestionHover()
            return
        }

        if hoverWindowController.isVisible {
            let hoverSafeFrames = [expandedHoverFrame(), hoverTransitFrame()].compactMap { $0 }
            if hoverSafeFrames.contains(where: { containsPointInAnyScreenCoordinate($0, point: screenPoint) }) {
                cancelScheduledHoverDismiss()
                return
            }
        }
        guard overlayWindow.isVisible else {
            scheduleHoverDismiss()
            return
        }

        let expandedOverlayFrame = overlayWindow.frame.insetBy(dx: -8, dy: -8)
        guard let resolvedScreenPoint = firstMatchingScreenPoint(in: expandedOverlayFrame, point: screenPoint) else {
            scheduleHoverDismiss()
            return
        }

        let windowPoint = overlayWindow.convertPoint(fromScreen: resolvedScreenPoint)
        let localPoint = overlayView.convert(windowPoint, from: nil)
        guard let renderedSuggestion = overlayView.hoveredSuggestion(at: localPoint) else {
            scheduleHoverDismiss()
            return
        }

        cancelScheduledHoverDismiss()
        showSuggestionHover(for: renderedSuggestion.suggestion)
    }

    private func dismissSuggestionHover() {
        cancelScheduledHoverDismiss()
        hoveredSuggestionIdentity = nil
        hoverWindowController.dismiss()
    }

    private func syncVisibleHoverSuggestionIfNeeded() {
        guard let hoveredSuggestionIdentity else { return }
        guard let hoveredSuggestion = activeSuggestions.first(where: { $0.stableIdentity == hoveredSuggestionIdentity }) else {
            dismissSuggestionHover()
            return
        }
        showSuggestionHover(for: hoveredSuggestion)
    }

    private func suggestionHoverAnchor(for suggestion: Suggestion) -> CGPoint? {
        lastRenderedSuggestionRects
            .first(where: { $0.suggestion.stableIdentity == suggestion.stableIdentity })
            .map { CGPoint(x: $0.screenRect.minX, y: $0.screenRect.maxY + 8) }
    }

    private func fallbackSuggestionHoverAnchor() -> CGPoint {
        if let lastOverlayFrame {
            return CGPoint(x: lastOverlayFrame.maxX - 320, y: lastOverlayFrame.minY + 28)
        }
        return CGPoint(x: 240, y: 200)
    }

    private func expandedHoverFrame() -> CGRect {
        hoverWindowController.screenFrame.insetBy(dx: -18, dy: -18)
    }

    private func hoverTransitFrame() -> CGRect? {
        guard let hoveredSuggestionIdentity,
              let sourceRect = lastRenderedSuggestionRects
              .first(where: { $0.suggestion.stableIdentity == hoveredSuggestionIdentity })?
              .screenRect
        else {
            return nil
        }

        let expandedSourceRect = sourceRect.insetBy(dx: -14, dy: -14)
        let expandedHoverRect = hoverWindowController.topLeftScreenFrame.insetBy(dx: -18, dy: -18)
        return expandedSourceRect.union(expandedHoverRect)
    }

    private func scheduleHoverDismiss(delay: TimeInterval = 0.65) {
        guard hoverWindowController.isVisible else { return }
        guard hoverDismissWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverDismissWorkItem = nil
            DebugLogger.log("suggestion hover dismiss scheduled")
            self.dismissSuggestionHover()
        }
        hoverDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelScheduledHoverDismiss() {
        hoverDismissWorkItem?.cancel()
        hoverDismissWorkItem = nil
    }

    private func containsPointInAnyScreenCoordinate(_ frame: CGRect, point: CGPoint) -> Bool {
        firstMatchingScreenPoint(in: frame, point: point) != nil
    }

    private func firstMatchingScreenPoint(in frame: CGRect, point: CGPoint) -> CGPoint? {
        candidateScreenPoints(from: point).first(where: { frame.contains($0) })
    }

    private func candidateScreenPoints(from point: CGPoint) -> [CGPoint] {
        let screenHeight = NSScreen.main?.frame.maxY ?? 0
        let flipped = CGPoint(x: point.x, y: screenHeight - point.y)
        if abs(flipped.y - point.y) <= 0.5 {
            return [point]
        }
        return [point, flipped]
    }

    private func rectsApproximatelyEqual(_ lhs: CGRect?, _ rhs: CGRect?, tolerance: CGFloat = 0.5) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (lhs?, rhs?):
            abs(lhs.origin.x - rhs.origin.x) <= tolerance &&
                abs(lhs.origin.y - rhs.origin.y) <= tolerance &&
                abs(lhs.size.width - rhs.size.width) <= tolerance &&
                abs(lhs.size.height - rhs.size.height) <= tolerance
        default:
            false
        }
    }

    private func visuallyMatchesSuggestions(_ lhs: [RenderedSuggestion], _ rhs: [RenderedSuggestion]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { lhsItem, rhsItem in
            lhsItem.suggestion.stableIdentity == rhsItem.suggestion.stableIdentity &&
                rectsApproximatelyEqual(lhsItem.screenRect, rhsItem.screenRect) &&
                rectsApproximatelyEqual(lhsItem.localRect, rhsItem.localRect)
        }
    }
}

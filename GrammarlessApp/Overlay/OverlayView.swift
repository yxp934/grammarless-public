import AppKit
import GrammarlessCore

struct RenderedSuggestion {
    let suggestion: Suggestion
    let screenRect: CGRect
    let localRect: CGRect
}

private extension CGRect {
    func approximatelyEquals(_ other: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(origin.x - other.origin.x) <= tolerance &&
            abs(origin.y - other.origin.y) <= tolerance &&
            abs(size.width - other.size.width) <= tolerance &&
            abs(size.height - other.size.height) <= tolerance
    }
}

private extension RenderedSuggestion {
    func visuallyMatches(_ other: RenderedSuggestion, tolerance: CGFloat = 0.5) -> Bool {
        suggestion.stableIdentity == other.suggestion.stableIdentity &&
            screenRect.approximatelyEquals(other.screenRect, tolerance: tolerance) &&
            localRect.approximatelyEquals(other.localRect, tolerance: tolerance)
    }
}

enum OverlayClickTarget {
    case vbar
    case fallbackBadge

    func logMessage(point: CGPoint, source: String) -> String {
        switch self {
        case .vbar:
            return "overlay click source=\(source) point=\(NSStringFromPoint(point)) target=vbar"
        case .fallbackBadge:
            return "overlay click source=\(source) point=\(NSStringFromPoint(point)) target=fallbackBadge"
        }
    }
}

private func interactiveRect(for rect: CGRect) -> CGRect {
    let inset = min(max(rect.height * 0.42, 4), 6)
    let y = max(rect.minY + inset, 2)
    let hitPadding = max(rect.height * 0.32, 5)
    return CGRect(
        x: rect.minX - 3,
        y: y - hitPadding,
        width: rect.width + 6,
        height: hitPadding * 2
    )
}

final class OverlayView: NSView {
    var suggestionRects: [RenderedSuggestion] = [] {
        didSet {
            guard !visuallyMatchesSuggestions(suggestionRects, oldValue) else { return }
            needsDisplay = true
        }
    }
    var vbarRect: CGRect? {
        didSet {
            guard !rectsApproximatelyEqual(vbarRect, oldValue) else { return }
            if oldValue == nil, vbarRect != nil {
                startVBarAppearAnimation()
            } else if vbarRect == nil {
                stopVBarAnimation()
                setVBarHovered(false, updateCursor: true)
                stopVBarHoverAnimation()
                vbarProgress = 0
                vbarHoverProgress = 0
            } else {
                vbarProgress = 1
            }
            needsDisplay = true
        }
    }
    var analysisGuideRect: CGRect? {
        didSet {
            guard !rectsApproximatelyEqual(analysisGuideRect, oldValue) else { return }
            needsDisplay = true
        }
    }
    var fallbackBadgeRect: CGRect? {
        didSet {
            guard !rectsApproximatelyEqual(fallbackBadgeRect, oldValue) else { return }
            needsDisplay = true
        }
    }
    var ghostText: String = "" {
        didSet {
            guard ghostText != oldValue else { return }
            needsDisplay = true
        }
    }
    var ghostRect: CGRect? {
        didSet {
            guard !rectsApproximatelyEqual(ghostRect, oldValue) else { return }
            needsDisplay = true
        }
    }

    var onFallbackClick: (() -> Void)?
    var onVBarClick: (() -> Void)?
    private var vbarProgress: CGFloat = 1
    private var vbarAnimationTimer: Timer?
    private var vbarAnimationStartedAt = Date()
    private var vbarHoverProgress: CGFloat = 0
    private var vbarHoverAnimationTimer: Timer?
    private var vbarHoverAnimationStartedAt = Date()
    private var vbarHoverStartProgress: CGFloat = 0
    private var vbarHoverTargetProgress: CGFloat = 0
    private var isVBarHovered = false
    private var isVBarCursorPushed = false
    private var trackingArea: NSTrackingArea?

    override var isOpaque: Bool { false }

    deinit {
        if isVBarCursorPushed {
            NSCursor.pop()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        for rendered in suggestionRects {
            let rect = rendered.localRect
            let underlineColor = color(for: rendered.suggestion.kind)
            underlineColor.setStroke()
            let y = underlineY(for: rect)
            let path = NSBezierPath()
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.line(to: CGPoint(x: rect.maxX, y: y))
            path.lineWidth = 2
            path.lineCapStyle = .round
            path.stroke()
        }

        if let rect = vbarRect {
            let eased = easeOutCubic(vbarProgress)
            let hoverEased = easeOutCubic(vbarHoverProgress)
            let visibleWidth = max(2, rect.width * eased) + (hoverEased * 2.4)
            let drawRect = CGRect(
                x: rect.maxX - visibleWidth,
                y: rect.minY - hoverEased,
                width: visibleWidth,
                height: rect.height + (hoverEased * 2)
            )
            let path = NSBezierPath(roundedRect: drawRect, xRadius: 2.5, yRadius: 2.5)
            if hoverEased > 0 {
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowBlurRadius = 8 * hoverEased
                shadow.shadowOffset = .zero
                shadow.shadowColor = GrammarlessTheme.nsAquaInk.withAlphaComponent(0.32 * hoverEased)
                shadow.set()
                GrammarlessTheme.nsAqua.withAlphaComponent(0.28 * hoverEased).setFill()
                path.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            GrammarlessTheme.nsAquaInk.withAlphaComponent(min(0.98, (0.90 + 0.08 * hoverEased) * eased)).setFill()
            path.fill()
        }

        if let rect = analysisGuideRect {
            GrammarlessTheme.nsAquaInk.withAlphaComponent(0.38).setStroke()
            let y = min(max(rect.maxY + 4, 2), bounds.height - 2)
            let path = NSBezierPath()
            path.move(to: CGPoint(x: max(rect.minX, 2), y: y))
            path.line(to: CGPoint(x: min(rect.maxX, bounds.width - 2), y: y))
            path.lineWidth = 2
            path.lineCapStyle = .round
            path.setLineDash([5, 4], count: 2, phase: 0)
            path.stroke()
        }

        if let rect = fallbackBadgeRect {
            GrammarlessTheme.nsAquaInk.setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.width / 2, yRadius: rect.height / 2).fill()
            let paragraph = "!" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            ]
            let size = paragraph.size(withAttributes: attributes)
            paragraph.draw(
                at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                withAttributes: attributes
            )
        }

        if let rect = ghostRect, !ghostText.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.62),
                .font: NSFont.systemFont(ofSize: max(12, min(18, rect.height * 0.72)), weight: .regular),
            ]
            (ghostText as NSString).draw(
                at: CGPoint(x: rect.maxX + 2, y: rect.minY + max(0, (rect.height - 16) / 2)),
                withAttributes: attributes
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        _ = handleClick(atLocalPoint: point, source: "view")
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateVBarHover(atLocalPoint: point)
    }

    override func mouseExited(with event: NSEvent) {
        updateVBarHover(atLocalPoint: nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        clickTarget(at: point) == nil ? nil : self
    }

    func handleClick(atLocalPoint point: CGPoint, source: String) -> Bool {
        if let target = clickTarget(at: point) {
            DebugLogger.log(target.logMessage(point: point, source: source))
            switch target {
            case .vbar:
                onVBarClick?()
            case .fallbackBadge:
                onFallbackClick?()
            }
            return true
        }
        DebugLogger.log(
            "overlay click source=\(source) point=\(NSStringFromPoint(point)) target=none suggestions=\(self.suggestionRects.count) " +
                "vbar=\(self.vbarRect != nil) fallback=\(self.fallbackBadgeRect != nil)"
        )
        return false
    }

    func clickTarget(at point: CGPoint) -> OverlayClickTarget? {
        if let vbarRect, expandedVBarHitRect(for: vbarRect).contains(point) {
            return .vbar
        }
        if let fallbackBadgeRect, fallbackBadgeRect.contains(point) {
            return .fallbackBadge
        }
        return nil
    }

    func hoveredSuggestion(at point: CGPoint) -> RenderedSuggestion? {
        suggestionRects.first(where: { interactiveRect(for: $0.localRect).contains(point) })
    }

    @discardableResult
    func updateVBarHover(atLocalPoint point: CGPoint?) -> Bool {
        let hovering: Bool
        if let point, let vbarRect {
            hovering = expandedVBarHitRect(for: vbarRect).contains(point)
        } else {
            hovering = false
        }
        setVBarHovered(hovering, updateCursor: true)
        return hovering
    }

    private func visuallyMatchesSuggestions(_ lhs: [RenderedSuggestion], _ rhs: [RenderedSuggestion]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { $0.visuallyMatches($1) }
    }

    private func rectsApproximatelyEqual(_ lhs: CGRect?, _ rhs: CGRect?, tolerance: CGFloat = 0.5) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs.approximatelyEquals(rhs, tolerance: tolerance)
        default:
            return false
        }
    }

    private func expandedVBarHitRect(for rect: CGRect) -> CGRect {
        rect.insetBy(dx: -14, dy: -12)
    }

    private func startVBarAppearAnimation() {
        stopVBarAnimation()
        vbarProgress = 0
        vbarAnimationStartedAt = Date()
        vbarAnimationTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let elapsed = Date().timeIntervalSince(self.vbarAnimationStartedAt)
            self.vbarProgress = min(1, CGFloat(elapsed / 0.18))
            self.needsDisplay = true
            if self.vbarProgress >= 1 {
                self.stopVBarAnimation()
            }
        }
        if let vbarAnimationTimer {
            RunLoop.main.add(vbarAnimationTimer, forMode: .common)
        }
    }

    private func stopVBarAnimation() {
        vbarAnimationTimer?.invalidate()
        vbarAnimationTimer = nil
    }

    private func setVBarHovered(_ hovering: Bool, updateCursor: Bool) {
        guard hovering != isVBarHovered else { return }
        isVBarHovered = hovering
        startVBarHoverAnimation(toward: hovering ? 1 : 0)
        guard updateCursor else { return }
        if hovering, !isVBarCursorPushed {
            NSCursor.pointingHand.push()
            isVBarCursorPushed = true
        } else if !hovering, isVBarCursorPushed {
            NSCursor.pop()
            isVBarCursorPushed = false
        }
    }

    private func startVBarHoverAnimation(toward target: CGFloat) {
        stopVBarHoverAnimation()
        vbarHoverStartProgress = vbarHoverProgress
        vbarHoverTargetProgress = target
        vbarHoverAnimationStartedAt = Date()
        vbarHoverAnimationTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let elapsed = Date().timeIntervalSince(self.vbarHoverAnimationStartedAt)
            let progress = min(1, CGFloat(elapsed / 0.16))
            let eased = self.easeOutCubic(progress)
            self.vbarHoverProgress = self.vbarHoverStartProgress + ((self.vbarHoverTargetProgress - self.vbarHoverStartProgress) * eased)
            self.needsDisplay = true
            if progress >= 1 {
                self.vbarHoverProgress = self.vbarHoverTargetProgress
                self.stopVBarHoverAnimation()
            }
        }
        if let vbarHoverAnimationTimer {
            RunLoop.main.add(vbarHoverAnimationTimer, forMode: .common)
        }
    }

    private func stopVBarHoverAnimation() {
        vbarHoverAnimationTimer?.invalidate()
        vbarHoverAnimationTimer = nil
    }

    private func easeOutCubic(_ value: CGFloat) -> CGFloat {
        let clamped = min(max(value, 0), 1)
        return 1 - pow(1 - clamped, 3)
    }

    private func color(for kind: SuggestionKind) -> NSColor {
        switch kind {
        case .spelling:
            return GrammarlessTheme.nsError
        case .grammar:
            return GrammarlessTheme.nsGoldInk
        case .rewrite:
            return GrammarlessTheme.nsAquaInk
        }
    }

    private func underlineY(for rect: CGRect) -> CGFloat {
        let inset = min(max(rect.height * 0.42, 4), 6)
        return max(rect.minY + inset, 2)
    }

    private func interactiveRect(for rect: CGRect) -> CGRect {
        let y = underlineY(for: rect)
        let hitPadding = max(rect.height * 0.32, 5)
        return CGRect(
            x: rect.minX - 3,
            y: y - hitPadding,
            width: rect.width + 6,
            height: hitPadding * 2
        )
    }
}

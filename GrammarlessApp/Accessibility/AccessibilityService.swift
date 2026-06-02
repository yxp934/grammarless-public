import AppKit
import ApplicationServices
import Foundation

private let axEditableAttribute = "AXEditable" as CFString
private let axFrameAttribute = "AXFrame" as CFString
private let axChildrenAttribute = kAXChildrenAttribute as CFString
private let axContentsAttribute = kAXContentsAttribute as CFString
private let axVisibleChildrenAttribute = kAXVisibleChildrenAttribute as CFString
private let axWindowsAttribute = kAXWindowsAttribute as CFString
private let axMainWindowAttribute = kAXMainWindowAttribute as CFString
private let axFocusedWindowAttribute = kAXFocusedWindowAttribute as CFString
private let axRoleAttribute = kAXRoleAttribute as CFString
private let axTitleAttribute = kAXTitleAttribute as CFString
private let axFocusedAttribute = kAXFocusedAttribute as CFString
private let axVisibleCharacterRangeAttribute = "AXVisibleCharacterRange" as CFString

struct FocusedTextContext {
    let application: NSRunningApplication
    let window: AXUIElement?
    let element: AXUIElement
    let elementIdentity: String
    let role: String
    let fullText: String
    let selectedRange: NSRange
    let visibleRange: NSRange?
    let elementBounds: CGRect
}

private struct EditableElementCandidate {
    let element: AXUIElement
    let window: AXUIElement?
    let role: String
    let rolePriority: Int
    let frameArea: CGFloat
    let textLength: Int
    let frame: CGRect
    let preview: String
    let applicationBundleIdentifier: String
}

struct EditableTextCandidateDescriptor {
    let applicationBundleIdentifier: String
    let role: String
    let frame: CGRect
    let textLength: Int
    let preview: String
}

struct AXDebugNodeDescriptor {
    let role: String
    let title: String
    let frame: CGRect
    let textLength: Int
    let editable: Bool?
    let preview: String
    let children: [AXDebugNodeDescriptor]
}

struct AXDebugApplicationDescriptor {
    let applicationBundleIdentifier: String
    let localizedName: String
    let focusedWindow: AXDebugNodeDescriptor?
    let mainWindow: AXDebugNodeDescriptor?
    let windows: [AXDebugNodeDescriptor]
}

private struct RootSearchScope {
    let window: AXUIElement?
    let roots: [AXUIElement]
}

final class AccessibilityService {
    private let systemWide = AXUIElementCreateSystemWide()
    private let editableRoles: Set<String> = [
        kAXTextAreaRole as String,
        kAXTextFieldRole as String,
        kAXComboBoxRole as String,
    ]
    private let containerRoles: Set<String> = [
        kAXApplicationRole as String,
        kAXWindowRole as String,
        kAXGroupRole as String,
        "AXSplitGroup",
        "AXLayoutArea",
        "AXTabGroup",
        "AXScrollArea",
        "AXSheet",
        "AXUnknown",
    ]
    private let blockedTraversalRoles: Set<String> = [
        kAXMenuBarRole as String,
        kAXMenuRole as String,
        kAXMenuItemRole as String,
        kAXMenuBarItemRole as String,
        kAXToolbarRole as String,
        kAXButtonRole as String,
        kAXStaticTextRole as String,
        kAXImageRole as String,
        kAXPopUpButtonRole as String,
        kAXCheckBoxRole as String,
        kAXRadioButtonRole as String,
        kAXIncrementorRole as String,
        kAXDisclosureTriangleRole as String,
        kAXBusyIndicatorRole as String,
    ]

    func isProcessTrusted(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func frontmostApplication() -> NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication
    }

    func focusedApplication() -> NSRunningApplication? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &value)
        guard status == .success, let rawValue = value else { return nil }
        let applicationElement = rawValue as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementGetPid(applicationElement, &pid) == .success else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    func focusedTextContext() -> FocusedTextContext? {
        guard let focusedElement = focusedElement() else { return nil }
        if let focusedApplication = focusedApplication() {
            let appElement = AXUIElementCreateApplication(focusedApplication.processIdentifier)
            let focusedWindow = elementAttribute(axFocusedWindowAttribute, on: appElement) ??
                elementAttribute(axMainWindowAttribute, on: appElement)
            if let context = textContext(
                for: focusedApplication,
                element: focusedElement,
                window: focusedWindow
            )
            {
                return context
            }
        }
        guard let application = frontmostApplication() else { return nil }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        let focusedWindow = elementAttribute(axFocusedWindowAttribute, on: appElement) ??
            elementAttribute(axMainWindowAttribute, on: appElement)
        return textContext(
            for: application,
            element: focusedElement,
            window: focusedWindow
        )
    }

    func fallbackTextEditContext() -> FocusedTextContext? {
        fallbackEditableTextContext(preferredBundleIdentifiers: ["com.apple.TextEdit"])
    }

    func fallbackEditableTextContext(preferredBundleIdentifiers: [String]) -> FocusedTextContext? {
        let runningApps = NSWorkspace.shared.runningApplications.filter { application in
            guard !application.isTerminated else { return false }
            guard let bundleIdentifier = application.bundleIdentifier else { return false }
            return preferredBundleIdentifiers.contains(bundleIdentifier)
        }

        for application in runningApps {
            if let context = textContextForApplication(application, preferFocusedElement: false) {
                return context
            }
        }

        return nil
    }

    func documentTextContext(for application: NSRunningApplication) -> FocusedTextContext? {
        textContextForApplication(application, preferFocusedElement: true)
    }

    func editableTextCandidates(preferredBundleIdentifiers: [String]) -> [EditableTextCandidateDescriptor] {
        let runningApps = NSWorkspace.shared.runningApplications.filter { application in
            guard !application.isTerminated else { return false }
            guard let bundleIdentifier = application.bundleIdentifier else { return false }
            return preferredBundleIdentifiers.contains(bundleIdentifier)
        }

        var descriptors: [EditableTextCandidateDescriptor] = []
        for application in runningApps {
            descriptors.append(contentsOf: editableCandidateDescriptors(for: application))
        }
        return descriptors.sorted { lhs, rhs in
            if lhs.textLength != rhs.textLength {
                return lhs.textLength > rhs.textLength
            }
            let lhsArea = lhs.frame.width * lhs.frame.height
            let rhsArea = rhs.frame.width * rhs.frame.height
            return lhsArea > rhsArea
        }
    }

    func editableTextContextCandidate(
        preferredBundleIdentifiers: [String],
        index: Int
    ) -> FocusedTextContext? {
        guard index >= 0 else { return nil }
        let runningApps = NSWorkspace.shared.runningApplications.filter { application in
            guard !application.isTerminated else { return false }
            guard let bundleIdentifier = application.bundleIdentifier else { return false }
            return preferredBundleIdentifiers.contains(bundleIdentifier)
        }

        var candidates: [(application: NSRunningApplication, candidate: EditableElementCandidate)] = []
        for application in runningApps {
            candidates.append(contentsOf: editableCandidates(for: application).map { (application, $0) })
        }

        let sorted = candidates.sorted { lhs, rhs in
            if lhs.candidate.rolePriority != rhs.candidate.rolePriority {
                return lhs.candidate.rolePriority > rhs.candidate.rolePriority
            }
            if lhs.candidate.textLength != rhs.candidate.textLength {
                return lhs.candidate.textLength > rhs.candidate.textLength
            }
            return lhs.candidate.frameArea > rhs.candidate.frameArea
        }

        guard index < sorted.count else { return nil }
        let chosen = sorted[index]
        return textContext(
            for: chosen.application,
            element: chosen.candidate.element,
            window: chosen.candidate.window
        )
    }

    func debugTree(preferredBundleIdentifiers: [String]) -> [AXDebugApplicationDescriptor] {
        let runningApps = NSWorkspace.shared.runningApplications.filter { application in
            guard !application.isTerminated else { return false }
            guard let bundleIdentifier = application.bundleIdentifier else { return false }
            return preferredBundleIdentifiers.contains(bundleIdentifier)
        }

        return runningApps.map { application in
            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            let focusedWindow = elementAttribute(axFocusedWindowAttribute, on: appElement).map {
                debugNode(for: $0, maxDepth: 3, maxChildren: 6)
            }
            let mainWindow = elementAttribute(axMainWindowAttribute, on: appElement).map {
                debugNode(for: $0, maxDepth: 3, maxChildren: 6)
            }
            let windows = elementArrayAttribute(axWindowsAttribute, on: appElement)
                .prefix(4)
                .map { debugNode(for: $0, maxDepth: 2, maxChildren: 6) }

            return AXDebugApplicationDescriptor(
                applicationBundleIdentifier: application.bundleIdentifier ?? "unknown",
                localizedName: application.localizedName ?? application.bundleIdentifier ?? "unknown",
                focusedWindow: focusedWindow,
                mainWindow: mainWindow,
                windows: windows
            )
        }
    }

    private func textContextForApplication(
        _ application: NSRunningApplication,
        preferFocusedElement: Bool = true
    ) -> FocusedTextContext? {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        let applicationBundleIdentifier = application.bundleIdentifier ?? "unknown"

        if preferFocusedElement,
           let focusedElement = elementAttribute(kAXFocusedUIElementAttribute as CFString, on: appElement)
        {
            let focusedWindow = elementAttribute(axFocusedWindowAttribute, on: appElement) ??
                elementAttribute(axMainWindowAttribute, on: appElement)
            if let context = textContext(
                for: application,
                element: focusedElement,
                window: focusedWindow
            )
            {
                return context
            }
        }

        let scopes = rootSearchScopes(in: appElement)
        if preferFocusedElement {
            for scope in scopes.prefix(2) {
                if let focusedWindowCandidate = bestEditableCandidate(
                    in: scope,
                    applicationBundleIdentifier: applicationBundleIdentifier
                ) {
                    return textContext(
                        for: application,
                        element: focusedWindowCandidate.element,
                        window: focusedWindowCandidate.window
                    )
                }
            }
        }

        var visited = Set<Int>()
        var bestCandidate: EditableElementCandidate?
        for scope in scopes {
            for root in scope.roots {
                if let candidate = bestEditableDescendant(
                    in: root,
                    applicationBundleIdentifier: applicationBundleIdentifier,
                    ownerWindow: scope.window,
                    visited: &visited
                ) {
                    if let currentBest = bestCandidate {
                        if isBetter(candidate, than: currentBest) {
                            bestCandidate = candidate
                        }
                    } else {
                        bestCandidate = candidate
                    }
                }
            }
        }

        guard let bestCandidate else { return nil }
        return textContext(
            for: application,
            element: bestCandidate.element,
            window: bestCandidate.window
        )
    }

    private func bestEditableCandidate(
        in scope: RootSearchScope,
        applicationBundleIdentifier: String
    ) -> EditableElementCandidate? {
        var visited = Set<Int>()
        var bestCandidate: EditableElementCandidate?
        for root in scope.roots {
            guard let candidate = bestEditableDescendant(
                in: root,
                applicationBundleIdentifier: applicationBundleIdentifier,
                ownerWindow: scope.window,
                visited: &visited
            ) else { continue }
            if let currentBest = bestCandidate {
                if isBetter(candidate, than: currentBest) {
                    bestCandidate = candidate
                }
            } else {
                bestCandidate = candidate
            }
        }
        return bestCandidate
    }

    private func rootSearchScopes(in applicationElement: AXUIElement) -> [RootSearchScope] {
        var windows: [AXUIElement] = []
        if let focusedWindow = elementAttribute(axFocusedWindowAttribute, on: applicationElement) {
            windows.append(focusedWindow)
        }
        if let mainWindow = elementAttribute(axMainWindowAttribute, on: applicationElement) {
            windows.append(mainWindow)
        }
        windows.append(contentsOf: elementArrayAttribute(axWindowsAttribute, on: applicationElement))

        var scopes: [RootSearchScope] = []
        for window in deduplicatedElements(windows) {
            let contentRoots = contentRoots(for: window)
            scopes.append(
                RootSearchScope(
                    window: window,
                    roots: contentRoots.isEmpty ? [window] : contentRoots
                )
            )
        }

        if scopes.isEmpty {
            scopes.append(RootSearchScope(window: nil, roots: [applicationElement]))
        }

        return scopes
    }

    private func rootElementsForFallbackSearch(in applicationElement: AXUIElement) -> [AXUIElement] {
        deduplicatedElements(rootSearchScopes(in: applicationElement).flatMap(\.roots))
    }

    private func bestEditableDescendant(
        in root: AXUIElement,
        applicationBundleIdentifier: String,
        ownerWindow: AXUIElement?,
        visited: inout Set<Int>
    ) -> EditableElementCandidate? {
        let identity = Int(CFHash(root))
        guard visited.insert(identity).inserted else { return nil }

        var bestCandidate = editableCandidate(
            for: root,
            applicationBundleIdentifier: applicationBundleIdentifier,
            ownerWindow: ownerWindow
        )

        for child in relatedElements(for: root) {
            guard let candidate = bestEditableDescendant(
                in: child,
                applicationBundleIdentifier: applicationBundleIdentifier,
                ownerWindow: ownerWindow,
                visited: &visited
            ) else { continue }
            if let currentBest = bestCandidate {
                if isBetter(candidate, than: currentBest) {
                    bestCandidate = candidate
                }
            } else {
                bestCandidate = candidate
            }
        }

        return bestCandidate
    }

    private func editableCandidateDescriptors(for application: NSRunningApplication) -> [EditableTextCandidateDescriptor] {
        editableCandidates(for: application).map {
            EditableTextCandidateDescriptor(
                applicationBundleIdentifier: $0.applicationBundleIdentifier,
                role: $0.role,
                frame: $0.frame,
                textLength: $0.textLength,
                preview: $0.preview
            )
        }
    }

    private func editableCandidates(for application: NSRunningApplication) -> [EditableElementCandidate] {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var visited = Set<Int>()
        var candidates: [EditableElementCandidate] = []

        for scope in rootSearchScopes(in: appElement) {
            for root in scope.roots {
                collectEditableCandidates(
                    in: root,
                    applicationBundleIdentifier: application.bundleIdentifier ?? "unknown",
                    ownerWindow: scope.window,
                    visited: &visited,
                    into: &candidates
                )
            }
        }

        return candidates.sorted { lhs, rhs in
            if lhs.rolePriority != rhs.rolePriority {
                return lhs.rolePriority > rhs.rolePriority
            }
            if lhs.textLength != rhs.textLength {
                return lhs.textLength > rhs.textLength
            }
            if lhs.frameArea != rhs.frameArea {
                return lhs.frameArea > rhs.frameArea
            }
            return false
        }
    }

    private func collectEditableCandidates(
        in root: AXUIElement,
        applicationBundleIdentifier: String,
        ownerWindow: AXUIElement?,
        visited: inout Set<Int>,
        into candidates: inout [EditableElementCandidate]
    ) {
        let identity = Int(CFHash(root))
        guard visited.insert(identity).inserted else { return }

        if let candidate = editableCandidate(
            for: root,
            applicationBundleIdentifier: applicationBundleIdentifier,
            ownerWindow: ownerWindow
        ) {
            candidates.append(candidate)
        }

        for child in relatedElements(for: root) {
            collectEditableCandidates(
                in: child,
                applicationBundleIdentifier: applicationBundleIdentifier,
                ownerWindow: ownerWindow,
                visited: &visited,
                into: &candidates
            )
        }
    }

    private func relatedElements(for element: AXUIElement) -> [AXUIElement] {
        let role = stringAttribute(axRoleAttribute, on: element) ?? "unknown"
        guard !blockedTraversalRoles.contains(role) else { return [] }

        var related: [AXUIElement] = []
        for attribute in traversalAttributes(forRole: role) {
            related.append(contentsOf: elementArrayAttribute(attribute, on: element))
            if let contentElement = elementAttribute(attribute, on: element) {
                related.append(contentElement)
            }
        }

        return deduplicatedElements(related.filter { child in
            let childRole = stringAttribute(axRoleAttribute, on: child) ?? "unknown"
            guard !blockedTraversalRoles.contains(childRole) else { return false }
            return containerRoles.contains(childRole) || isDocumentLikeEditableElement(child)
        })
    }

    private func editableCandidate(
        for element: AXUIElement,
        applicationBundleIdentifier: String,
        ownerWindow: AXUIElement?
    ) -> EditableElementCandidate? {
        let role = stringAttribute(axRoleAttribute, on: element) ?? "unknown"
        let editable = boolAttribute(axEditableAttribute, on: element) ?? true
        guard editable else { return nil }
        guard editableRoles.contains(role) else {
            return nil
        }
        let frame = rectAttribute(axFrameAttribute, on: element) ?? .zero
        let value = stringAttribute(kAXValueAttribute as CFString, on: element) ?? ""
        let textLength = (value as NSString).length

        let rolePriority: Int
        switch role {
        case String(kAXTextAreaRole):
            rolePriority = isLikelyDocumentEditor(
                role: role,
                frame: frame,
                textLength: textLength,
                preview: value
            ) ? 5 : 4
        case String(kAXTextFieldRole):
            rolePriority = isLikelyDocumentEditor(
                role: role,
                frame: frame,
                textLength: textLength,
                preview: value
            ) ? 3 : 1
        default:
            rolePriority = isLikelyDocumentEditor(
                role: role,
                frame: frame,
                textLength: textLength,
                preview: value
            ) ? 2 : 0
        }
        return EditableElementCandidate(
            element: element,
            window: ownerWindow,
            role: role,
            rolePriority: rolePriority,
            frameArea: max(frame.width, 0) * max(frame.height, 0),
            textLength: textLength,
            frame: frame,
            preview: String(value.prefix(120)),
            applicationBundleIdentifier: applicationBundleIdentifier
        )
    }

    private func isBetter(_ lhs: EditableElementCandidate, than rhs: EditableElementCandidate) -> Bool {
        if lhs.rolePriority != rhs.rolePriority {
            return lhs.rolePriority > rhs.rolePriority
        }
        if lhs.frameArea != rhs.frameArea {
            return lhs.frameArea > rhs.frameArea
        }
        if lhs.textLength != rhs.textLength {
            return lhs.textLength > rhs.textLength
        }
        return false
    }

    private func textContext(
        for application: NSRunningApplication,
        element: AXUIElement,
        window: AXUIElement?
    ) -> FocusedTextContext? {
        let role = stringAttribute(axRoleAttribute, on: element) ?? "unknown"
        let editable = boolAttribute(axEditableAttribute, on: element) ?? true
        guard editable else { return nil }
        guard editableRoles.contains(role) else {
            return nil
        }
        let value = stringAttribute(kAXValueAttribute as CFString, on: element) ?? ""

        let selectedRange = rangeAttribute(kAXSelectedTextRangeAttribute as CFString, on: element) ?? NSRange(location: 0, length: 0)
        let frame = rectAttribute(axFrameAttribute, on: element) ?? .zero
        let visibleRange = visibleTextRange(in: element, fullText: value, elementBounds: frame)
        let pid = application.processIdentifier
        return FocusedTextContext(
            application: application,
            window: window,
            element: element,
            elementIdentity: "\(pid)-\(CFHash(element))",
            role: role,
            fullText: value,
            selectedRange: selectedRange,
            visibleRange: visibleRange,
            elementBounds: frame
        )
    }

    func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value)
        guard result == .success, let element = value else { return nil }
        return (element as! AXUIElement)
    }

    func bounds(for range: NSRange, in element: AXUIElement) -> CGRect? {
        var mutableRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else { return nil }
        var result: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &result
        )
        guard status == .success, let value = result else { return nil }
        let axValue = value as! AXValue
        var rect = CGRect.zero
        guard AXValueGetType(axValue) == .cgRect, AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private func visibleTextRange(in element: AXUIElement, fullText: String, elementBounds: CGRect) -> NSRange? {
        let nsText = fullText as NSString
        guard nsText.length > 0 else { return nil }

        if let axRange = rangeAttribute(axVisibleCharacterRangeAttribute, on: element),
           isValidTextRange(axRange, textLength: nsText.length),
           axRange.length > 0 {
            return axRange
        }

        return inferredVisibleTextRange(in: element, fullText: fullText, elementBounds: elementBounds)
    }

    private func inferredVisibleTextRange(in element: AXUIElement, fullText: String, elementBounds: CGRect) -> NSRange? {
        let nsText = fullText as NSString
        guard nsText.length > 0, !elementBounds.isEmpty else { return nil }
        let visibleFrame = elementBounds.insetBy(dx: -12, dy: -12)
        var visibleRanges: [NSRange] = []
        var location = 0

        while location < nsText.length {
            let paragraphRange = nsText.paragraphRange(for: NSRange(location: location, length: 0))
            let probeRange = firstNonEmptyProbeRange(in: paragraphRange, textLength: nsText.length)
            if let probeRange,
               let rect = bounds(for: probeRange, in: element),
               rect.intersects(visibleFrame) {
                visibleRanges.append(paragraphRange)
            }
            let nextLocation = NSMaxRange(paragraphRange)
            guard nextLocation > location else { break }
            location = nextLocation
        }

        guard let first = visibleRanges.first else { return nil }
        return visibleRanges.dropFirst().reduce(first) { NSUnionRange($0, $1) }
    }

    private func firstNonEmptyProbeRange(in range: NSRange, textLength: Int) -> NSRange? {
        guard range.location != NSNotFound, range.location < textLength else { return nil }
        guard NSMaxRange(range) > range.location else { return nil }
        return NSRange(location: range.location, length: 1)
    }

    private func isValidTextRange(_ range: NSRange, textLength: Int) -> Bool {
        range.location != NSNotFound &&
            range.location >= 0 &&
            range.length >= 0 &&
            NSMaxRange(range) <= textLength
    }

    func rectAttribute(_ attribute: CFString, on element: AXUIElement) -> CGRect? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success, let rawValue = value else { return nil }
        let axValue = rawValue as! AXValue
        var rect = CGRect.zero
        guard AXValueGetType(axValue) == .cgRect, AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        return rect
    }

    func rangeAttribute(_ attribute: CFString, on element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success, let rawValue = value else { return nil }
        let axValue = rawValue as! AXValue
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    func stringAttribute(_ attribute: CFString, on element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success else { return nil }
        return value as? String
    }

    func elementAttribute(_ attribute: CFString, on element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success, let rawValue = value else { return nil }
        return (rawValue as! AXUIElement)
    }

    func elementArrayAttribute(_ attribute: CFString, on element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success, let rawValue = value as? [Any] else { return [] }
        return rawValue.map { $0 as! AXUIElement }
    }

    func boolAttribute(_ attribute: CFString, on element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success else { return nil }
        return value as? Bool
    }

    func setSelectedRange(_ range: NSRange, on element: AXUIElement) -> Bool {
        var mutableRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &mutableRange) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    func replaceSelectedText(_ text: String, on element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
    }

    func setFocused(_ element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, axFocusedAttribute, kCFBooleanTrue) == .success
    }

    func setFocusedWindow(_ window: AXUIElement, for application: NSRunningApplication) -> Bool {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        return AXUIElementSetAttributeValue(appElement, axFocusedWindowAttribute, window) == .success
    }

    func setMainWindow(_ window: AXUIElement, for application: NSRunningApplication) -> Bool {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        return AXUIElementSetAttributeValue(appElement, axMainWindowAttribute, window) == .success
    }

    func raise(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success
    }

    private func contentRoots(for window: AXUIElement) -> [AXUIElement] {
        var roots: [AXUIElement] = []
        roots.append(contentsOf: elementArrayAttribute(axContentsAttribute, on: window))
        if let contentElement = elementAttribute(axContentsAttribute, on: window) {
            roots.append(contentElement)
        }

        let visibleChildren = elementArrayAttribute(axVisibleChildrenAttribute, on: window)
        let children = elementArrayAttribute(axChildrenAttribute, on: window)
        roots.append(contentsOf: visibleChildren.filter(isLikelyContentRoot))
        roots.append(contentsOf: children.filter(isLikelyContentRoot))

        if roots.isEmpty {
            roots.append(contentsOf: visibleChildren.filter(isDocumentLikeEditableElement))
            roots.append(contentsOf: children.filter(isDocumentLikeEditableElement))
        }

        return deduplicatedElements(roots)
    }

    private func traversalAttributes(forRole role: String) -> [CFString] {
        if role == kAXApplicationRole as String {
            return [axWindowsAttribute, axVisibleChildrenAttribute, axChildrenAttribute]
        }
        if role == kAXWindowRole as String {
            return [axContentsAttribute, axVisibleChildrenAttribute, axChildrenAttribute]
        }
        if containerRoles.contains(role) {
            return [axVisibleChildrenAttribute, axContentsAttribute, axChildrenAttribute]
        }
        return [axVisibleChildrenAttribute, axChildrenAttribute]
    }

    private func isLikelyContentRoot(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(axRoleAttribute, on: element) ?? "unknown"
        guard !blockedTraversalRoles.contains(role) else { return false }
        return containerRoles.contains(role) || isDocumentLikeEditableElement(element)
    }

    private func isDocumentLikeEditableElement(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(axRoleAttribute, on: element) ?? "unknown"
        guard editableRoles.contains(role) else { return false }
        let frame = rectAttribute(axFrameAttribute, on: element) ?? .zero
        let value = stringAttribute(kAXValueAttribute as CFString, on: element) ?? ""
        return isLikelyDocumentEditor(
            role: role,
            frame: frame,
            textLength: (value as NSString).length,
            preview: value
        )
    }

    private func isLikelyDocumentEditor(
        role: String,
        frame: CGRect,
        textLength: Int,
        preview: String
    ) -> Bool {
        if role == kAXTextAreaRole as String {
            return frame.height >= 80 || frame.width >= 240 || textLength > 0 || preview.contains("\n")
        }
        return frame.height >= 80 || (frame.width >= 240 && textLength > 32) || preview.contains("\n")
    }

    private func deduplicatedElements(_ elements: [AXUIElement]) -> [AXUIElement] {
        var seen = Set<Int>()
        return elements.filter { seen.insert(Int(CFHash($0))).inserted }
    }

    private func debugNode(
        for element: AXUIElement,
        maxDepth: Int,
        maxChildren: Int
    ) -> AXDebugNodeDescriptor {
        let role = stringAttribute(axRoleAttribute, on: element) ?? "unknown"
        let title = stringAttribute(axTitleAttribute, on: element) ?? ""
        let frame = rectAttribute(axFrameAttribute, on: element) ?? .zero
        let value = stringAttribute(kAXValueAttribute as CFString, on: element) ?? ""
        let children: [AXDebugNodeDescriptor]
        if maxDepth > 0 {
            children = Array(relatedElements(for: element).prefix(maxChildren)).map {
                debugNode(for: $0, maxDepth: maxDepth - 1, maxChildren: maxChildren)
            }
        } else {
            children = []
        }
        return AXDebugNodeDescriptor(
            role: role,
            title: title,
            frame: frame,
            textLength: (value as NSString).length,
            editable: boolAttribute(axEditableAttribute, on: element),
            preview: String(value.prefix(120)),
            children: children
        )
    }
}

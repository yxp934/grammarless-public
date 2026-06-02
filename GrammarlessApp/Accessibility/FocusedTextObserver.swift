import AppKit
import ApplicationServices
import Foundation

final class FocusedTextObserver {
    var onEvent: (() -> Void)?

    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var observedAppElement: AXUIElement?
    private var observedFocusedElement: AXUIElement?

    func attach(to application: NSRunningApplication, focusedElement: AXUIElement?) {
        guard observedPID != application.processIdentifier else {
            if let focusedElement {
                observeFocusedElementIfNeeded(focusedElement)
            }
            return
        }

        detach()

        let pid = application.processIdentifier
        var createdObserver: AXObserver?
        let status = AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon else { return }
            let observer = Unmanaged<FocusedTextObserver>.fromOpaque(refcon).takeUnretainedValue()
            observer.onEvent?()
        }, &createdObserver)

        guard status == .success, let observer = createdObserver else { return }
        self.observer = observer
        self.observedPID = pid

        let appElement = AXUIElementCreateApplication(pid)
        observedAppElement = appElement
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        AXObserverAddNotification(observer, appElement, kAXFocusedUIElementChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .commonModes)

        if let focusedElement {
            observeFocusedElementIfNeeded(focusedElement)
        }
    }

    func observeFocusedElementIfNeeded(_ element: AXUIElement) {
        guard let observer else { return }
        if let observedFocusedElement, CFEqual(element, observedFocusedElement) {
            return
        }

        if let old = observedFocusedElement {
            AXObserverRemoveNotification(observer, old, kAXValueChangedNotification as CFString)
            AXObserverRemoveNotification(observer, old, kAXSelectedTextChangedNotification as CFString)
        }

        observedFocusedElement = element
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        AXObserverAddNotification(observer, element, kAXValueChangedNotification as CFString, refcon)
        AXObserverAddNotification(observer, element, kAXSelectedTextChangedNotification as CFString, refcon)
    }

    func detach() {
        if let observer, let appElement = observedAppElement {
            AXObserverRemoveNotification(observer, appElement, kAXFocusedUIElementChangedNotification as CFString)
            if let focused = observedFocusedElement {
                AXObserverRemoveNotification(observer, focused, kAXValueChangedNotification as CFString)
                AXObserverRemoveNotification(observer, focused, kAXSelectedTextChangedNotification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        observedPID = nil
        observedAppElement = nil
        observedFocusedElement = nil
    }
}

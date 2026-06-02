import AppKit
import Foundation
import GrammarlessCore

enum ReplacementError: Error, LocalizedError {
    case unableToSelectRange
    case unableToReplaceSelectedText
    case unableToSimulatePaste
    case unableToType
    case unableToRunWordAutomation(String)

    var errorDescription: String? {
        switch self {
        case .unableToSelectRange:
            return "Unable to select the requested text range."
        case .unableToReplaceSelectedText:
            return "Unable to replace the selected text."
        case .unableToSimulatePaste:
            return "Unable to paste replacement text."
        case .unableToType:
            return "Unable to type replacement text."
        case let .unableToRunWordAutomation(message):
            return "Unable to replace text in Word: \(message)"
        }
    }
}

final class SystemPasteboardClient: ClipboardClient {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func snapshot() -> ClipboardSnapshot {
        ClipboardSnapshot(string: pasteboard.string(forType: .string))
    }

    func write(string: String) {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    func restore(snapshot: ClipboardSnapshot) {
        pasteboard.clearContents()
        if let string = snapshot.string {
            pasteboard.setString(string, forType: .string)
        }
    }
}

final class TextReplacementExecutor {
    private let accessibilityService: AccessibilityService
    private let pasteboardClient: ClipboardClient

    init(
        accessibilityService: AccessibilityService,
        pasteboardClient: ClipboardClient = SystemPasteboardClient()
    ) {
        self.accessibilityService = accessibilityService
        self.pasteboardClient = pasteboardClient
    }

    func execute(
        command: ReplaceCommand,
        in context: FocusedTextContext
    ) async throws {
        do {
            try await prepareTargetRange(command.targetRange, in: context, phase: "initial")

            switch command.strategy {
            case .nativePaste:
                // A click on a non-activating SwiftUI panel can leave the panel
                // as the key window while the AX selection in Word/TextEdit is
                // still valid. Re-activate and re-select immediately before the
                // synthetic Cmd+V so the paste lands in the host document rather
                // than just leaving text selected.
                try await prepareTargetRange(command.targetRange, in: context, phase: "nativePaste")
                try await pasteReplacement(
                    command.replacementText,
                    restoreDelayNanoseconds: pasteboardRestoreDelay(for: context)
                )
            case .axSelectedText:
                guard accessibilityService.replaceSelectedText(command.replacementText, on: context.element) else {
                    throw ReplacementError.unableToReplaceSelectedText
                }
            case .typingFallback:
                try await prepareTargetRange(command.targetRange, in: context, phase: "typingFallback")
                try typeReplacement(command.replacementText)
            }

            let caretLocation = command.targetRange.location + (command.replacementText as NSString).length
            await collapseSelection(
                NSRange(location: caretLocation, length: 0),
                in: context,
                reason: "replacement-complete"
            )
        } catch {
            SyntheticInputReset.releaseAllModifiersAndMouseButtons(reason: "replacement-execute-failed")
            let caretLocation = min(
                max(command.targetRange.location, 0),
                (context.fullText as NSString).length
            )
            await collapseSelection(
                NSRange(location: caretLocation, length: 0),
                in: context,
                reason: "replacement-failed"
            )
            throw error
        }
    }

    func typeText(_ text: String, in context: FocusedTextContext? = nil) throws {
        if let context {
            _ = accessibilityService.setFocused(context.element)
        }
        try typeReplacement(text)
    }

    func executeWordRangeReplacement(
        command: ReplaceCommand,
        in context: FocusedTextContext
    ) async throws {
        try await prepareTargetRange(command.targetRange, in: context, phase: "wordAutomation")
        try runWordRangeAutomation(command: command)
        let caretLocation = command.targetRange.location + (command.replacementText as NSString).length
        await collapseSelection(
            NSRange(location: caretLocation, length: 0),
            in: context,
            reason: "word-automation-complete"
        )
    }

    private func prepareTargetRange(
        _ range: NSRange,
        in context: FocusedTextContext,
        phase: String
    ) async throws {
        let activated = context.application.activate(options: [.activateIgnoringOtherApps])
        var raisedWindow = false
        var focusedWindow = false
        var mainWindow = false
        if let window = context.window {
            raisedWindow = accessibilityService.raise(window)
            focusedWindow = accessibilityService.setFocusedWindow(window, for: context.application)
            mainWindow = accessibilityService.setMainWindow(window, for: context.application)
        }
        try? await Task.sleep(nanoseconds: 90_000_000)
        let focused = accessibilityService.setFocused(context.element)
        try? await Task.sleep(nanoseconds: 45_000_000)
        let selected = accessibilityService.setSelectedRange(range, on: context.element)
        DebugLogger.log(
            "replacement prepare phase=\(phase) target=\(range.location):\(range.length) " +
                "activated=\(activated) raisedWindow=\(raisedWindow) focusedWindow=\(focusedWindow) " +
                "mainWindow=\(mainWindow) focused=\(focused) selected=\(selected)"
        )
        guard selected else {
            throw ReplacementError.unableToSelectRange
        }
        try? await Task.sleep(nanoseconds: 45_000_000)
    }

    private func collapseSelection(
        _ range: NSRange,
        in context: FocusedTextContext,
        reason: String
    ) async {
        _ = context.application.activate(options: [.activateIgnoringOtherApps])
        if let window = context.window {
            _ = accessibilityService.raise(window)
            _ = accessibilityService.setFocusedWindow(window, for: context.application)
            _ = accessibilityService.setMainWindow(window, for: context.application)
        }
        try? await Task.sleep(nanoseconds: 45_000_000)
        let focused = accessibilityService.setFocused(context.element)
        let selected = accessibilityService.setSelectedRange(range, on: context.element)
        DebugLogger.log(
            "replacement collapse reason=\(reason) range=\(range.location):\(range.length) " +
                "focused=\(focused) selected=\(selected)"
        )
    }

    private func pasteReplacement(
        _ replacement: String,
        restoreDelayNanoseconds: UInt64 = 150_000_000
    ) async throws {
        let session = ClipboardSession(client: pasteboardClient)
        session.writeTemporary(replacement)
        guard simulateCommandKeyPress(keyCode: 9) else {
            session.restore()
            SyntheticInputReset.releaseAllModifiersAndMouseButtons(reason: "paste-failed")
            throw ReplacementError.unableToSimulatePaste
        }
        try? await Task.sleep(nanoseconds: restoreDelayNanoseconds)
        session.restore()
        SyntheticInputReset.releaseAllModifiersAndMouseButtons(reason: "paste-complete")
    }

    private func pasteboardRestoreDelay(for context: FocusedTextContext) -> UInt64 {
        if context.application.bundleIdentifier == "com.microsoft.Word" {
            // Word consumes NSPasteboard contents asynchronously after Cmd+V.
            // Restoring the user's clipboard too quickly makes Word leave only
            // the selected range/caret changed, while AXValue remains unchanged.
            return 1_000_000_000
        }
        return 150_000_000
    }

    private func runWordRangeAutomation(command: ReplaceCommand) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            """
            on run argv
                set startIndex to (item 1 of argv) as integer
                set endIndex to (item 2 of argv) as integer
                set replacementText to item 3 of argv
                tell application "Microsoft Word"
                    set targetRange to create range active document start startIndex end endIndex
                    set content of targetRange to replacementText
                end tell
            end run
            """,
            String(command.targetRange.location),
            String(NSMaxRange(command.targetRange)),
            command.replacementText,
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ReplacementError.unableToRunWordAutomation(error.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ReplacementError.unableToRunWordAutomation(message?.isEmpty == false ? message! : "osascript exited with status \(process.terminationStatus)")
        }
        DebugLogger.log(
            "replacement wordAutomation target=\(command.targetRange.location):\(command.targetRange.length)"
        )
    }

    private func typeReplacement(_ replacement: String) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ReplacementError.unableToType
        }
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        down?.keyboardSetUnicodeString(stringLength: replacement.utf16.count, unicodeString: Array(replacement.utf16))
        up?.keyboardSetUnicodeString(stringLength: replacement.utf16.count, unicodeString: Array(replacement.utf16))
        down?.flags = []
        up?.flags = []
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        SyntheticInputReset.releaseAllModifiersAndMouseButtons(reason: "type-complete")
    }

    private func simulateCommandKeyPress(keyCode: CGKeyCode) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        SyntheticInputReset.releaseAllModifiersAndMouseButtons(reason: "shortcut-before")
        let commandKey: CGKeyCode = 55
        guard let commandDown = CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: true),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: false),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            SyntheticInputReset.releaseAllModifiersAndMouseButtons(reason: "shortcut-create-failed")
            return false
        }
        commandDown.flags = .maskCommand
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        commandUp.flags = []
        commandDown.post(tap: .cghidEventTap)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        commandUp.post(tap: .cghidEventTap)
        SyntheticInputReset.releaseAllModifiersAndMouseButtons(reason: "shortcut-after")
        return true
    }
}

enum SyntheticInputReset {
    private static let modifierKeyCodes: [CGKeyCode] = [
        55, // left command
        54, // right command
        56, // left shift
        60, // right shift
        58, // left option
        61, // right option
        59, // left control
        62, // right control
        57, // caps lock key-up only; does not toggle state
        63, // fn
    ]

    @discardableResult
    static func releaseAllModifiersAndMouseButtons(reason: String) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        for keyCode in modifierKeyCodes {
            guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
                continue
            }
            keyUp.flags = []
            keyUp.post(tap: .cghidEventTap)
        }

        let location = CGEvent(source: nil)?.location ?? .zero
        let mouseUps: [(CGEventType, CGMouseButton)] = [
            (.leftMouseUp, .left),
            (.rightMouseUp, .right),
            (.otherMouseUp, .center),
        ]
        for (eventType, button) in mouseUps {
            guard let event = CGEvent(
                mouseEventSource: source,
                mouseType: eventType,
                mouseCursorPosition: location,
                mouseButton: button
            ) else {
                continue
            }
            event.flags = []
            event.post(tap: .cghidEventTap)
        }

        let flags = CGEventSource.flagsState(.combinedSessionState)
        let commandStuck = flags.contains(.maskCommand)
        DebugLogger.log(
            "synthetic input reset reason=\(reason) flags=\(String(flags.rawValue, radix: 16)) command=\(commandStuck)"
        )
        return true
    }
}

import Foundation

public struct ReplacementCapabilities: Equatable {
    public var supportsNativePaste: Bool
    public var supportsAXSelectedText: Bool
    public var supportsTypingFallback: Bool

    public init(
        supportsNativePaste: Bool = true,
        supportsAXSelectedText: Bool = true,
        supportsTypingFallback: Bool = true
    ) {
        self.supportsNativePaste = supportsNativePaste
        self.supportsAXSelectedText = supportsAXSelectedText
        self.supportsTypingFallback = supportsTypingFallback
    }
}

public enum ReplacementPlanner {
    public static func strategies(for capabilities: ReplacementCapabilities) -> [ReplaceStrategy] {
        var strategies: [ReplaceStrategy] = []
        if capabilities.supportsNativePaste { strategies.append(.nativePaste) }
        if capabilities.supportsAXSelectedText { strategies.append(.axSelectedText) }
        if capabilities.supportsTypingFallback { strategies.append(.typingFallback) }
        return strategies
    }

    public static func makeCommand(
        suggestion: Suggestion,
        snapshot: TextSnapshot,
        strategy: ReplaceStrategy
    ) -> ReplaceCommand {
        ReplaceCommand(
            targetRange: suggestion.rangeInFullText,
            expectedOriginalText: suggestion.originalText,
            replacementText: suggestion.replacementText,
            strategy: strategy,
            snapshotRevision: snapshot.revision
        )
    }

    public static func validate(
        command: ReplaceCommand,
        currentText: String,
        currentRevision: UUID
    ) -> Bool {
        guard command.snapshotRevision == currentRevision else { return false }
        let nsText = currentText as NSString
        guard NSMaxRange(command.targetRange) <= nsText.length else { return false }
        let currentOriginal = nsText.substring(with: command.targetRange)
        return currentOriginal == command.expectedOriginalText
    }
}

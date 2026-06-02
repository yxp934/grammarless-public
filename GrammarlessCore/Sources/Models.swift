import CoreGraphics
import Foundation

public enum DetectedLanguage: String, Codable, CaseIterable {
    case en
    case zh
    case mixed
}

public enum SuggestionKind: String, Codable, CaseIterable {
    case spelling
    case grammar
    case rewrite
}

public enum SuggestionSource: String, Codable {
    case local
    case llm
}

public enum ProofIssueKind: String, Codable, CaseIterable {
    case spelling
    case wordChoice
    case confusableWord
    case visualSimilarChar
    case phoneticSimilarChar
    case grammarSelection
    case grammarRedundant
    case grammarMissing
    case grammarDisorder
    case punctuation
    case date
    case amount
    case properNoun
    case duplicateDefinition
    case sequenceNumber
    case leaderTitle
    case adminDivision
    case styleRedundancy
}

public enum ProofIssueSeverity: String, Codable, Comparable {
    case info
    case warning
    case critical

    private var rank: Int {
        switch self {
        case .info:
            return 0
        case .warning:
            return 1
        case .critical:
            return 2
        }
    }

    public static func < (lhs: ProofIssueSeverity, rhs: ProofIssueSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

public enum ReviewAction: String, Codable, CaseIterable, Identifiable {
    case formal
    case clarity
    case shorten
    case natural

    public var id: String { rawValue }
}

public enum RewriteDiffOperation: String, Codable, Equatable {
    case equal
    case deletion
    case insertion
}

public struct RewriteDiffSegment: Equatable, Codable {
    public var operation: RewriteDiffOperation
    public var text: String

    public init(operation: RewriteDiffOperation, text: String) {
        self.operation = operation
        self.text = text
    }
}

public enum RewriteDiff {
    public static func mergedSegments(original: String, revised: String) -> [RewriteDiffSegment] {
        guard original != revised else {
            return original.isEmpty ? [] : [RewriteDiffSegment(operation: .equal, text: original)]
        }

        let originalTokens = tokenize(original)
        let revisedTokens = tokenize(revised)
        guard !originalTokens.isEmpty || !revisedTokens.isEmpty else { return [] }
        guard originalTokens.count * revisedTokens.count <= 120_000 else {
            return mergeAdjacent([
                RewriteDiffSegment(operation: .deletion, text: original),
                RewriteDiffSegment(operation: .insertion, text: revised),
            ])
        }

        return mergeAdjacent(refineChangedRuns(tokenLevelSegments(originalTokens: originalTokens, revisedTokens: revisedTokens)))
    }

    private static func tokenLevelSegments(originalTokens: [String], revisedTokens: [String]) -> [RewriteDiffSegment] {
        let rows = originalTokens.count + 1
        let columns = revisedTokens.count + 1
        var table = Array(repeating: Array(repeating: 0, count: columns), count: rows)

        if !originalTokens.isEmpty, !revisedTokens.isEmpty {
            for i in stride(from: originalTokens.count - 1, through: 0, by: -1) {
                for j in stride(from: revisedTokens.count - 1, through: 0, by: -1) {
                    if originalTokens[i] == revisedTokens[j] {
                        table[i][j] = table[i + 1][j + 1] + 1
                    } else {
                        table[i][j] = max(table[i + 1][j], table[i][j + 1])
                    }
                }
            }
        }

        var segments: [RewriteDiffSegment] = []
        var i = 0
        var j = 0
        while i < originalTokens.count, j < revisedTokens.count {
            if originalTokens[i] == revisedTokens[j] {
                segments.append(RewriteDiffSegment(operation: .equal, text: originalTokens[i]))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                segments.append(RewriteDiffSegment(operation: .deletion, text: originalTokens[i]))
                i += 1
            } else {
                segments.append(RewriteDiffSegment(operation: .insertion, text: revisedTokens[j]))
                j += 1
            }
        }
        while i < originalTokens.count {
            segments.append(RewriteDiffSegment(operation: .deletion, text: originalTokens[i]))
            i += 1
        }
        while j < revisedTokens.count {
            segments.append(RewriteDiffSegment(operation: .insertion, text: revisedTokens[j]))
            j += 1
        }

        return mergeAdjacent(segments)
    }

    private static func refineChangedRuns(_ segments: [RewriteDiffSegment]) -> [RewriteDiffSegment] {
        let merged = mergeAdjacent(segments)
        var refined: [RewriteDiffSegment] = []
        var index = 0

        while index < merged.count {
            let segment = merged[index]
            if segment.operation == .equal {
                refined.append(segment)
                index += 1
                continue
            }

            var deletedText = ""
            var insertedText = ""
            var cursor = index
            while cursor < merged.count, merged[cursor].operation != .equal {
                switch merged[cursor].operation {
                case .equal:
                    break
                case .deletion:
                    deletedText += merged[cursor].text
                case .insertion:
                    insertedText += merged[cursor].text
                }
                cursor += 1
            }

            if !deletedText.isEmpty, !insertedText.isEmpty {
                refined.append(contentsOf: characterLevelSegments(original: deletedText, revised: insertedText))
            } else {
                if !deletedText.isEmpty {
                    refined.append(RewriteDiffSegment(operation: .deletion, text: deletedText))
                }
                if !insertedText.isEmpty {
                    refined.append(RewriteDiffSegment(operation: .insertion, text: insertedText))
                }
            }
            index = cursor
        }

        return mergeAdjacent(refined)
    }

    private static func characterLevelSegments(original: String, revised: String) -> [RewriteDiffSegment] {
        guard original != revised else {
            return original.isEmpty ? [] : [RewriteDiffSegment(operation: .equal, text: original)]
        }

        let originalCharacters = Array(original)
        let revisedCharacters = Array(revised)
        guard !originalCharacters.isEmpty || !revisedCharacters.isEmpty else { return [] }
        guard !originalCharacters.isEmpty else {
            return [RewriteDiffSegment(operation: .insertion, text: revised)]
        }
        guard !revisedCharacters.isEmpty else {
            return [RewriteDiffSegment(operation: .deletion, text: original)]
        }
        guard originalCharacters.count * revisedCharacters.count <= 160_000 else {
            return [
                RewriteDiffSegment(operation: .deletion, text: original),
                RewriteDiffSegment(operation: .insertion, text: revised),
            ]
        }

        let rows = originalCharacters.count + 1
        let columns = revisedCharacters.count + 1
        var table = Array(repeating: Array(repeating: 0, count: columns), count: rows)

        for i in stride(from: originalCharacters.count - 1, through: 0, by: -1) {
            for j in stride(from: revisedCharacters.count - 1, through: 0, by: -1) {
                if originalCharacters[i] == revisedCharacters[j] {
                    table[i][j] = table[i + 1][j + 1] + 1
                } else {
                    table[i][j] = max(table[i + 1][j], table[i][j + 1])
                }
            }
        }

        let lcsLength = table[0][0]
        guard shouldUseCharacterDiff(
            original: original,
            revised: revised,
            originalCount: originalCharacters.count,
            revisedCount: revisedCharacters.count,
            lcsLength: lcsLength
        ) else {
            return [
                RewriteDiffSegment(operation: .deletion, text: original),
                RewriteDiffSegment(operation: .insertion, text: revised),
            ]
        }

        var segments: [RewriteDiffSegment] = []
        var i = 0
        var j = 0
        while i < originalCharacters.count, j < revisedCharacters.count {
            if originalCharacters[i] == revisedCharacters[j] {
                segments.append(RewriteDiffSegment(operation: .equal, text: String(originalCharacters[i])))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                segments.append(RewriteDiffSegment(operation: .deletion, text: String(originalCharacters[i])))
                i += 1
            } else {
                segments.append(RewriteDiffSegment(operation: .insertion, text: String(revisedCharacters[j])))
                j += 1
            }
        }
        while i < originalCharacters.count {
            segments.append(RewriteDiffSegment(operation: .deletion, text: String(originalCharacters[i])))
            i += 1
        }
        while j < revisedCharacters.count {
            segments.append(RewriteDiffSegment(operation: .insertion, text: String(revisedCharacters[j])))
            j += 1
        }

        return mergeAdjacent(segments)
    }

    private static func shouldUseCharacterDiff(
        original: String,
        revised: String,
        originalCount: Int,
        revisedCount: Int,
        lcsLength: Int
    ) -> Bool {
        guard lcsLength > 0 else { return false }
        if containsCJK(original) || containsCJK(revised) {
            return true
        }

        let minCount = max(1, min(originalCount, revisedCount))
        let maxCount = max(originalCount, revisedCount)
        let minRatio = Double(lcsLength) / Double(minCount)
        let maxRatio = Double(lcsLength) / Double(max(1, maxCount))
        let compactEdit = !original.contains(where: { $0.isWhitespace }) && !revised.contains(where: { $0.isWhitespace })

        if compactEdit {
            return lcsLength >= 2 && minRatio >= 0.45
        }

        return lcsLength >= 3 && minRatio >= 0.35 && maxRatio >= 0.20
    }

    private enum TokenKind: Equatable {
        case whitespace
        case latinWord
        case number
        case cjk
        case punctuation
    }

    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var currentKind: TokenKind?

        func flush() {
            guard !current.isEmpty else { return }
            tokens.append(current)
            current = ""
            currentKind = nil
        }

        for scalar in text.unicodeScalars {
            let kind = tokenKind(for: scalar)
            let scalarText = String(Character(scalar))
            if kind == .cjk || kind == .punctuation {
                flush()
                tokens.append(scalarText)
                continue
            }
            if currentKind == kind {
                current += scalarText
            } else {
                flush()
                current = scalarText
                currentKind = kind
            }
        }
        flush()
        return tokens
    }

    private static func tokenKind(for scalar: UnicodeScalar) -> TokenKind {
        if CharacterSet.whitespacesAndNewlines.contains(scalar) {
            return .whitespace
        }
        if CharacterSet.decimalDigits.contains(scalar) {
            return .number
        }
        if CharacterSet.letters.contains(scalar) || scalar.value == 39 {
            if isCJK(scalar) {
                return .cjk
            }
            return .latinWord
        }
        if isCJK(scalar) {
            return .cjk
        }
        return .punctuation
    }

    private static func isCJK(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xF900 ... 0xFAFF:
            return true
        default:
            return false
        }
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isCJK)
    }

    private static func mergeAdjacent(_ segments: [RewriteDiffSegment]) -> [RewriteDiffSegment] {
        var merged: [RewriteDiffSegment] = []
        for segment in segments where !segment.text.isEmpty {
            if let last = merged.last, last.operation == segment.operation {
                merged[merged.count - 1].text += segment.text
            } else {
                merged.append(segment)
            }
        }
        return merged
    }
}

public struct TextSnapshot: Equatable {
    public var appBundleId: String
    public var elementIdentity: String
    public var fullText: String
    public var selectedRange: NSRange
    public var analysisText: String
    public var analysisRangeInFullText: NSRange
    public var elementBounds: CGRect
    public var revision: UUID
    public var languageHint: DetectedLanguage

    public init(
        appBundleId: String,
        elementIdentity: String,
        fullText: String,
        selectedRange: NSRange,
        analysisText: String,
        analysisRangeInFullText: NSRange,
        elementBounds: CGRect,
        revision: UUID,
        languageHint: DetectedLanguage
    ) {
        self.appBundleId = appBundleId
        self.elementIdentity = elementIdentity
        self.fullText = fullText
        self.selectedRange = selectedRange
        self.analysisText = analysisText
        self.analysisRangeInFullText = analysisRangeInFullText
        self.elementBounds = elementBounds
        self.revision = revision
        self.languageHint = languageHint
    }
}

public extension TextSnapshot {
    var paragraphIdentity: String {
        "\(analysisRangeInFullText.location):\(analysisRangeInFullText.length)"
    }

    var hasCollapsedCaretAtDocumentEnd: Bool {
        selectedRange.length == 0 &&
            selectedRange.location == (fullText as NSString).length
    }
}

public struct Suggestion: Identifiable, Equatable, Codable {
    public var id: UUID
    public var kind: SuggestionKind
    public var source: SuggestionSource
    public var rangeInFullText: NSRange
    public var originalText: String
    public var replacementText: String
    public var explanation: String
    public var paragraphIdentity: String
    public var proofIssueKind: ProofIssueKind?
    public var proofIssueSeverity: ProofIssueSeverity?
    public var proofIssueConfidence: Double?
    public var proofIssueDetectorSource: String?
    public var proofIssueAdvancedTip: String?
    public var proofIssueAutofixSafe: Bool?

    public init(
        id: UUID = UUID(),
        kind: SuggestionKind,
        source: SuggestionSource,
        rangeInFullText: NSRange,
        originalText: String,
        replacementText: String,
        explanation: String,
        paragraphIdentity: String,
        proofIssueKind: ProofIssueKind? = nil,
        proofIssueSeverity: ProofIssueSeverity? = nil,
        proofIssueConfidence: Double? = nil,
        proofIssueDetectorSource: String? = nil,
        proofIssueAdvancedTip: String? = nil,
        proofIssueAutofixSafe: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.rangeInFullText = rangeInFullText
        self.originalText = originalText
        self.replacementText = replacementText
        self.explanation = explanation
        self.paragraphIdentity = paragraphIdentity
        self.proofIssueKind = proofIssueKind
        self.proofIssueSeverity = proofIssueSeverity
        self.proofIssueConfidence = proofIssueConfidence
        self.proofIssueDetectorSource = proofIssueDetectorSource
        self.proofIssueAdvancedTip = proofIssueAdvancedTip
        self.proofIssueAutofixSafe = proofIssueAutofixSafe
    }
}

public struct ProofIssue: Identifiable, Equatable, Codable {
    public var id: UUID
    public var kind: ProofIssueKind
    public var severity: ProofIssueSeverity
    public var rangeInFullText: NSRange
    public var sourceText: String
    public var replacementText: String?
    public var confidence: Double
    public var detectorSource: String
    public var explanation: String
    public var advancedTip: String?
    public var autofixSafe: Bool
    public var evidence: [String: String]

    public init(
        id: UUID = UUID(),
        kind: ProofIssueKind,
        severity: ProofIssueSeverity,
        rangeInFullText: NSRange,
        sourceText: String,
        replacementText: String?,
        confidence: Double,
        detectorSource: String,
        explanation: String,
        advancedTip: String? = nil,
        autofixSafe: Bool,
        evidence: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.rangeInFullText = rangeInFullText
        self.sourceText = sourceText
        self.replacementText = replacementText
        self.confidence = confidence
        self.detectorSource = detectorSource
        self.explanation = explanation
        self.advancedTip = advancedTip
        self.autofixSafe = autofixSafe
        self.evidence = evidence
    }
}

public struct SuggestionBatch: Equatable, Codable {
    public var snapshotRevision: UUID
    public var paragraphIdentity: String
    public var suggestions: [Suggestion]

    public init(snapshotRevision: UUID, paragraphIdentity: String, suggestions: [Suggestion]) {
        self.snapshotRevision = snapshotRevision
        self.paragraphIdentity = paragraphIdentity
        self.suggestions = suggestions
    }
}

public extension SuggestionBatch {
    func isReusable(for snapshot: TextSnapshot) -> Bool {
        snapshotRevision == snapshot.revision &&
            paragraphIdentity == snapshot.paragraphIdentity
    }
}

public enum ReplaceStrategy: String, CaseIterable {
    case nativePaste
    case axSelectedText
    case typingFallback
}

public struct ReplaceCommand: Equatable {
    public var targetRange: NSRange
    public var expectedOriginalText: String
    public var replacementText: String
    public var strategy: ReplaceStrategy
    public var snapshotRevision: UUID

    public init(
        targetRange: NSRange,
        expectedOriginalText: String,
        replacementText: String,
        strategy: ReplaceStrategy,
        snapshotRevision: UUID
    ) {
        self.targetRange = targetRange
        self.expectedOriginalText = expectedOriginalText
        self.replacementText = replacementText
        self.strategy = strategy
        self.snapshotRevision = snapshotRevision
    }
}

public struct AIActionRequest: Equatable {
    public var action: ReviewAction
    public var selectedText: String
    public var surroundingContext: String
    public var languageHint: DetectedLanguage

    public init(
        action: ReviewAction,
        selectedText: String,
        surroundingContext: String,
        languageHint: DetectedLanguage
    ) {
        self.action = action
        self.selectedText = selectedText
        self.surroundingContext = surroundingContext
        self.languageHint = languageHint
    }
}

public struct ReviewActionResult: Equatable {
    public var replacement: String
    public var explanation: String

    public init(replacement: String, explanation: String) {
        self.replacement = replacement
        self.explanation = explanation
    }
}

public enum LLMStatus: Equatable {
    case idle
    case running(String)
    case success(String)
    case failed(String)
}

public extension Suggestion {
    var stableIdentity: String {
        let proofKind = proofIssueKind?.rawValue ?? "none"
        return "\(kind.rawValue)|\(proofKind)|\(rangeInFullText.location)|\(rangeInFullText.length)|\(replacementText)"
    }

    var isNoOpReplacement: Bool {
        originalText == replacementText
    }
}

public extension ProofIssue {
    var isNoOpReplacement: Bool {
        guard let replacementText else { return false }
        return sourceText == replacementText
    }

    var needsLLMAdjudication: Bool {
        switch kind {
        case .confusableWord, .visualSimilarChar, .phoneticSimilarChar,
             .wordChoice, .grammarSelection, .grammarMissing,
             .grammarDisorder, .styleRedundancy:
            return confidence < 0.96
        case .spelling, .grammarRedundant, .punctuation, .date, .amount,
             .properNoun, .duplicateDefinition, .sequenceNumber,
             .leaderTitle, .adminDivision:
            return false
        }
    }

    func asSuggestion(paragraphIdentity: String) -> Suggestion? {
        guard let replacementText, !replacementText.isEmpty, replacementText != sourceText else {
            return nil
        }
        let suggestionKind: SuggestionKind
        switch kind {
        case .spelling, .visualSimilarChar, .phoneticSimilarChar:
            suggestionKind = .spelling
        case .wordChoice, .confusableWord, .styleRedundancy:
            suggestionKind = .rewrite
        case .grammarSelection, .grammarRedundant, .grammarMissing,
             .grammarDisorder, .punctuation, .date, .amount,
             .properNoun, .duplicateDefinition, .sequenceNumber,
             .leaderTitle, .adminDivision:
            suggestionKind = .grammar
        }

        var details = "[高级纠错: \(kind.rawValue)] \(explanation)"
        if let advancedTip, !advancedTip.isEmpty {
            details += "\n\(advancedTip)"
        }
        details += "\nconfidence=\(String(format: "%.2f", confidence)); source=\(detectorSource)"
        if !autofixSafe {
            details += "\n需要人工确认后再替换。"
        }

        return Suggestion(
            id: id,
            kind: suggestionKind,
            source: .local,
            rangeInFullText: rangeInFullText,
            originalText: sourceText,
            replacementText: replacementText,
            explanation: details,
            paragraphIdentity: paragraphIdentity,
            proofIssueKind: kind,
            proofIssueSeverity: severity,
            proofIssueConfidence: confidence,
            proofIssueDetectorSource: detectorSource,
            proofIssueAdvancedTip: advancedTip,
            proofIssueAutofixSafe: autofixSafe
        )
    }
}

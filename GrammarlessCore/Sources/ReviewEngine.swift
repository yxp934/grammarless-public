import AppKit
import Foundation

public final class ReviewEngine {
    private let llmClient: LLMReviewing
    private let spellChecker: NSSpellChecker
    private let proofreadingPipeline: ProofreadingPipeline
    private let englishWordRegex = try! NSRegularExpression(pattern: #"\b[A-Za-z][A-Za-z']*\b"#)

    public init(
        llmClient: LLMReviewing = LLMClient(),
        spellChecker: NSSpellChecker = .shared,
        proofreadingPipeline: ProofreadingPipeline = ProofreadingPipeline()
    ) {
        self.llmClient = llmClient
        self.spellChecker = spellChecker
        self.proofreadingPipeline = proofreadingPipeline
    }

    public func localSuggestions(for snapshot: TextSnapshot) -> SuggestionBatch {
        var suggestions: [Suggestion] = []
        let text = snapshot.analysisText
        let nsText = text as NSString
        let paragraphIdentity = "\(snapshot.analysisRangeInFullText.location):\(snapshot.analysisRangeInFullText.length)"
        guard nsText.length > 0 else {
            return SuggestionBatch(
                snapshotRevision: snapshot.revision,
                paragraphIdentity: paragraphIdentity,
                suggestions: []
            )
        }

        suggestions.append(contentsOf: proofreadingPipeline.suggestions(for: snapshot))

        if snapshot.languageHint != .zh {
            let spellDocumentTag = NSSpellChecker.uniqueSpellDocumentTag()
            suggestions.append(
                contentsOf: localEnglishSpellingSuggestions(
                    text: text,
                    nsText: nsText,
                    paragraphIdentity: paragraphIdentity,
                    analysisRangeInFullText: snapshot.analysisRangeInFullText,
                    spellDocumentTag: spellDocumentTag
                )
            )
        }

        return SuggestionBatch(
            snapshotRevision: snapshot.revision,
            paragraphIdentity: paragraphIdentity,
            suggestions: Self.sanitizedSuggestions(suggestions)
        )
    }

    private func localChineseSuggestions(
        text: String,
        nsText: NSString,
        paragraphIdentity: String,
        analysisRangeInFullText: NSRange
    ) -> [Suggestion] {
        let heuristics: [(pattern: String, kind: SuggestionKind, replacement: String, explanation: String)] = [
            (#"我门"#, .spelling, "我们", "“门”应为“们”。"),
            (#"尽快的去"#, .grammar, "尽快", "去掉多余“的去”。"),
            (#"一下下"#, .rewrite, "一下", "表达更简洁自然。")
        ]

        var suggestions: [Suggestion] = []
        var seenRanges = Set<String>()
        let fullRange = NSRange(location: 0, length: nsText.length)

        for heuristic in heuristics {
            guard let regex = try? NSRegularExpression(pattern: heuristic.pattern) else { continue }
            for match in regex.matches(in: text, range: fullRange) {
                let suggestionRange = match.range
                guard suggestionRange.location != NSNotFound, suggestionRange.length > 0 else { continue }

                let key = "\(suggestionRange.location):\(suggestionRange.length)"
                guard seenRanges.insert(key).inserted else { continue }

                let original = nsText.substring(with: suggestionRange)
                let fullTextRange = ParagraphContextExtractor.mapAnalysisRangeToFullText(
                    analysisRange: suggestionRange,
                    analysisRangeInFullText: analysisRangeInFullText
                )
                suggestions.append(
                    Suggestion(
                        kind: heuristic.kind,
                        source: .local,
                        rangeInFullText: fullTextRange,
                        originalText: original,
                        replacementText: heuristic.replacement,
                        explanation: heuristic.explanation,
                        paragraphIdentity: paragraphIdentity
                    )
                )
            }
        }

        return Self.sortedSuggestions(suggestions)
    }

    private func localEnglishSpellingSuggestions(
        text: String,
        nsText: NSString,
        paragraphIdentity: String,
        analysisRangeInFullText: NSRange,
        spellDocumentTag: Int
    ) -> [Suggestion] {
        englishWordRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap { match in
            let word = nsText.substring(with: match.range)
            let isolatedWordMisspelling = spellChecker.checkSpelling(
                of: word,
                startingAt: 0,
                language: "en",
                wrap: false,
                inSpellDocumentWithTag: spellDocumentTag,
                wordCount: nil
            )
            guard isolatedWordMisspelling.location != NSNotFound else { return nil }

            let guesses = spellChecker.guesses(
                forWordRange: match.range,
                in: text,
                language: "en",
                inSpellDocumentWithTag: spellDocumentTag
            ) ?? []
            let replacement = guesses.first(where: { $0 != word }) ?? word
            let fullRange = ParagraphContextExtractor.mapAnalysisRangeToFullText(
                analysisRange: match.range,
                analysisRangeInFullText: analysisRangeInFullText
            )

            return Suggestion(
                kind: .spelling,
                source: .local,
                rangeInFullText: fullRange,
                originalText: word,
                replacementText: replacement,
                explanation: "Possible spelling issue.",
                paragraphIdentity: paragraphIdentity,
                proofIssueKind: .spelling,
                proofIssueSeverity: .warning,
                proofIssueConfidence: 0.95,
                proofIssueDetectorSource: "nsspellchecker",
                proofIssueAdvancedTip: "英文拼写由系统拼写检查器召回，候选按系统词典排序。",
                proofIssueAutofixSafe: false
            )
        }
    }

    private func localEnglishGrammarSuggestions(
        text: String,
        nsText: NSString,
        paragraphIdentity: String,
        analysisRangeInFullText: NSRange
    ) -> [Suggestion] {
        let heuristics: [(pattern: String, replacement: String, explanation: String)] = [
            (#"(?i)\b(?:he|she|it)\s+(do not knows)\b"#, "does not know", "Use singular agreement here."),
            (#"(?i)\b(?:he|she|it)\s+(do not know)\b"#, "does not know", "Use singular agreement here."),
            (#"(?i)\b(?:he|she|it)\s+(don't knows)\b"#, "doesn't know", "Use singular agreement here."),
            (#"(?i)\b(does not knows)\b"#, "does not know", "Use the base verb after does not."),
            (#"(?i)\b(do not knows)\b"#, "do not know", "Use the base verb after do not.")
        ]

        var suggestions: [Suggestion] = []
        var seenRanges = Set<String>()
        let fullRange = NSRange(location: 0, length: nsText.length)

        for heuristic in heuristics {
            guard let regex = try? NSRegularExpression(pattern: heuristic.pattern) else { continue }
            for match in regex.matches(in: text, range: fullRange) {
                let suggestionRange = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
                guard suggestionRange.location != NSNotFound, suggestionRange.length > 0 else { continue }

                let key = "\(suggestionRange.location):\(suggestionRange.length)"
                guard seenRanges.insert(key).inserted else { continue }

                let original = nsText.substring(with: suggestionRange)
                let fullTextRange = ParagraphContextExtractor.mapAnalysisRangeToFullText(
                    analysisRange: suggestionRange,
                    analysisRangeInFullText: analysisRangeInFullText
                )
                suggestions.append(
                    Suggestion(
                        kind: .grammar,
                        source: .local,
                        rangeInFullText: fullTextRange,
                        originalText: original,
                        replacementText: heuristic.replacement,
                        explanation: heuristic.explanation,
                        paragraphIdentity: paragraphIdentity
                    )
                )
            }
        }

        return suggestions
    }

    public func remoteSuggestions(
        for snapshot: TextSnapshot,
        configuration: AppConfiguration
    ) async throws -> SuggestionBatch {
        try await llmClient.review(snapshot: snapshot, configuration: configuration)
    }

    public func shouldRunRemoteReview(for snapshot: TextSnapshot) -> Bool {
        !snapshot.analysisText.containsCJK
    }

    public func offlineChineseSuggestions(
        for snapshot: TextSnapshot,
        configuration: AppConfiguration = AppConfiguration()
    ) async throws -> SuggestionBatch {
        guard configuration.uiLanguage != .en,
              snapshot.languageHint != .en,
              snapshot.analysisText.containsCJK else {
            return SuggestionBatch(
                snapshotRevision: snapshot.revision,
                paragraphIdentity: snapshot.paragraphIdentity,
                suggestions: []
            )
        }

        return SuggestionBatch(
            snapshotRevision: snapshot.revision,
            paragraphIdentity: snapshot.paragraphIdentity,
            suggestions: localSuggestions(for: snapshot).suggestions
        )
    }

    public func adjudicateRedSuggestions(
        for snapshot: TextSnapshot,
        suggestions: [Suggestion],
        configuration: AppConfiguration
    ) async throws -> SuggestionBatch {
        let redCandidates = Self.sortedSuggestions(suggestions.filter { $0.kind == .spelling })
        guard !redCandidates.isEmpty else {
            return SuggestionBatch(
                snapshotRevision: snapshot.revision,
                paragraphIdentity: snapshot.paragraphIdentity,
                suggestions: []
            )
        }

        let content = try await llmClient.performImpactStep(
            systemPrompt: redAdjudicationSystemPrompt(),
            userPrompt: redAdjudicationUserPrompt(snapshot: snapshot, candidates: redCandidates),
            configuration: configuration,
            timeout: configuration.reviewTimeoutSeconds
        )
        let parsed = try ReviewParsing.parseRedSuggestionBatch(
            content: content,
            snapshot: snapshot,
            candidates: redCandidates
        )
        return SuggestionBatch(
            snapshotRevision: snapshot.revision,
            paragraphIdentity: snapshot.paragraphIdentity,
            suggestions: Self.sanitizedSuggestions(parsed.suggestions)
        )
    }

    public func performAction(
        request: AIActionRequest,
        configuration: AppConfiguration
    ) async throws -> ReviewActionResult {
        try await llmClient.performAction(request: request, configuration: configuration)
    }

    public func performAgentAction(
        request: AgentActionRequest,
        configuration: AppConfiguration
    ) async throws -> AgentResponse {
        try await llmClient.performAgentAction(request: request, configuration: configuration)
    }

    public func performAgentToolLoop(
        request: AgentToolLoopRequest,
        configuration: AppConfiguration
    ) async throws -> AgentToolLoopResult {
        try await AgentToolLoop(llmClient: llmClient).run(request: request, configuration: configuration)
    }

    public func streamAgentFinalMessage(
        request: AgentFinalMessageRequest,
        configuration: AppConfiguration,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        try await llmClient.streamAgentFinalMessage(
            request: request,
            configuration: configuration,
            onDelta: onDelta
        )
    }

    public func analyzeImpact(
        snapshot: TextSnapshot,
        configuration: AppConfiguration,
        memoryContext: WritingMemoryContext,
        progressHandler: ImpactAnalysisProgressHandler? = nil
    ) async throws -> DocumentImpactReport {
        try await ImpactAnalysisOrchestrator(llmClient: llmClient).run(
            snapshot: snapshot,
            configuration: configuration,
            memoryContext: memoryContext,
            progressHandler: progressHandler
        )
    }

    public func requestGhostSuggestion(
        request: GhostSuggestionRequest,
        configuration: AppConfiguration
    ) async throws -> GhostSuggestion {
        try await llmClient.requestGhostSuggestion(request: request, configuration: configuration)
    }

    public static func merge(local: SuggestionBatch, remote: SuggestionBatch) -> SuggestionBatch {
        var seen = Set<String>()
        var merged: [Suggestion] = []
        var localRanges: [NSRange] = []

        for suggestion in sortedSuggestions(local.suggestions) {
            guard !suggestion.isNoOpReplacement else { continue }
            guard seen.insert(displayIdentity(suggestion)).inserted else { continue }
            merged.append(suggestion)
            localRanges.append(suggestion.rangeInFullText)
        }

        for suggestion in sortedSuggestions(remote.suggestions) {
            guard !suggestion.isNoOpReplacement else { continue }
            guard !localRanges.contains(where: { rangesOverlap($0, suggestion.rangeInFullText) }) else { continue }
            guard seen.insert(displayIdentity(suggestion)).inserted else { continue }
            merged.append(suggestion)
        }

        return SuggestionBatch(
            snapshotRevision: remote.snapshotRevision,
            paragraphIdentity: remote.paragraphIdentity,
            suggestions: sortedSuggestions(merged)
        )
    }

    public static func replacingRedSuggestions(in batch: SuggestionBatch, with redBatch: SuggestionBatch) -> SuggestionBatch {
        SuggestionBatch(
            snapshotRevision: batch.snapshotRevision,
            paragraphIdentity: batch.paragraphIdentity,
            suggestions: sanitizedSuggestions(
                batch.suggestions.filter { $0.kind != .spelling } + redBatch.suggestions
            )
        )
    }

    private struct RedAdjudicationCandidate: Encodable {
        let id: String
        let start: Int
        let end: Int
        let original: String
        let replacement: String
        let explanation: String
        let detector: String
        let confidence: Double?
    }

    private func redAdjudicationSystemPrompt() -> String {
        """
        You are Grammarless Red Judge. Return strict JSON only:
        {"operations":[{"op":"keep|update|delete|add","id":"","start":0,"end":0,"original":"","replacement":"","explanation":""}]}
        Rules:
        - Judge only red underline spelling/typo suggestions.
        - Use keep when an existing red suggestion is correct.
        - Use update when an existing red suggestion is correct but the replacement or explanation should change.
        - Use delete when an existing red suggestion is false positive or unsafe.
        - Use add only for clear spelling/typo red issues missing from the candidates.
        - For update/add, start/end are UTF-16 offsets in analysisText and end is exclusive.
        - Copy original exactly from analysisText[start..<end].
        - Do not create grammar or style suggestions here; those belong to yellow/blue review.
        - Never use markdown.
        """
    }

    private func redAdjudicationUserPrompt(snapshot: TextSnapshot, candidates: [Suggestion]) -> String {
        let candidatesJSON = redAdjudicationCandidatesJSON(snapshot: snapshot, candidates: candidates)
        return """
        languageHint: \(snapshot.languageHint.rawValue)
        analysisText:
        \(snapshot.analysisText)

        candidates:
        \(candidatesJSON)
        """
    }

    private func redAdjudicationCandidatesJSON(snapshot: TextSnapshot, candidates: [Suggestion]) -> String {
        let rows = candidates.compactMap { suggestion -> RedAdjudicationCandidate? in
            let start = suggestion.rangeInFullText.location - snapshot.analysisRangeInFullText.location
            guard start >= 0 else { return nil }
            let end = start + suggestion.rangeInFullText.length
            guard end <= (snapshot.analysisText as NSString).length else { return nil }
            return RedAdjudicationCandidate(
                id: suggestion.stableIdentity,
                start: start,
                end: end,
                original: suggestion.originalText,
                replacement: suggestion.replacementText,
                explanation: suggestion.explanation,
                detector: suggestion.proofIssueDetectorSource ?? suggestion.source.rawValue,
                confidence: suggestion.proofIssueConfidence
            )
        }
        guard let data = try? JSONEncoder().encode(rows),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    private static func sortedSuggestions(_ suggestions: [Suggestion]) -> [Suggestion] {
        suggestions.sorted(by: suggestionComesBefore(_:_:))
    }

    private static func sanitizedSuggestions(_ suggestions: [Suggestion]) -> [Suggestion] {
        var seen = Set<String>()
        return sortedSuggestions(suggestions.filter { suggestion in
            guard !suggestion.isNoOpReplacement else { return false }
            return seen.insert(displayIdentity(suggestion)).inserted
        })
    }

    private static func displayIdentity(_ suggestion: Suggestion) -> String {
        "\(suggestion.rangeInFullText.location)|\(suggestion.rangeInFullText.length)|\(suggestion.replacementText)"
    }

    private static func rangesOverlap(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        NSIntersectionRange(lhs, rhs).length > 0
    }

    private static func suggestionComesBefore(_ lhs: Suggestion, _ rhs: Suggestion) -> Bool {
        if lhs.rangeInFullText.location != rhs.rangeInFullText.location {
            return lhs.rangeInFullText.location < rhs.rangeInFullText.location
        }
        if lhs.rangeInFullText.length != rhs.rangeInFullText.length {
            return lhs.rangeInFullText.length < rhs.rangeInFullText.length
        }
        if lhs.kind != rhs.kind {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        if lhs.source != rhs.source {
            return sourcePriority(lhs.source) < sourcePriority(rhs.source)
        }
        if lhs.originalText != rhs.originalText {
            return lhs.originalText < rhs.originalText
        }
        if lhs.replacementText != rhs.replacementText {
            return lhs.replacementText < rhs.replacementText
        }
        return lhs.explanation < rhs.explanation
    }

    private static func sourcePriority(_ source: SuggestionSource) -> Int {
        switch source {
        case .local:
            return 0
        case .llm:
            return 1
        }
    }
}

private extension String {
    var containsCJK: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xF900 ... 0xFAFF:
                return true
            default:
                return false
            }
        }
    }
}

import Foundation

public enum ImpactDimension: String, Codable, CaseIterable, Identifiable {
    case purposeClarity
    case structureLogic
    case evidenceSufficiency
    case readerReaction
    case genreFit
    case languageClarity

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .purposeClarity: return "目的清晰度"
        case .structureLogic: return "结构逻辑"
        case .evidenceSufficiency: return "证据充分性"
        case .readerReaction: return "读者反应"
        case .genreFit: return "文体匹配"
        case .languageClarity: return "语言清晰度"
        }
    }
}

public enum ImpactSeverity: String, Codable, Equatable, CaseIterable {
    case critical
    case high
    case medium
    case low
}

public enum ImpactAnalysisPath: String, Codable, Equatable, CaseIterable {
    case segmentation
    case genreClassification
    case structureFormat
    case globalLogicEvidence
    case localLogicEvidence
    case readerReaction
    case languageClarity
    case reducer
}

public struct ImpactAnalysisProgress: Codable, Equatable {
    public var path: ImpactAnalysisPath
    public var completed: Int
    public var total: Int
    public var message: String

    public init(path: ImpactAnalysisPath, completed: Int, total: Int, message: String) {
        self.path = path
        self.completed = completed
        self.total = total
        self.message = message
    }
}

public typealias ImpactAnalysisProgressHandler = (ImpactAnalysisProgress) async -> Void

public struct ImpactAnalysisFailure: Codable, Equatable, Identifiable {
    public var id: String {
        [path.rawValue, segmentID ?? "document", message]
            .joined(separator: "|")
    }

    public var path: ImpactAnalysisPath
    public var segmentID: String?
    public var paragraphIDs: [String]
    public var message: String

    public init(
        path: ImpactAnalysisPath,
        segmentID: String? = nil,
        paragraphIDs: [String] = [],
        message: String
    ) {
        self.path = path
        self.segmentID = segmentID
        self.paragraphIDs = paragraphIDs
        self.message = message
    }
}

public enum ImpactParagraphKind: String, Codable, Equatable {
    case heading
    case body
    case list
    case quote
    case table
    case code
    case empty
}

public enum ImpactSegmentSource: String, Codable, Equatable {
    case paragraph
    case paragraphMerge
    case llmBoundary
    case fallbackBoundary
}

public struct ImpactParagraph: Codable, Equatable, Identifiable {
    public var id: String
    public var rangeInFullText: NSRange
    public var text: String
    public var kind: ImpactParagraphKind

    public init(id: String, rangeInFullText: NSRange, text: String, kind: ImpactParagraphKind) {
        self.id = id
        self.rangeInFullText = rangeInFullText
        self.text = text
        self.kind = kind
    }
}

public struct ImpactSegment: Codable, Equatable, Identifiable {
    public var id: String
    public var paragraphIDs: [String]
    public var rangeInFullText: NSRange
    public var text: String
    public var source: ImpactSegmentSource

    public init(
        id: String,
        paragraphIDs: [String],
        rangeInFullText: NSRange,
        text: String,
        source: ImpactSegmentSource
    ) {
        self.id = id
        self.paragraphIDs = paragraphIDs
        self.rangeInFullText = rangeInFullText
        self.text = text
        self.source = source
    }
}

public struct ImpactSegmentationResult: Codable, Equatable {
    public var documentLengthUTF16: Int
    public var paragraphs: [ImpactParagraph]
    public var segments: [ImpactSegment]
    public var usedGrammarAwareSegmentation: Bool
    public var didUseLLMBoundaries: Bool
    public var didFallbackHardSplit: Bool

    public init(
        documentLengthUTF16: Int,
        paragraphs: [ImpactParagraph],
        segments: [ImpactSegment],
        usedGrammarAwareSegmentation: Bool,
        didUseLLMBoundaries: Bool,
        didFallbackHardSplit: Bool
    ) {
        self.documentLengthUTF16 = documentLengthUTF16
        self.paragraphs = paragraphs
        self.segments = segments
        self.usedGrammarAwareSegmentation = usedGrammarAwareSegmentation
        self.didUseLLMBoundaries = didUseLLMBoundaries
        self.didFallbackHardSplit = didFallbackHardSplit
    }
}

public struct ImpactGenreRubric: Codable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var family: String
    public var languageRequirements: [String]
    public var formatRequirements: [String]
    public var dimensionPrompts: [ImpactDimension: String]

    public init(
        id: String,
        label: String,
        family: String,
        languageRequirements: [String],
        formatRequirements: [String],
        dimensionPrompts: [ImpactDimension: String]
    ) {
        self.id = id
        self.label = label
        self.family = family
        self.languageRequirements = languageRequirements
        self.formatRequirements = formatRequirements
        self.dimensionPrompts = dimensionPrompts
    }
}

public struct ImpactGenreClassification: Codable, Equatable {
    public var primaryGenreID: String
    public var secondaryGenreIDs: [String]
    public var genreConfidence: Double
    public var intent: String
    public var audience: String
    public var formality: String
    public var whyThisGenre: String
    public var formatSignals: [String]
    public var missingSignals: [String]

    public init(
        primaryGenreID: String,
        secondaryGenreIDs: [String] = [],
        genreConfidence: Double,
        intent: String,
        audience: String,
        formality: String,
        whyThisGenre: String,
        formatSignals: [String] = [],
        missingSignals: [String] = []
    ) {
        self.primaryGenreID = primaryGenreID
        self.secondaryGenreIDs = secondaryGenreIDs
        self.genreConfidence = genreConfidence
        self.intent = intent
        self.audience = audience
        self.formality = formality
        self.whyThisGenre = whyThisGenre
        self.formatSignals = formatSignals
        self.missingSignals = missingSignals
    }
}

public struct ImpactScore: Codable, Equatable, Identifiable {
    public var id: String { dimension.rawValue }
    public var dimension: ImpactDimension
    public var score: Int
    public var reason: String
    public var topFix: String
    public var confidence: Double

    public init(dimension: ImpactDimension, score: Int, reason: String, topFix: String, confidence: Double) {
        self.dimension = dimension
        self.score = score
        self.reason = reason
        self.topFix = topFix
        self.confidence = confidence
    }
}

public struct ImpactFinding: Codable, Equatable, Identifiable {
    public var id: UUID
    public var dimension: ImpactDimension
    public var severity: ImpactSeverity
    public var segmentIDs: [String]
    public var paragraphIDs: [String]
    public var title: String
    public var explanation: String
    public var evidence: String
    public var recommendation: String
    public var confidence: Double

    public init(
        id: UUID = UUID(),
        dimension: ImpactDimension,
        severity: ImpactSeverity,
        segmentIDs: [String],
        paragraphIDs: [String],
        title: String,
        explanation: String,
        evidence: String,
        recommendation: String,
        confidence: Double
    ) {
        self.id = id
        self.dimension = dimension
        self.severity = severity
        self.segmentIDs = segmentIDs
        self.paragraphIDs = paragraphIDs
        self.title = title
        self.explanation = explanation
        self.evidence = evidence
        self.recommendation = recommendation
        self.confidence = confidence
    }
}

public struct ImpactSegmentStructureResult: Codable, Equatable, Identifiable {
    public var id: String { segmentID }
    public var segmentID: String
    public var paragraphIDs: [String]
    public var localRole: String
    public var expectedRoleForGenre: String
    public var servesDocumentPurpose: Bool
    public var structureIssue: String
    public var formatIssue: String
    public var recommendedMove: String
}

public struct ImpactLocalLogicResult: Codable, Equatable, Identifiable {
    public var id: String { segmentID }
    public var segmentID: String
    public var mainClaim: String
    public var localEvidence: [String]
    public var logicGap: String
    public var overclaim: String
    public var internalContradiction: String
    public var evidenceStrength: String
    public var recommendedFix: String
}

public struct ImpactReaderReactionResult: Codable, Equatable, Identifiable {
    public var id: String { segmentID }
    public var segmentID: String
    public var likelyTakeaway: String
    public var likelyConfusion: String
    public var likelyObjection: String
    public var trustLevel: String
    public var nextActionClarity: String
    public var emotionalReaction: String
    public var recommendedFix: String
}

public struct ImpactLanguageClarityIssue: Codable, Equatable, Identifiable {
    public var id: UUID
    public var type: String
    public var severity: ImpactSeverity
    public var original: String
    public var replacement: String?
    public var explanation: String
    public var recommendation: String

    public init(
        id: UUID = UUID(),
        type: String,
        severity: ImpactSeverity,
        original: String,
        replacement: String? = nil,
        explanation: String,
        recommendation: String
    ) {
        self.id = id
        self.type = type
        self.severity = severity
        self.original = original
        self.replacement = replacement
        self.explanation = explanation
        self.recommendation = recommendation
    }
}

public struct ImpactLanguageClarityResult: Codable, Equatable, Identifiable {
    public var id: String { segmentID }
    public var segmentID: String
    public var clarityIssues: [ImpactLanguageClarityIssue]
    public var readabilityRisk: String
    public var styleFitRisk: String
    public var recommendedFix: String
}

public struct ImpactGlobalClaim: Codable, Equatable, Identifiable {
    public var id: String { claimID }
    public var claimID: String
    public var claim: String
    public var introducedIn: String
    public var supportedBy: [String]
    public var weakenedBy: [String]
    public var evidenceStrength: String
    public var gap: String
    public var readerQuestion: String
}

public struct ImpactGlobalLogicResult: Codable, Equatable {
    public var globalClaims: [ImpactGlobalClaim]
    public var crossParagraphGaps: [String]
    public var contradictions: [String]
    public var redundancies: [String]
    public var missingBridges: [String]
    public var globalLogicSummary: String

    public init(
        globalClaims: [ImpactGlobalClaim] = [],
        crossParagraphGaps: [String] = [],
        contradictions: [String] = [],
        redundancies: [String] = [],
        missingBridges: [String] = [],
        globalLogicSummary: String = ""
    ) {
        self.globalClaims = globalClaims
        self.crossParagraphGaps = crossParagraphGaps
        self.contradictions = contradictions
        self.redundancies = redundancies
        self.missingBridges = missingBridges
        self.globalLogicSummary = globalLogicSummary
    }
}

public struct DocumentImpactReport: Codable, Equatable {
    public var snapshotRevision: UUID
    public var documentLengthUTF16: Int
    public var segmentation: ImpactSegmentationResult
    public var genreClassification: ImpactGenreClassification
    public var primaryGenre: ImpactGenreRubric
    public var overallScore: Int
    public var oneSentenceDiagnosis: String
    public var executiveSummary: String
    public var scores: [ImpactScore]
    public var topFindings: [ImpactFinding]
    public var structureResults: [ImpactSegmentStructureResult]
    public var globalLogicResult: ImpactGlobalLogicResult
    public var localLogicResults: [ImpactLocalLogicResult]
    public var readerReactionResults: [ImpactReaderReactionResult]
    public var languageClarityResults: [ImpactLanguageClarityResult]
    public var quickWins: [String]
    public var deeperRevisions: [String]
    public var readerSummary: String
    public var structureSummary: String
    public var logicSummary: String
    public var doNotChange: [String]
    public var analysisFailures: [ImpactAnalysisFailure]
    public var patchCandidates: [TextPatch]

    public init(
        snapshotRevision: UUID,
        documentLengthUTF16: Int,
        segmentation: ImpactSegmentationResult,
        genreClassification: ImpactGenreClassification,
        primaryGenre: ImpactGenreRubric,
        overallScore: Int,
        oneSentenceDiagnosis: String,
        executiveSummary: String,
        scores: [ImpactScore],
        topFindings: [ImpactFinding],
        structureResults: [ImpactSegmentStructureResult],
        globalLogicResult: ImpactGlobalLogicResult,
        localLogicResults: [ImpactLocalLogicResult],
        readerReactionResults: [ImpactReaderReactionResult],
        languageClarityResults: [ImpactLanguageClarityResult],
        quickWins: [String],
        deeperRevisions: [String],
        readerSummary: String,
        structureSummary: String,
        logicSummary: String,
        doNotChange: [String],
        analysisFailures: [ImpactAnalysisFailure] = [],
        patchCandidates: [TextPatch]
    ) {
        self.snapshotRevision = snapshotRevision
        self.documentLengthUTF16 = documentLengthUTF16
        self.segmentation = segmentation
        self.genreClassification = genreClassification
        self.primaryGenre = primaryGenre
        self.overallScore = overallScore
        self.oneSentenceDiagnosis = oneSentenceDiagnosis
        self.executiveSummary = executiveSummary
        self.scores = scores
        self.topFindings = topFindings
        self.structureResults = structureResults
        self.globalLogicResult = globalLogicResult
        self.localLogicResults = localLogicResults
        self.readerReactionResults = readerReactionResults
        self.languageClarityResults = languageClarityResults
        self.quickWins = quickWins
        self.deeperRevisions = deeperRevisions
        self.readerSummary = readerSummary
        self.structureSummary = structureSummary
        self.logicSummary = logicSummary
        self.doNotChange = doNotChange
        self.analysisFailures = analysisFailures
        self.patchCandidates = patchCandidates
    }
}

public enum ImpactAnalysisError: LocalizedError, Equatable {
    case emptyDocument
    case unknownGenre(String)
    case invalidBoundaryCuts
    case partialAnalysisFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyDocument: return "当前文档没有可分析的文本。"
        case .unknownGenre(let id): return "未知文体：\(id)。"
        case .invalidBoundaryCuts: return "LLM 返回了无效切分点。"
        case .partialAnalysisFailed(let message): return "Impact analysis failed: \(message)"
        }
    }
}

public typealias ImpactBoundaryFinder = (_ windowText: String, _ windowStartInDocumentUTF16: Int) async throws -> [Int]

public final class ImpactDocumentSegmenter {
    public struct Configuration: Equatable {
        public var grammarAwareThresholdUTF16: Int
        public var minSegmentUTF16: Int
        public var maxSegmentUTF16: Int
        public var maxLLMWindowUTF16: Int

        public init(
            grammarAwareThresholdUTF16: Int = 1000,
            minSegmentUTF16: Int = 100,
            maxSegmentUTF16: Int = 1000,
            maxLLMWindowUTF16: Int = 10_000
        ) {
            self.grammarAwareThresholdUTF16 = grammarAwareThresholdUTF16
            self.minSegmentUTF16 = minSegmentUTF16
            self.maxSegmentUTF16 = maxSegmentUTF16
            self.maxLLMWindowUTF16 = maxLLMWindowUTF16
        }
    }

    private let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func segment(
        text: String,
        boundaryFinder: ImpactBoundaryFinder? = nil
    ) async throws -> ImpactSegmentationResult {
        let nsText = text as NSString
        guard nsText.length > 0 else { throw ImpactAnalysisError.emptyDocument }
        let paragraphs = extractParagraphs(text: text, nsText: nsText)
        guard !paragraphs.isEmpty else { throw ImpactAnalysisError.emptyDocument }

        let usedGrammarAware = nsText.length > configuration.grammarAwareThresholdUTF16
        let merged = usedGrammarAware ? mergeSmallParagraphs(paragraphs, nsText: nsText) : paragraphs.enumerated().map { index, paragraph in
            ImpactSegment(
                id: "s\(Self.paddedIndex(index + 1))",
                paragraphIDs: [paragraph.id],
                rangeInFullText: paragraph.rangeInFullText,
                text: paragraph.text,
                source: .paragraph
            )
        }

        var finalSegments: [ImpactSegment] = []
        var usedLLM = false
        var usedFallback = false
        for segment in merged {
            if (segment.text as NSString).length <= configuration.maxSegmentUTF16 {
                finalSegments.append(segment)
                continue
            }
            let split = try await splitLongSegment(segment, nsText: nsText, boundaryFinder: boundaryFinder)
            usedLLM = usedLLM || split.usedLLM
            usedFallback = usedFallback || split.usedFallback
            finalSegments.append(contentsOf: split.segments)
        }

        let reindexed = finalSegments.enumerated().map { index, segment in
            ImpactSegment(
                id: "s\(Self.paddedIndex(index + 1))",
                paragraphIDs: segment.paragraphIDs,
                rangeInFullText: segment.rangeInFullText,
                text: segment.text,
                source: segment.source
            )
        }

        return ImpactSegmentationResult(
            documentLengthUTF16: nsText.length,
            paragraphs: paragraphs,
            segments: reindexed,
            usedGrammarAwareSegmentation: usedGrammarAware,
            didUseLLMBoundaries: usedLLM,
            didFallbackHardSplit: usedFallback
        )
    }

    private func extractParagraphs(text: String, nsText: NSString) -> [ImpactParagraph] {
        var paragraphs: [ImpactParagraph] = []
        nsText.enumerateSubstrings(
            in: NSRange(location: 0, length: nsText.length),
            options: [.byParagraphs, .substringNotRequired]
        ) { _, substringRange, _, _ in
            guard substringRange.location != NSNotFound, substringRange.length > 0 else { return }
            let raw = nsText.substring(with: substringRange)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let index = paragraphs.count + 1
            paragraphs.append(
                ImpactParagraph(
                    id: "p\(Self.paddedIndex(index))",
                    rangeInFullText: substringRange,
                    text: raw,
                    kind: Self.kind(for: raw)
                )
            )
        }
        return paragraphs
    }

    private func mergeSmallParagraphs(_ paragraphs: [ImpactParagraph], nsText: NSString) -> [ImpactSegment] {
        var segments: [ImpactSegment] = []
        var index = 0
        while index < paragraphs.count {
            var ids = [paragraphs[index].id]
            var start = paragraphs[index].rangeInFullText.location
            var end = NSMaxRange(paragraphs[index].rangeInFullText)
            var length = end - start
            var source: ImpactSegmentSource = .paragraph

            if length < configuration.minSegmentUTF16 {
                source = .paragraphMerge
                if index + 1 < paragraphs.count {
                    repeat {
                        index += 1
                        ids.append(paragraphs[index].id)
                        end = NSMaxRange(paragraphs[index].rangeInFullText)
                        length = end - start
                    } while length < configuration.minSegmentUTF16 && index + 1 < paragraphs.count
                } else if let previous = segments.popLast() {
                    ids = previous.paragraphIDs + ids
                    start = previous.rangeInFullText.location
                    length = end - start
                    source = .paragraphMerge
                }
            }

            let range = NSRange(location: start, length: length)
            segments.append(
                ImpactSegment(
                    id: "s\(Self.paddedIndex(segments.count + 1))",
                    paragraphIDs: ids,
                    rangeInFullText: range,
                    text: nsText.substring(with: range),
                    source: source
                )
            )
            index += 1
        }
        return segments
    }

    private func splitLongSegment(
        _ segment: ImpactSegment,
        nsText: NSString,
        boundaryFinder: ImpactBoundaryFinder?
    ) async throws -> (segments: [ImpactSegment], usedLLM: Bool, usedFallback: Bool) {
        var output: [ImpactSegment] = []
        var usedLLM = false
        var usedFallback = false
        let segmentEnd = NSMaxRange(segment.rangeInFullText)
        var windowStart = segment.rangeInFullText.location

        while windowStart < segmentEnd {
            let windowLength = min(configuration.maxLLMWindowUTF16, segmentEnd - windowStart)
            let windowRange = NSRange(location: windowStart, length: windowLength)
            let windowText = nsText.substring(with: windowRange)
            let relativeCuts: [Int]
            var source: ImpactSegmentSource = .fallbackBoundary

            if let boundaryFinder {
                do {
                    let cuts = try await boundaryFinder(windowText, windowStart)
                    if Self.areValidCuts(cuts, in: windowText as NSString, maxSegmentLength: configuration.maxSegmentUTF16) {
                        relativeCuts = cuts
                        source = .llmBoundary
                        usedLLM = true
                    } else {
                        relativeCuts = fallbackCuts(in: windowText as NSString)
                        usedFallback = true
                    }
                } catch {
                    relativeCuts = fallbackCuts(in: windowText as NSString)
                    usedFallback = true
                }
            } else {
                relativeCuts = fallbackCuts(in: windowText as NSString)
                usedFallback = true
            }

            let absoluteRanges = ranges(from: relativeCuts, windowStart: windowStart, windowLength: windowLength)
            for range in absoluteRanges {
                output.append(
                    ImpactSegment(
                        id: "s\(Self.paddedIndex(output.count + 1))",
                        paragraphIDs: segment.paragraphIDs,
                        rangeInFullText: range,
                        text: nsText.substring(with: range),
                        source: source
                    )
                )
            }
            windowStart += windowLength
        }

        return (output, usedLLM, usedFallback)
    }

    private func ranges(from cuts: [Int], windowStart: Int, windowLength: Int) -> [NSRange] {
        var ranges: [NSRange] = []
        var previous = 0
        for cut in cuts + [windowLength] {
            guard cut > previous else { continue }
            ranges.append(NSRange(location: windowStart + previous, length: cut - previous))
            previous = cut
        }
        return ranges
    }

    private func fallbackCuts(in nsWindow: NSString) -> [Int] {
        var cuts: [Int] = []
        var cursor = 0
        while nsWindow.length - cursor > configuration.maxSegmentUTF16 {
            let limit = cursor + configuration.maxSegmentUTF16
            let boundary = nearestBoundary(in: nsWindow, from: cursor, hardLimit: limit)
            guard boundary > cursor else {
                let hard = min(limit, nsWindow.length)
                cuts.append(hard)
                cursor = hard
                continue
            }
            cuts.append(boundary)
            cursor = boundary
        }
        return cuts.filter { $0 > 0 && $0 < nsWindow.length }
    }

    private func nearestBoundary(in text: NSString, from cursor: Int, hardLimit: Int) -> Int {
        let lowerBound = cursor + min(300, max(1, hardLimit - cursor))
        guard hardLimit > cursor else { return cursor }
        let punctuation = CharacterSet(charactersIn: "。！？!?；;：:.\n")
        var index = min(hardLimit, text.length) - 1
        while index >= lowerBound {
            let char = text.substring(with: NSRange(location: index, length: 1)).unicodeScalars.first
            if let char, punctuation.contains(char) {
                return min(index + 1, text.length)
            }
            index -= 1
        }
        index = min(hardLimit, text.length) - 1
        while index >= lowerBound {
            let char = text.substring(with: NSRange(location: index, length: 1)).unicodeScalars.first
            if let char, CharacterSet.whitespacesAndNewlines.contains(char) {
                return min(index + 1, text.length)
            }
            index -= 1
        }
        return min(hardLimit, text.length)
    }

    private static func areValidCuts(_ cuts: [Int], in text: NSString, maxSegmentLength: Int) -> Bool {
        let totalLength = text.length
        guard cuts == cuts.sorted(), Set(cuts).count == cuts.count else { return false }
        var previous = 0
        for cut in cuts {
            guard cut > previous, cut < totalLength || cut == totalLength else { return false }
            guard cut - previous <= maxSegmentLength else { return false }
            guard isSafeCutBoundary(cut, in: text) else { return false }
            previous = cut
        }
        guard totalLength - previous <= maxSegmentLength else { return false }
        return true
    }

    private static func isSafeCutBoundary(_ cut: Int, in text: NSString) -> Bool {
        guard cut > 0, cut < text.length else { return false }
        let left = scalar(at: cut - 1, in: text)
        let right = scalar(at: cut, in: text)
        if let left, CharacterSet.whitespacesAndNewlines.contains(left) { return true }
        if let right, CharacterSet.whitespacesAndNewlines.contains(right) { return true }
        if let left, CharacterSet(charactersIn: "。！？!?；;：:，,、)]}）】」』\"'").contains(left) { return true }
        if let right, CharacterSet(charactersIn: "([{（【「『\"'").contains(right) { return true }
        if isTokenScalar(left), isTokenScalar(right) { return false }
        return true
    }

    private static func scalar(at index: Int, in text: NSString) -> UnicodeScalar? {
        guard index >= 0, index < text.length else { return nil }
        return text.substring(with: NSRange(location: index, length: 1)).unicodeScalars.first
    }

    private static func isTokenScalar(_ scalar: UnicodeScalar?) -> Bool {
        guard let scalar else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }

    private static func kind(for text: String) -> ImpactParagraphKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed.hasPrefix("#") { return .heading }
        if trimmed.hasPrefix(">") { return .quote }
        if trimmed.hasPrefix("```") { return .code }
        if trimmed.contains("|") && trimmed.contains("---") { return .table }
        if trimmed.range(of: #"^\s*(?:[-*+]\s+|\d+[.)]\s+)"#, options: .regularExpression) != nil { return .list }
        return .body
    }

    private static func paddedIndex(_ index: Int) -> String {
        String(format: "%04d", index)
    }
}

public enum ImpactGenreRegistry {
    public static let fallbackGenreID = "general_document"

    public static func allRubrics() -> [ImpactGenreRubric] {
        baseRubrics
    }

    public static func rubric(id: String) -> ImpactGenreRubric? {
        baseRubrics.first { $0.id == id } ?? baseRubrics.first { $0.id == fallbackGenreID }
    }

    public static var genreIDList: String {
        baseRubrics.map { "\($0.id): \($0.label)" }.joined(separator: "\n")
    }

    private static func rubric(
        _ id: String,
        _ label: String,
        _ family: String,
        language: [String],
        format: [String],
        purpose: String,
        structure: String,
        evidence: String,
        reader: String,
        fit: String,
        clarity: String
    ) -> ImpactGenreRubric {
        ImpactGenreRubric(
            id: id,
            label: label,
            family: family,
            languageRequirements: language,
            formatRequirements: format,
            dimensionPrompts: [
                .purposeClarity: purpose,
                .structureLogic: structure,
                .evidenceSufficiency: evidence,
                .readerReaction: reader,
                .genreFit: fit,
                .languageClarity: clarity,
            ]
        )
    }

    private static let baseRubrics: [ImpactGenreRubric] = [
        rubric("general_document", "通用文档", "general", language: ["清楚", "连贯", "面向读者"], format: ["明确目的", "分段合理", "结论或下一步清楚"], purpose: "判断文本是否明确说明写作目的、核心信息和期望读者采取的行动。", structure: "检查内容顺序、段落功能、转折和结尾是否形成清楚路径。", evidence: "检查主张是否由事实、例子、数据或上下文支撑。", reader: "模拟目标读者是否理解重点、信任文本并知道下一步。", fit: "检查文本是否符合它最接近的使用场景和正式度。", clarity: "找出冗余、模糊、长句、术语不一致和不必要复杂表达。"),
        rubric("chat_message", "即时消息", "general", language: ["短", "直接", "低负担", "避免语气误伤"], format: ["上下文", "核心信息", "回复或行动期待"], purpose: "判断消息是否一眼能看出意图，是通知、请求、确认、拒绝、道歉还是推进决策。", structure: "检查是否先给必要上下文，再给核心信息或行动要求。", evidence: "如涉及判断、承诺、结论，检查是否给出足够依据、时间、对象、条件。", reader: "模拟接收者是否会困惑、被冒犯、不知道如何回复，或误解语气。", fit: "检查是否符合即时消息的短句、口语化、低负担阅读习惯。", clarity: "找出模糊代词、过长句、情绪化表达、双关或可能被误读的措辞。"),
        rubric("social_post", "社交媒体帖子", "general", language: ["抓人", "简短", "有语气", "易分享"], format: ["hook", "正文", "标签或链接", "互动问题"], purpose: "检查开头是否让读者立刻知道为什么要停下来读。", structure: "检查 hook、主体、互动或 CTA 是否在有限篇幅内形成节奏。", evidence: "检查观点、经历或事实是否足以支撑分享价值。", reader: "模拟读者是否愿意点赞、评论、转发或继续了解。", fit: "检查是否符合平台语气、长度、标签和互动习惯。", clarity: "删掉泛泛开场，强化具体场景、动作和可转发句。"),
        rubric("forum_post", "论坛/社区帖子", "general", language: ["具体", "可回复", "上下文充分", "尊重社区"], format: ["标题", "背景", "尝试过什么", "问题", "期望反馈"], purpose: "检查帖子是否明确要讨论、求助、分享还是征询意见。", structure: "检查标题、背景、已尝试方案、具体问题是否齐全。", evidence: "检查是否提供复现信息、上下文、约束或参考链接。", reader: "模拟社区成员是否知道如何回复且不会觉得信息不足。", fit: "检查是否符合社区规范、语气和可讨论性。", clarity: "用具体问题替代泛泛求助，减少情绪化或过宽问题。"),
        rubric("personal_note", "个人笔记", "general", language: ["自然", "可回忆", "低结构压力", "重点可见"], format: ["日期/标题", "要点", "想法", "下一步"], purpose: "检查笔记是否能帮助未来的自己理解当时重点。", structure: "检查信息是否按主题、时间或任务组织，避免混杂。", evidence: "检查事实、链接、决定和待办是否足以回溯。", reader: "模拟未来读者是否能快速恢复上下文并行动。", fit: "检查是否符合个人知识记录的轻量、可检索风格。", clarity: "把隐含前提补成关键词、标题和明确待办。"),
        rubric("formal_letter", "正式信函", "general", language: ["正式", "礼貌", "清楚", "完整"], format: ["称呼", "目的", "背景", "请求/回应", "结束语"], purpose: "检查信件是否在开头明确来意和关系场景。", structure: "检查称呼、背景、正文、请求、结束语是否符合正式信函顺序。", evidence: "检查请求、事实、日期、附件或证明是否充分。", reader: "模拟收信人是否能理解诉求、态度和下一步。", fit: "检查正式度、礼貌公式和格式是否匹配机构或个人关系。", clarity: "减少绕圈寒暄，明确请求对象、事项和期限。"),
        rubric("announcement", "公告/通知", "general", language: ["直接", "权威", "时间明确", "行动清楚"], format: ["对象", "事项", "时间地点", "影响", "行动要求"], purpose: "检查公告是否明确谁需要知道什么、何时生效、要做什么。", structure: "检查是否按对象、事项、影响、行动和联系方式组织。", evidence: "检查政策、时间、地点、负责人和例外是否足够。", reader: "模拟读者是否会遗漏截止时间、适用范围或责任。", fit: "检查是否符合公告的正式、可扫读、无歧义格式。", clarity: "用标题、项目符号和时间字段降低误读风险。"),
        rubric("general_email", "普通邮件", "general", language: ["礼貌", "清楚", "分段", "可执行"], format: ["主题", "开头目的", "正文", "下一步"], purpose: "判断邮件主题、首段和结尾是否明确说明为什么写、希望对方做什么。", structure: "检查是否按背景、重点、请求、截止时间、附件或补充信息组织。", evidence: "检查是否提供对方完成任务所需的上下文、链接、数据或附件说明。", reader: "模拟收件人是否知道优先级、是否会漏看关键信息、是否会觉得负担过重。", fit: "检查称呼、语气、礼貌程度、正式度是否适合关系和场景。", clarity: "压缩冗余寒暄，拆分长句，明确代词指向和时间条件。"),
        rubric("business_email", "商务邮件", "business", language: ["专业", "简洁", "礼貌", "行动项明确"], format: ["结论先行", "背景", "请求", "截止时间", "下一步"], purpose: "检查是否在前几句说明业务目标、决策点或请求事项。", structure: "检查是否按结论先行、背景简述、具体请求、截止时间、下一步排列。", evidence: "检查是否给出数字、事实、业务影响或前序沟通依据。", reader: "模拟经理、客户、同事是否能快速判断要不要回复、批准或行动。", fit: "检查是否符合商务邮件的专业、简洁、礼貌、可执行风格。", clarity: "删除空泛客套、弱化词和含糊表达，确保责任人、动作、时间明确。"),
        rubric("sales_outreach", "销售开发邮件/私信", "business", language: ["个性化", "价值导向", "短", "低压力"], format: ["触发原因", "痛点", "价值", "证明", "轻量 CTA"], purpose: "检查开头是否说明为什么联系这位读者。", structure: "检查是否从个性化观察到价值主张，再到低门槛下一步。", evidence: "检查是否有客户证据、指标、案例或可信理由支持价值。", reader: "模拟潜在客户是否觉得相关、可信、不被打扰。", fit: "检查是否符合 outbound 的短、具体、非模板化风格。", clarity: "删除泛泛赞美和硬推销，改成具体触发和轻量请求。"),
        rubric("customer_support_reply", "客服回复", "business", language: ["共情", "明确", "解决导向", "避免推责"], format: ["确认问题", "解释原因", "解决步骤", "时间预期", "补偿/升级"], purpose: "检查回复是否先承认用户问题并说明能做什么。", structure: "检查是否按理解、原因、步骤、时间线和升级路径组织。", evidence: "检查是否提供订单号、错误信息、限制、责任和验证方式。", reader: "模拟用户是否会感到被理解、知道下一步并恢复信任。", fit: "检查是否符合客服回复的礼貌、清楚、负责风格。", clarity: "减少内部术语和含糊道歉，给出具体步骤与时间。"),
        rubric("memo", "备忘录", "business", language: ["内部", "简洁", "任务导向", "中性"], format: ["To/From/Date/Subject", "摘要", "背景", "讨论", "行动"], purpose: "判断 memo 是否明确说明内部沟通目的，是通知、建议、决策记录还是行动请求。", structure: "检查是否包含收件人、发件人、日期、主题，并按摘要、背景、讨论、行动组织。", evidence: "检查内部决策所需的数据、政策依据、影响范围和风险是否足够。", reader: "模拟内部读者是否能快速找到结论、责任人和后续动作。", fit: "检查是否符合 memo 的简洁、组织内部、任务导向格式。", clarity: "消除长段落和官僚表达，用标题、列表和短句提高可扫读性。"),
        rubric("executive_summary", "执行摘要", "business", language: ["结论先行", "高密度", "少过程", "面向决策"], format: ["问题", "洞察", "建议", "影响", "风险", "下一步"], purpose: "判断是否在开头给出核心结论、建议和需要决策的事项。", structure: "检查是否按问题、洞察、建议、影响、风险、下一步组织。", evidence: "检查关键结论是否由指标、事实或案例支撑。", reader: "模拟高层是否能在短时间内做出判断。", fit: "检查是否符合 executive summary 的高密度、结论导向、少细节风格。", clarity: "删除过程性叙述，保留决策相关信息。"),
        rubric("business_report", "商业报告", "business", language: ["客观", "数据驱动", "分析性", "建议明确"], format: ["背景", "方法", "发现", "分析", "建议", "附录"], purpose: "检查报告要回答的业务问题是否明确。", structure: "检查是否按背景、方法、发现、分析、建议、附录展开。", evidence: "检查数据来源、样本、假设、限制和推论是否完整。", reader: "模拟业务读者是否会信服结论并知道如何行动。", fit: "检查是否符合报告的客观、结构化、数据支持风格。", clarity: "避免空洞形容词，用具体指标和解释替代。"),
        rubric("business_proposal", "商业提案", "business", language: ["说服", "商业化", "可执行", "风险清楚"], format: ["问题", "方案", "价值", "实施", "成本", "风险", "CTA"], purpose: "检查提案是否明确要争取批准、预算、合作还是资源。", structure: "检查是否从痛点到方案，再到价值、执行计划、风险和请求。", evidence: "检查市场、成本、收益、案例、可行性证据是否支撑方案。", reader: "模拟决策者会问什么反对问题，是否已提前回答。", fit: "检查是否符合提案的说服性、商业性、可执行格式。", clarity: "减少口号化表达，明确收益、投入、时间线和责任。"),
        rubric("strategy_doc", "战略文档", "business", language: ["方向明确", "取舍清楚", "长期视角", "可落地"], format: ["愿景", "诊断", "选择", "举措", "指标", "风险"], purpose: "检查战略是否说明要赢在哪里、为什么现在、取舍是什么。", structure: "检查愿景、现状诊断、战略选择、举措、指标是否闭环。", evidence: "检查市场、竞争、能力、资源和假设是否支撑取舍。", reader: "模拟领导层和执行团队是否理解优先级与放弃项。", fit: "检查是否符合战略文档的高层次但可执行风格。", clarity: "把抽象愿景落到具体选择、指标和边界。"),
        rubric("meeting_agenda", "会议议程", "business", language: ["简洁", "目标明确", "时间盒", "角色清楚"], format: ["目标", "议题", "时间", "负责人", "准备材料"], purpose: "检查会议是否有明确目标和期望产出。", structure: "检查议题顺序、时间分配、负责人和材料是否完整。", evidence: "检查背景材料、决策问题和输入是否足够。", reader: "模拟参会者是否能提前准备并控制会议范围。", fit: "检查是否符合 agenda 的可执行、可控时长格式。", clarity: "把宽泛议题改成问题式议题和明确产出。"),
        rubric("meeting_minutes", "会议纪要", "business", language: ["事实记录", "决策清楚", "行动项明确", "可追踪"], format: ["参会人", "讨论摘要", "决定", "行动项", "截止日期"], purpose: "检查纪要是否明确记录做了什么决定和谁负责什么。", structure: "检查讨论、决定、行动项、负责人、截止时间是否分开。", evidence: "检查关键依据、异议、未决问题是否记录充分。", reader: "模拟未参会者是否能理解结果并继续执行。", fit: "检查是否符合纪要的中性、可追踪、非流水账风格。", clarity: "减少逐字记录，突出决定、理由和行动。"),
        rubric("project_plan", "项目计划", "business", language: ["可执行", "边界清楚", "时间线明确", "风险可见"], format: ["目标", "范围", "里程碑", "资源", "风险", "验收"], purpose: "检查项目目标、范围和成功标准是否清楚。", structure: "检查里程碑、依赖、资源、风险、验收是否形成执行路径。", evidence: "检查估算、约束、假设和责任分配是否充分。", reader: "模拟项目成员是否知道下一步和风险升级方式。", fit: "检查是否符合项目计划的结构化、可追踪格式。", clarity: "将模糊任务改成负责人、日期和可验证产出。"),
        rubric("okr", "OKR", "business", language: ["聚焦", "可衡量", "有挑战", "少而精"], format: ["Objective", "Key Results", "Initiatives", "Owner"], purpose: "检查目标是否表达清楚的方向和业务价值。", structure: "检查 Objective、KR、举措和负责人是否对应。", evidence: "检查 KR 是否可量化、有基线或目标值并能证明进展。", reader: "模拟团队是否能据此优先排序并判断成败。", fit: "检查是否符合 OKR 的结果导向而非任务清单风格。", clarity: "把活动性描述改成结果指标和明确数字。"),
        rubric("performance_review", "绩效评估", "career", language: ["具体", "平衡", "证据化", "发展导向"], format: ["成果", "行为", "影响", "反馈", "下一步"], purpose: "检查评价目的是否明确，是晋升、复盘、反馈还是发展。", structure: "检查成果、行为、影响、改进点和下一步是否平衡。", evidence: "检查评价是否有项目、指标、行为例子支撑。", reader: "模拟被评价者和管理者是否认为公平、可执行。", fit: "检查是否符合绩效评估的专业、尊重、证据导向风格。", clarity: "用具体行为和影响替代人格化判断。"),
        rubric("case_study", "商业案例研究", "marketing", language: ["故事化", "结果导向", "客户视角", "可信"], format: ["客户背景", "挑战", "方案", "实施", "结果", "引用"], purpose: "检查案例是否明确展示客户问题和可复制价值。", structure: "检查挑战、方案、实施、结果是否形成前后对比。", evidence: "检查结果是否有指标、客户引用、时间线或对照。", reader: "模拟潜在客户是否能代入并信任结果。", fit: "检查是否符合 case study 的客户故事和商业证明格式。", clarity: "把功能清单改成客户场景、行动和结果。"),
        rubric("white_paper", "白皮书", "marketing", language: ["权威", "教育性", "研究支撑", "解决方案导向"], format: ["摘要", "问题背景", "研究/洞察", "框架", "建议", "结论"], purpose: "检查白皮书是否围绕一个行业问题给出可信框架。", structure: "检查从背景到研究洞察、框架和建议是否递进。", evidence: "检查统计、来源、案例、方法和限制是否支撑权威性。", reader: "模拟专业读者是否认为内容值得保存和分享。", fit: "检查是否符合白皮书的教育性、深度和品牌可信度。", clarity: "减少营销口号，增加框架、数据和清楚图示说明。"),
        rubric("incident_report", "事故/事件报告", "business", language: ["事实化", "时间线", "影响清楚", "改进导向"], format: ["摘要", "影响", "时间线", "根因", "处置", "预防"], purpose: "检查报告是否说明发生了什么、影响谁、当前状态如何。", structure: "检查摘要、影响、时间线、根因、处置、后续行动是否完整。", evidence: "检查日志、指标、决策点、责任边界和证据是否充分。", reader: "模拟利益相关方是否能信任复盘并理解改进。", fit: "检查是否符合事故报告的无责、透明、证据导向风格。", clarity: "避免模糊归因，明确时间、影响范围和验证结果。"),
        rubric("prd", "产品需求文档", "product", language: ["可实现", "可测试", "范围明确", "用户问题导向"], format: ["背景", "用户场景", "目标", "需求", "非目标", "验收标准"], purpose: "检查需求文档是否明确要解决的用户问题和业务目标。", structure: "检查背景、用户场景、需求、边界、验收标准是否完整。", evidence: "检查需求是否有用户证据、数据、反馈或业务约束支持。", reader: "模拟设计、工程、测试是否能独立理解并执行。", fit: "检查是否符合 PRD 的可实现、可测试、范围明确要求。", clarity: "将模糊需求改成可验收条件，避免“优化”“支持”等空词。"),
        rubric("mrd", "市场需求文档", "product", language: ["市场导向", "机会明确", "竞争意识", "商业价值"], format: ["市场背景", "用户细分", "问题", "竞争", "机会", "成功指标"], purpose: "检查 MRD 是否明确市场机会和目标用户。", structure: "检查市场、用户、竞品、机会、指标是否支撑产品方向。", evidence: "检查数据、调研、竞品证据和 TAM/SAM 等假设是否充分。", reader: "模拟产品和商业团队是否能据此判断优先级。", fit: "检查是否符合 MRD 的市场分析和机会论证风格。", clarity: "用具体细分市场和证据替代泛泛“用户需要”。"),
        rubric("user_story", "用户故事", "product", language: ["用户中心", "可验收", "小颗粒", "价值清楚"], format: ["As a", "I want", "So that", "Acceptance Criteria"], purpose: "检查用户故事是否说明用户、目标和价值。", structure: "检查故事、验收标准、边界条件是否对应。", evidence: "检查场景、数据、状态和异常是否足以开发测试。", reader: "模拟工程和 QA 是否能无歧义实现。", fit: "检查是否符合用户故事的 INVEST、小而可验收风格。", clarity: "把解决方案描述改成用户目标和可验证条件。"),
        rubric("release_notes", "发布说明", "product", language: ["用户收益", "简洁", "分组", "可行动"], format: ["新增", "改进", "修复", "已知问题", "升级提示"], purpose: "检查发布说明是否说明这次变化对用户有什么价值。", structure: "检查新增、改进、修复、已知问题和升级提示是否分组。", evidence: "检查版本号、影响范围、迁移步骤和限制是否充分。", reader: "模拟用户是否知道是否需要升级、如何使用新能力。", fit: "检查是否符合 release notes 的清楚、非营销、面向用户风格。", clarity: "用用户收益替代内部实现细节。"),
        rubric("changelog", "变更日志", "technical", language: ["准确", "简短", "版本化", "可追踪"], format: ["版本", "日期", "Added", "Changed", "Fixed", "Breaking"], purpose: "检查每条变更是否明确说明影响范围。", structure: "检查是否按版本、日期、变更类型和兼容性组织。", evidence: "检查 breaking changes、迁移说明、issue/PR 链接是否充分。", reader: "模拟开发者是否能判断升级风险。", fit: "检查是否符合 changelog 的版本化、可追踪格式。", clarity: "用一致动词和标签，删除模糊“优化若干问题”。"),
        rubric("ux_microcopy", "UX Microcopy", "ux", language: ["短", "情境化", "用户语言", "行动导向"], format: ["状态", "原因", "下一步", "按钮动作"], purpose: "检查文案是否让用户知道当前状态和下一步。", structure: "检查提示是否在正确时机、正确位置、对应用户任务。", evidence: "检查错误、限制或权限说明是否给出必要原因和解决办法。", reader: "模拟用户是否会困惑、焦虑、误点或中断流程。", fit: "检查是否符合 UI 文案的简短、具体、行动导向风格。", clarity: "避免技术码和抽象词，使用用户语言和明确按钮动词。"),
        rubric("error_message", "错误信息", "ux", language: ["清楚", "可恢复", "不责怪用户", "具体"], format: ["发生了什么", "为什么", "怎么解决", "联系渠道"], purpose: "检查错误信息是否说明状态和恢复路径。", structure: "检查原因、影响、下一步和支持方式是否按优先级呈现。", evidence: "检查错误码、限制、权限或输入要求是否足够。", reader: "模拟用户是否能不恐慌并完成下一步。", fit: "检查是否符合错误文案的短、明确、非责备风格。", clarity: "删除“出错了”式空话，改成具体动作和恢复建议。"),
        rubric("onboarding_copy", "新手引导文案", "ux", language: ["鼓励", "渐进", "收益明确", "少干扰"], format: ["价值", "步骤", "示例", "完成反馈"], purpose: "检查引导是否说明用户为什么要完成这一步。", structure: "检查是否按最小步骤递进，并给出及时反馈。", evidence: "检查示例、默认值、权限说明是否足以降低阻力。", reader: "模拟新用户是否知道下一步且愿意继续。", fit: "检查是否符合 onboarding 的轻量、任务内、价值驱动风格。", clarity: "把产品术语改成用户收益和具体操作。"),
        rubric("help_center_article", "帮助中心文章", "support", language: ["任务导向", "可搜索", "步骤清楚", "边界明确"], format: ["适用对象", "步骤", "截图/提示", "故障处理", "联系支持"], purpose: "检查文章是否对应一个清晰用户问题。", structure: "检查适用条件、步骤、验证、故障处理是否完整。", evidence: "检查截图描述、菜单路径、限制和版本差异是否充分。", reader: "模拟用户是否能独立解决问题。", fit: "检查是否符合帮助中心的可搜索、低负担格式。", clarity: "优化标题和步骤动词，避免内部术语。"),
        rubric("tutorial", "教程", "technical", language: ["教学性", "渐进", "第二人称", "鼓励式"], format: ["目标", "前提", "步骤", "验证", "总结"], purpose: "检查教程是否说明学习目标和完成后读者能做什么。", structure: "检查步骤是否从准备、操作、验证到总结递进。", evidence: "检查是否给出预期输出、截图、命令结果或验证方法。", reader: "模拟新手是否会卡在未说明的前提、环境或术语上。", fit: "检查是否符合教程的教学性、渐进性、鼓励式风格。", clarity: "使用第二人称、主动语态、编号步骤和清楚命令。"),
        rubric("how_to", "How-to Guide", "technical", language: ["任务导向", "简洁", "命令式", "实用"], format: ["前提", "步骤", "验证", "故障处理"], purpose: "检查标题和开头是否明确要完成的具体任务。", structure: "检查前提条件、步骤、验证、故障处理是否完整。", evidence: "检查步骤是否有命令、参数、结果和边界条件。", reader: "模拟忙碌读者是否能快速完成任务。", fit: "检查是否符合 how-to 的实用、简洁、任务导向格式。", clarity: "用命令式短句，避免解释性长段抢占步骤。"),
        rubric("api_reference", "API Reference", "technical", language: ["准确", "稳定", "可查找", "术语一致"], format: ["endpoint", "auth", "parameters", "request", "response", "errors", "examples"], purpose: "检查每个接口用途是否一句话讲清。", structure: "检查 endpoint、auth、parameters、request、response、errors、examples 是否完整。", evidence: "检查示例是否可运行，错误和边界是否覆盖。", reader: "模拟开发者是否能不问人完成接入。", fit: "检查是否符合 reference 的准确、稳定、可查找格式。", clarity: "术语一致，参数定义无歧义，示例和说明一致。"),
        rubric("readme", "README", "technical", language: ["入口文档", "可操作", "可扫描", "价值明确"], format: ["项目是什么", "安装", "快速开始", "配置", "示例", "贡献"], purpose: "检查开头是否说明项目用途、目标用户和价值。", structure: "检查是否按概览、安装、快速开始、配置、示例、贡献组织。", evidence: "检查命令、依赖、版本、运行结果是否足够。", reader: "模拟新用户是否能 5 分钟内跑起来。", fit: "检查是否符合 README 的入口文档、可操作、可扫描格式。", clarity: "简化背景，突出 quickstart 和常见错误。"),
        rubric("troubleshooting", "故障排查", "technical", language: ["诊断式", "步骤化", "证据导向", "可验证"], format: ["症状", "原因", "诊断", "修复", "验证"], purpose: "检查是否明确对应什么错误、症状或失败场景。", structure: "检查是否按 symptom、cause、diagnosis、fix、verification 组织。", evidence: "检查是否给出日志、命令、错误码和验证标准。", reader: "模拟用户是否能定位自己是否命中该问题。", fit: "检查是否符合排障文档的诊断式、步骤化、证据导向风格。", clarity: "避免“可能是网络问题”等空泛判断，给出可验证路径。"),
        rubric("architecture_doc", "架构文档", "technical", language: ["系统性", "权衡清楚", "边界明确", "可维护"], format: ["背景", "目标", "组件", "数据流", "权衡", "风险"], purpose: "检查架构文档是否明确要解决的系统问题和约束。", structure: "检查组件、接口、数据流、部署、权衡是否形成完整图景。", evidence: "检查容量、安全、失败模式、替代方案和限制是否充分。", reader: "模拟工程团队是否能据此实现、评审和维护。", fit: "检查是否符合架构文档的中立、可追踪、权衡导向风格。", clarity: "明确术语、边界和因果，减少“显然”“简单”等词。"),
        rubric("technical_design_doc", "技术设计文档/RFC", "technical", language: ["决策导向", "可评审", "约束清楚", "实现可行"], format: ["问题", "目标/非目标", "方案", "接口", "迁移", "测试"], purpose: "检查设计是否说明要做的技术决策和成功标准。", structure: "检查问题、非目标、方案、接口、迁移、测试、回滚是否完整。", evidence: "检查取舍、风险、性能、安全、兼容性证据是否充分。", reader: "模拟评审者是否能发现风险并批准执行。", fit: "检查是否符合 RFC/design doc 的可评审、透明权衡格式。", clarity: "把模糊方案细化为接口、状态、错误和测试。"),
        rubric("runbook", "运维 Runbook", "technical", language: ["操作化", "安全", "可恢复", "验证明确"], format: ["触发条件", "步骤", "回滚", "验证", "升级"], purpose: "检查 runbook 是否明确何时使用和目标状态。", structure: "检查诊断、操作、回滚、验证、升级路径是否按顺序。", evidence: "检查命令、权限、风险、预期输出和超时条件是否充分。", reader: "模拟值班人员是否能在压力下安全执行。", fit: "检查是否符合 runbook 的命令式、可验证、安全格式。", clarity: "用复制即用命令和检查点替代叙述性建议。"),
        rubric("postmortem", "事故复盘/Postmortem", "technical", language: ["无责", "事实化", "根因导向", "行动可追踪"], format: ["摘要", "影响", "时间线", "根因", "经验", "行动项"], purpose: "检查复盘是否明确影响、根因和防复发目标。", structure: "检查摘要、时间线、根因、检测、响应、行动项是否闭环。", evidence: "检查指标、日志、客户影响、决策记录是否支撑结论。", reader: "模拟团队是否能信任复盘并执行改进。", fit: "检查是否符合 blameless postmortem 的透明、学习导向风格。", clarity: "避免责备个人，明确系统性原因和 owner/date。"),
        rubric("code_review_comment", "代码评审意见", "technical", language: ["具体", "建设性", "可操作", "尊重"], format: ["问题", "影响", "建议", "示例"], purpose: "检查评审意见是否明确指出问题和影响。", structure: "检查是否包含位置、原因、建议和可选替代方案。", evidence: "检查是否有代码行为、测试或规范证据支撑。", reader: "模拟作者是否能理解并愿意修改。", fit: "检查是否符合 code review 的简洁、协作、问题导向风格。", clarity: "避免命令式评价人格，改成具体风险和建议。"),
        rubric("pull_request_description", "PR 描述", "technical", language: ["上下文", "变更清楚", "测试明确", "风险可见"], format: ["背景", "改动", "截图/证据", "测试", "风险"], purpose: "检查 PR 是否说明为什么改和改了什么。", structure: "检查背景、范围、测试、风险、回滚、关联 issue 是否完整。", evidence: "检查验证命令、截图、数据迁移或兼容性证据是否充分。", reader: "模拟 reviewer 是否能快速决定如何评审。", fit: "检查是否符合 PR 描述的可审查、证据化格式。", clarity: "把流水账 commits 改成范围、验证和风险摘要。"),
        rubric("academic_essay", "学术 Essay", "academic", language: ["正式", "分析性", "证据驱动", "避免口语"], format: ["thesis", "topic sentence", "evidence", "analysis", "conclusion"], purpose: "检查 essay 是否有清楚、可争辩、早出现的中心论点。", structure: "检查每段是否服务 thesis，段落顺序是否形成递进论证。", evidence: "检查每个主张是否有文本、数据、文献或案例支持。", reader: "模拟学术读者是否理解问题为何重要、论证为何成立。", fit: "检查是否符合学术 essay 的正式、分析性、证据驱动风格。", clarity: "删除泛泛判断，强化 topic sentence、transition 和分析句。"),
        rubric("research_article", "研究论文", "academic", language: ["客观", "严谨", "可复现", "限制清楚"], format: ["Introduction", "Methods", "Results", "Discussion"], purpose: "检查研究问题、研究缺口和贡献是否明确。", structure: "检查引言、方法、结果、讨论是否各司其职且互相对应。", evidence: "检查方法、数据、统计、限制是否足以支持结论。", reader: "模拟同行是否能复现、信服并理解研究价值。", fit: "检查是否符合研究论文的客观、严谨、可验证格式。", clarity: "减少夸大结论，明确变量、样本、结果和限制。"),
        rubric("abstract", "论文摘要", "academic", language: ["浓缩", "完整", "客观", "贡献明确"], format: ["背景", "目的", "方法", "结果", "结论"], purpose: "检查摘要是否在有限字数内说明研究问题和贡献。", structure: "检查背景、目的、方法、结果、结论是否平衡。", evidence: "检查结果是否包含关键数据或发现而非空泛承诺。", reader: "模拟检索读者是否能判断是否阅读全文。", fit: "检查是否符合摘要的独立、精炼、非宣传风格。", clarity: "删掉泛泛重要性，加入具体方法、结果和结论。"),
        rubric("literature_review", "文献综述", "academic", language: ["综合", "批判", "比较", "学术对话"], format: ["范围", "主题", "共识", "分歧", "gap", "结论"], purpose: "检查综述是否说明主题范围、综述目的和研究问题。", structure: "检查是否按主题、方法、理论或时间组织，而非简单罗列文献。", evidence: "检查是否比较多篇来源的关系、分歧、共识和空白。", reader: "模拟读者是否能看出领域地图和下一步研究机会。", fit: "检查是否符合文献综述的综合、批判、学术对话风格。", clarity: "强化连接词和比较句，减少“某某说”的堆叠。"),
        rubric("research_proposal", "研究计划/开题报告", "academic", language: ["问题明确", "方法可行", "贡献清楚", "风险透明"], format: ["背景", "研究问题", "文献 gap", "方法", "时间线", "预期贡献"], purpose: "检查计划是否提出清晰可研究的问题。", structure: "检查背景、gap、问题、方法、数据、时间线是否连贯。", evidence: "检查可行性、伦理、数据来源、方法限制是否充分。", reader: "模拟导师或评审是否相信项目能完成且有价值。", fit: "检查是否符合研究计划的严谨、可执行、贡献导向风格。", clarity: "把宏大主题收窄为可操作问题和方法。"),
        rubric("lab_report", "实验报告", "academic", language: ["客观", "步骤清楚", "结果分明", "误差意识"], format: ["目的", "材料方法", "结果", "讨论", "结论"], purpose: "检查实验目的和假设是否明确。", structure: "检查方法、结果、讨论、结论是否分离且对应。", evidence: "检查数据、图表、误差、控制变量是否足以支持结论。", reader: "模拟老师或同行是否能复现实验并评估结果。", fit: "检查是否符合实验报告的客观、可复现格式。", clarity: "区分观察结果和解释，明确变量与误差来源。"),
        rubric("thesis_chapter", "论文/毕业设计章节", "academic", language: ["章节功能明确", "学术连贯", "证据充分", "格式规范"], format: ["章节目标", "小节", "论证", "图表", "小结"], purpose: "检查章节是否服务整篇论文的问题和贡献。", structure: "检查章节内部小节、过渡、图表和小结是否递进。", evidence: "检查引用、数据、方法或案例是否支撑章节结论。", reader: "模拟答辩评委是否能看出章节必要性和贡献。", fit: "检查是否符合学位论文的规范、严谨和章节化风格。", clarity: "强化章节导语、过渡和本章小结，减少松散堆料。"),
        rubric("annotated_bibliography", "注释书目", "academic", language: ["准确", "评价性", "简洁", "来源意识"], format: ["引用", "摘要", "评价", "相关性"], purpose: "检查每条注释是否说明来源内容和用途。", structure: "检查引用格式、摘要、评价和与主题相关性是否完整。", evidence: "检查是否评价方法、可信度、局限和贡献。", reader: "模拟读者是否能判断该来源是否值得使用。", fit: "检查是否符合 annotated bibliography 的规范和批判性。", clarity: "避免只复述标题，加入来源质量和适用场景。"),
        rubric("grant_proposal", "基金/资助申请", "academic", language: ["使命匹配", "影响明确", "可行", "预算合理"], format: ["问题", "目标", "方法", "影响", "团队", "预算"], purpose: "检查申请是否明确资助要解决的问题和影响。", structure: "检查目标、方法、时间线、团队、预算、评估是否闭环。", evidence: "检查需求证据、过往能力、评估指标和预算依据是否充分。", reader: "模拟评审是否相信项目重要、可行、值得资助。", fit: "检查是否符合 grant proposal 的使命匹配和证据化说服风格。", clarity: "把愿景转成可评估目标、里程碑和预算理由。"),
        rubric("lesson_plan", "教案", "education", language: ["目标明确", "活动可执行", "评估对应", "学生中心"], format: ["学习目标", "材料", "流程", "活动", "评估", "作业"], purpose: "检查课程目标是否具体、可观察、匹配学生水平。", structure: "检查导入、讲授、练习、评估、作业是否按学习逻辑展开。", evidence: "检查活动、材料、时间、差异化支持是否充分。", reader: "模拟教师是否能照此授课，学生是否能达成目标。", fit: "检查是否符合教案的目标-活动-评估一致性。", clarity: "把抽象目标改成可观察行为和评估证据。"),
        rubric("study_guide", "学习指南", "education", language: ["重点清楚", "层级化", "可练习", "鼓励"], format: ["目标", "重点", "解释", "例题", "自测"], purpose: "检查指南是否说明学习范围和掌握标准。", structure: "检查概念、例子、练习、自测是否从易到难。", evidence: "检查关键定义、误区、答案或反馈是否充分。", reader: "模拟学生是否能用它复习并发现薄弱点。", fit: "检查是否符合学习材料的清晰、渐进、可练习风格。", clarity: "增加标题、例子和自测问题，减少纯讲解堆叠。"),
        rubric("exam_question", "考试题目/解析", "education", language: ["准确", "公平", "难度清楚", "解析充分"], format: ["题干", "条件", "选项/要求", "答案", "解析"], purpose: "检查题目是否考查明确能力且无歧义。", structure: "检查题干、条件、选项、答案、解析是否对应。", evidence: "检查正确答案、干扰项、评分点和依据是否充分。", reader: "模拟学生是否会因文字而非能力被误导。", fit: "检查是否符合考试题的公平、准确、可评分格式。", clarity: "删除多余背景，明确条件、问法和评分依据。"),
        rubric("syllabus", "课程大纲", "education", language: ["范围明确", "政策清楚", "节奏可见", "期望透明"], format: ["课程目标", "周计划", "作业", "评分", "政策", "资源"], purpose: "检查大纲是否说明课程目标和学生责任。", structure: "检查目标、周计划、作业、评分、政策、资源是否完整。", evidence: "检查评分标准、迟交政策、材料和联系方式是否充分。", reader: "模拟学生是否能规划学习并理解规则。", fit: "检查是否符合 syllabus 的正式、透明、可规划格式。", clarity: "把隐性要求改成日期、权重和可执行政策。"),
        rubric("landing_page", "Landing Page", "marketing", language: ["转化导向", "可扫读", "收益明确", "强 CTA"], format: ["headline", "痛点", "价值", "证明", "CTA", "FAQ"], purpose: "检查首屏是否说明产品给谁、解决什么、为什么值得行动。", structure: "检查是否按痛点、价值、证明、功能、异议处理、CTA 组织。", evidence: "检查是否有案例、数据、评价、对比或演示支撑价值。", reader: "模拟目标用户是否会产生兴趣、信任和下一步行动。", fit: "检查是否符合 landing page 的转化导向、可扫读、强 CTA 风格。", clarity: "把功能描述转成用户收益，删除空泛形容词。"),
        rubric("seo_article", "SEO 博客", "marketing", language: ["人优先", "完整回答", "标题清楚", "不堆关键词"], format: ["搜索意图", "H1/H2/H3", "答案", "例子", "CTA"], purpose: "检查文章是否明确服务某个搜索意图和读者问题。", structure: "检查 H1/H2/H3 是否覆盖问题链，是否先回答核心问题。", evidence: "检查是否有原创经验、数据、例子、来源，而非泛泛汇总。", reader: "模拟读者读完是否达成搜索目标并感到满意。", fit: "检查是否符合 SEO 内容的人优先、可扫读、完整但不灌水风格。", clarity: "删除关键词堆砌和重复段落，强化标题和答案密度。"),
        rubric("ad_copy", "广告文案", "marketing", language: ["抓注意", "利益明确", "短", "可测试"], format: ["受众", "痛点", "利益", "证明", "CTA"], purpose: "检查广告是否在第一眼传达一个强利益点。", structure: "检查痛点、价值、证明和行动是否在短篇幅内闭环。", evidence: "检查承诺是否有可信证据且不夸大。", reader: "模拟目标用户是否会停留、理解并点击。", fit: "检查是否符合广告渠道、字符限制和转化目标。", clarity: "减少形容词，强化具体收益、场景和动词。"),
        rubric("product_description", "商品/产品描述", "marketing", language: ["具体", "收益导向", "可比较", "购买阻力低"], format: ["是什么", "适合谁", "特点", "收益", "规格", "保障"], purpose: "检查描述是否明确产品用途、适用人群和购买理由。", structure: "检查特点、收益、规格、使用场景和保障是否组织清楚。", evidence: "检查材质、尺寸、兼容性、证明和限制是否充分。", reader: "模拟买家是否能判断是否适合自己。", fit: "检查是否符合电商/产品页的可扫读、可信、转化格式。", clarity: "把抽象卖点改成具体场景、规格和结果。"),
        rubric("newsletter", "Newsletter", "marketing", language: ["关系感", "策展", "节奏好", "CTA 清楚"], format: ["开场", "主题内容", "链接/资源", "个人观点", "CTA"], purpose: "检查 newsletter 是否有明确主题和读者收益。", structure: "检查开场、内容块、资源、观点、行动是否形成阅读节奏。", evidence: "检查链接、来源、例子和推荐理由是否充分。", reader: "模拟订阅者是否觉得值得打开下一封。", fit: "检查是否符合 newsletter 的个人感、可扫读、持续关系风格。", clarity: "强化标题、分段和每个链接为什么值得点。"),
        rubric("video_script", "视频脚本", "media", language: ["口语化", "画面感", "节奏", "留存导向"], format: ["hook", "场景/画面", "正文", "转折", "CTA"], purpose: "检查开头是否在几秒内给出看下去的理由。", structure: "检查 hook、信息点、画面提示、转场和结尾是否有节奏。", evidence: "检查事实、演示、例子或素材是否支撑内容。", reader: "模拟观众是否会中途流失、困惑或愿意互动。", fit: "检查是否符合视频平台的口语、节奏和视觉呈现。", clarity: "把书面句改成可说出口的短句和画面动作。"),
        rubric("webinar_script", "网络研讨会脚本", "marketing", language: ["教育性", "互动", "结构清楚", "转化自然"], format: ["开场", "议程", "教学内容", "互动", "案例", "CTA"], purpose: "检查脚本是否明确参会者会学到什么。", structure: "检查议程、教学、互动、案例、提问和 CTA 是否顺畅。", evidence: "检查数据、案例、演示和讲者可信度是否充分。", reader: "模拟听众是否能跟上、参与并接受下一步。", fit: "检查是否符合 webinar 的教育优先、自然转化风格。", clarity: "增加过渡语、互动问题和口语化提示。"),
        rubric("press_release", "新闻稿", "media", language: ["新闻价值", "事实清楚", "引用规范", "客观"], format: ["标题", "导语", "新闻点", "引用", "背景", "媒体联系"], purpose: "检查新闻稿是否有明确新闻点而非广告语。", structure: "检查标题、导语、事实、引用、公司背景、联系方式是否完整。", evidence: "检查数字、时间、地点、人物、引用和可验证事实是否充分。", reader: "模拟记者是否能快速判断是否值得报道。", fit: "检查是否符合新闻稿的倒金字塔和媒体格式。", clarity: "减少营销形容词，强化事实、影响和引用。"),
        rubric("brand_story", "品牌故事", "marketing", language: ["价值观", "故事性", "差异化", "情感连接"], format: ["起源", "冲突", "选择", "价值观", "承诺"], purpose: "检查故事是否说明品牌为何存在、为谁而做。", structure: "检查起源、挑战、选择、价值观和承诺是否形成叙事弧。", evidence: "检查事实、创始人经历、客户影响是否支撑可信度。", reader: "模拟读者是否产生记忆点和情感连接。", fit: "检查是否符合品牌故事的真实、差异化、非口号风格。", clarity: "用具体人物和事件替代抽象使命宣言。"),
        rubric("news_article", "新闻报道", "media", language: ["事实优先", "客观", "简洁", "来源清楚"], format: ["lead", "5W1H", "背景", "引用", "影响"], purpose: "检查 lead 是否回答最重要新闻事实。", structure: "检查是否按重要性排序，而非按作者写作过程排序。", evidence: "检查事实、来源、引用、背景是否充分且可核查。", reader: "模拟读者是否能快速知道发生了什么和为何重要。", fit: "检查是否符合新闻报道的客观、简洁、事实导向风格。", clarity: "去掉评论性语言，明确主体、时间和来源。"),
        rubric("feature_article", "特写文章", "media", language: ["故事化", "细节", "人物", "主题深度"], format: ["开场场景", "人物", "冲突", "背景", "主题", "结尾"], purpose: "检查文章是否有明确人物、场景或主题钩子。", structure: "检查场景、人物、背景、冲突、主题是否交织推进。", evidence: "检查采访、细节、数据和背景材料是否支撑主题。", reader: "模拟读者是否被故事吸引并理解深层意义。", fit: "检查是否符合 feature 的叙事性、细节和深度风格。", clarity: "增加具象场景和人物行动，减少概括性说明。"),
        rubric("op_ed", "评论/专栏", "media", language: ["观点鲜明", "论证", "声音", "公共性"], format: ["立场", "背景", "理由", "反驳", "结论"], purpose: "检查评论是否有清晰、可争辩的中心观点。", structure: "检查立场、理由、证据、反方回应、结论是否递进。", evidence: "检查事实、例子、价值判断和逻辑是否足以支撑立场。", reader: "模拟读者是否理解并愿意考虑作者观点。", fit: "检查是否符合 op-ed 的观点性、公共讨论和作者声音。", clarity: "强化论点句，区分事实与价值判断。"),
        rubric("interview", "访谈稿", "media", language: ["问题有层次", "声音真实", "上下文清楚", "可读"], format: ["引言", "问答", "追问", "背景", "结尾"], purpose: "检查访谈目的和嘉宾价值是否清楚。", structure: "检查问题顺序是否由浅入深并保留必要上下文。", evidence: "检查回答是否有足够事实、例子、追问和澄清。", reader: "模拟读者是否能听见嘉宾声音并获得洞察。", fit: "检查是否符合访谈稿的对话、节奏和真实性。", clarity: "删掉寒暄重复，强化追问和关键回答。"),
        rubric("review_article", "评论/测评", "media", language: ["标准清楚", "体验具体", "平衡", "建议明确"], format: ["对象", "标准", "体验", "优缺点", "结论"], purpose: "检查测评是否说明评价标准和适用人群。", structure: "检查体验、优点、缺点、对比、结论是否分明。", evidence: "检查实测数据、场景、样例和限制是否充分。", reader: "模拟读者是否能据此决定是否购买/观看/使用。", fit: "检查是否符合测评的独立、具体、平衡风格。", clarity: "用具体体验和标准替代泛泛好坏判断。"),
        rubric("novel_chapter", "小说章节", "creative", language: ["场景化", "视角一致", "人物动机", "节奏"], format: ["场景目标", "冲突", "选择", "后果", "转折"], purpose: "检查本章在故事中的功能，是推进情节、揭示人物还是制造转折。", structure: "检查场景目标、冲突、选择、后果是否形成因果链。", evidence: "检查人物行为是否由前文动机、情境和设定支撑。", reader: "模拟读者是否想继续读、是否困惑或情感投入不足。", fit: "检查是否符合小说的叙事视角、节奏、场景化表达。", clarity: "处理过度说明、视角跳跃、重复描写和节奏拖慢。"),
        rubric("short_story", "短篇小说", "creative", language: ["集中", "暗示", "冲突", "余韵"], format: ["开端", "冲突", "转折", "高潮", "结尾"], purpose: "检查故事是否围绕一个核心冲突或情感变化。", structure: "检查开端、推进、转折、高潮、结尾是否紧凑。", evidence: "检查人物选择、伏笔、意象和结局是否相互支撑。", reader: "模拟读者是否在短篇幅内获得情感冲击或思考。", fit: "检查是否符合短篇小说的集中、留白、完整弧线。", clarity: "删除解释性段落，强化行动、意象和结尾余韵。"),
        rubric("poem", "诗歌", "creative", language: ["意象", "节奏", "浓缩", "声音"], format: ["意象", "行分割", "重复/转折", "结尾"], purpose: "检查诗是否有核心情绪、意象或声音。", structure: "检查行分割、节奏、重复、转折和结尾是否服务主题。", evidence: "检查意象和细节是否支撑情感而非空泛抒情。", reader: "模拟读者是否能感到声音、画面和余韵。", fit: "检查是否符合诗歌的浓缩、节奏和多义性。", clarity: "用具体意象替代抽象情绪词，调整换行节奏。"),
        rubric("screenplay", "剧本/脚本", "creative", language: ["可拍", "动作化", "对白自然", "场景清楚"], format: ["场景标题", "动作", "对白", "转场", "节拍"], purpose: "检查场景目标和戏剧冲突是否明确。", structure: "检查场景标题、动作、对白、节拍和转场是否规范。", evidence: "检查角色动机、视觉动作和因果是否支撑剧情。", reader: "模拟演员/导演是否能理解怎么演、怎么拍。", fit: "检查是否符合剧本的可视化、动作化和格式规范。", clarity: "减少心理说明，把信息转成动作、对白和场面调度。"),
        rubric("memoir", "回忆录/个人叙事", "creative", language: ["真实感", "反思", "场景", "成长线"], format: ["场景", "人物", "事件", "反思", "意义"], purpose: "检查叙事是否围绕一个人生片段和反思主题。", structure: "检查事件、场景、人物、反思是否交替推进。", evidence: "检查细节、对话、背景是否支撑真实性和意义。", reader: "模拟读者是否能共情并理解作者变化。", fit: "检查是否符合回忆录的真实、反思、故事化风格。", clarity: "增加具体场景，避免只总结人生道理。"),
        rubric("game_narrative", "游戏叙事/任务文本", "creative", language: ["可互动", "目标清楚", "世界观一致", "动机"], format: ["背景", "目标", "冲突", "奖励", "分支"], purpose: "检查玩家目标、动机和世界观信息是否清楚。", structure: "检查背景、任务目标、冲突、奖励和分支是否组织合理。", evidence: "检查设定、角色动机、前后状态是否一致。", reader: "模拟玩家是否知道要做什么且愿意投入。", fit: "检查是否符合游戏文本的互动性、简短和沉浸感。", clarity: "把说明改成可行动目标和角色化表达。"),
        rubric("legal_memo", "法律备忘录", "legal", language: ["客观", "精确", "引用充分", "风险清楚"], format: ["Issue", "Rule", "Application", "Conclusion"], purpose: "检查法律问题和简短结论是否明确。", structure: "检查是否按 issue、rule、application、conclusion 或 CREAC 组织。", evidence: "检查法条、判例、事实适用是否足以支持结论。", reader: "模拟律师或客户是否理解法律风险和不确定性。", fit: "检查是否符合法律 memo 的客观、精确、引用充分风格。", clarity: "减少法律黑话，明确规则、事实和推理链。"),
        rubric("contract", "合同", "legal", language: ["精确", "无歧义", "可执行", "定义清楚"], format: ["定义", "权利义务", "条件", "例外", "违约", "终止"], purpose: "检查合同条款是否明确分配权利、义务和风险。", structure: "检查定义、义务、条件、例外、违约、终止是否一致。", evidence: "检查关键约束是否有定义、时间、金额、责任主体。", reader: "模拟签约方是否会对责任、范围或例外产生不同理解。", fit: "检查是否符合合同的精确、无歧义、可执行风格。", clarity: "拆分长句，减少嵌套条件和未定义术语。"),
        rubric("legal_brief", "法律诉状/法律论证书", "legal", language: ["说服", "权威引用", "事实适用", "结构严密"], format: ["问题", "事实", "法律标准", "论证", "请求"], purpose: "检查法律立场和请求救济是否明确。", structure: "检查事实、法律标准、论证、反方回应、请求是否递进。", evidence: "检查判例、法条、记录事实是否充分支撑论点。", reader: "模拟法官或对方律师是否会看到漏洞。", fit: "检查是否符合法律 brief 的说服性、引用和严谨格式。", clarity: "强化规则到事实的适用链，补反方回应。"),
        rubric("privacy_policy", "隐私政策", "legal", language: ["透明", "完整", "用户可理解", "合规"], format: ["收集信息", "用途", "共享", "权利", "安全", "联系"], purpose: "检查政策是否明确说明收集什么、为什么、用户权利是什么。", structure: "检查收集、使用、共享、保留、安全、权利、联系是否完整。", evidence: "检查法律依据、第三方、地区差异和选择机制是否充分。", reader: "模拟用户和合规审查者是否能理解数据实践。", fit: "检查是否符合隐私政策的透明、完整和合规风格。", clarity: "减少法律堆叠，使用分层标题和普通语言解释。"),
        rubric("terms_of_service", "服务条款", "legal", language: ["权利义务清楚", "风险分配", "可执行", "范围明确"], format: ["账户", "使用规则", "付款", "责任限制", "终止", "争议"], purpose: "检查条款是否明确服务范围、用户义务和平台权利。", structure: "检查账户、使用限制、付款、内容、责任、终止、争议是否完整。", evidence: "检查关键定义、例外、限制、司法辖区和流程是否充分。", reader: "模拟用户或法务是否会对责任边界产生歧义。", fit: "检查是否符合 TOS 的精确、全面、可执行格式。", clarity: "拆解长句，明确条件、主体和后果。"),
        rubric("compliance_policy", "合规政策", "legal", language: ["规则明确", "职责清楚", "可执行", "审计友好"], format: ["适用范围", "原则", "流程", "责任", "例外", "报告"], purpose: "检查政策是否明确适用对象和禁止/要求行为。", structure: "检查范围、原则、流程、责任、例外和报告渠道是否完整。", evidence: "检查法规依据、控制点、记录要求和处罚是否充分。", reader: "模拟员工是否知道如何合规行动和升级问题。", fit: "检查是否符合合规政策的权威、可执行、可审计风格。", clarity: "把抽象原则转成可操作规则和责任。"),
        rubric("patient_education", "患者教育材料", "health", language: ["普通词汇", "短句", "行动步骤", "非恐吓"], format: ["是什么", "为什么", "怎么做", "何时求助"], purpose: "检查材料是否有一个主要健康信息和明确行动。", structure: "检查是否按读者问题顺序解释：是什么、为什么、怎么做、何时求助。", evidence: "检查建议是否说明原因、风险、收益和必要限制。", reader: "模拟患者是否能第一次阅读就理解并行动。", fit: "检查是否符合健康传播的 plain language、低负担、非恐吓风格。", clarity: "替换医学术语，使用短句、列表和具体行为。"),
        rubric("clinical_note", "临床记录", "health", language: ["客观", "结构化", "事实准确", "连续护理"], format: ["主诉", "病史", "检查", "评估", "计划"], purpose: "检查记录是否清楚说明病情、判断和计划。", structure: "检查 SOAP 或相应结构是否分明且信息不混杂。", evidence: "检查症状、体征、检查、用药、风险和随访是否充分。", reader: "模拟后续医护是否能安全接续护理。", fit: "检查是否符合临床记录的客观、简洁、专业格式。", clarity: "减少含糊描述，明确时间、剂量、阴性/阳性发现。"),
        rubric("medical_abstract", "医学摘要", "health", language: ["严谨", "结果具体", "限制清楚", "临床意义"], format: ["背景", "目的", "方法", "结果", "结论"], purpose: "检查摘要是否明确临床问题、方法和主要结论。", structure: "检查背景、方法、结果、结论是否平衡。", evidence: "检查样本、指标、效果量、不良事件和限制是否充分。", reader: "模拟临床读者是否能判断证据强度和适用性。", fit: "检查是否符合医学写作的谨慎、数据化和伦理风格。", clarity: "避免夸大疗效，明确人群、终点和限制。"),
        rubric("safety_instructions", "安全说明", "health", language: ["警示清楚", "步骤明确", "风险分级", "可执行"], format: ["危险", "准备", "步骤", "禁止事项", "应急"], purpose: "检查说明是否明确风险、适用范围和必须动作。", structure: "检查危险、准备、操作、禁止、应急和联系是否顺序清楚。", evidence: "检查阈值、设备、防护、例外和验证是否充分。", reader: "模拟读者在紧急或高风险场景是否能正确执行。", fit: "检查是否符合安全说明的醒目、无歧义、命令式格式。", clarity: "用强动词、警示词和列表替代长段解释。"),
        rubric("resume", "简历", "career", language: ["成果量化", "强动词", "可扫读", "岗位匹配"], format: ["摘要", "经历", "项目", "技能", "教育"], purpose: "检查简历是否明确展示候选人与目标岗位的匹配。", structure: "检查信息是否按最相关、最有说服力的顺序排列。", evidence: "检查经历是否用行动、结果、指标证明能力。", reader: "模拟招聘者 20-35 秒内能记住什么。", fit: "检查是否符合简历的简洁、扫描友好、成就导向格式。", clarity: "用强动词和数字替代职责罗列和泛泛自评。"),
        rubric("cover_letter", "求职信", "career", language: ["岗位匹配", "故事性", "专业", "具体"], format: ["开头匹配", "经历证据", "动机", "贡献", "结尾"], purpose: "检查求职信是否说明为什么适合这个岗位和公司。", structure: "检查开头、证据、动机、贡献、结尾请求是否递进。", evidence: "检查经历例子是否证明岗位关键能力。", reader: "模拟招聘者是否看到差异化和真诚动机。", fit: "检查是否符合求职信的专业、定制化、简洁风格。", clarity: "删除模板化热情，加入具体岗位需求和证据。"),
        rubric("linkedin_profile", "LinkedIn/职业简介", "career", language: ["定位清楚", "成果可见", "关键词", "可信"], format: ["headline", "about", "experience", "skills", "CTA"], purpose: "检查职业定位和目标受众是否清楚。", structure: "检查 headline、about、经历、技能、联系动作是否一致。", evidence: "检查成果、关键词、项目和社会证明是否充分。", reader: "模拟招聘者或合作方是否能快速理解价值。", fit: "检查是否符合职业资料的可搜索、可信、个人品牌风格。", clarity: "把空泛自我评价改成具体成果和服务对象。"),
        rubric("interview_answer", "面试回答", "career", language: ["结构化", "具体", "反思", "岗位相关"], format: ["情境", "任务", "行动", "结果", "学习"], purpose: "检查回答是否直接回应问题并体现岗位能力。", structure: "检查 STAR/CAR 结构是否完整且不冗长。", evidence: "检查行动、结果、指标、反思是否充分。", reader: "模拟面试官是否能判断候选人真实贡献。", fit: "检查是否符合面试回答的口语化、具体、正向风格。", clarity: "用具体场景和结果替代泛泛“我负责/我参与”。"),
        rubric("policy_brief", "政策简报", "policy", language: ["结论先行", "公共影响", "证据充分", "建议可行"], format: ["问题", "背景", "选项", "证据", "建议", "影响"], purpose: "检查简报是否明确政策问题和建议。", structure: "检查问题、背景、政策选项、证据、建议、影响是否清楚。", evidence: "检查数据、利益相关方、成本、风险和实施条件是否充分。", reader: "模拟决策者是否能快速判断采纳路径。", fit: "检查是否符合 policy brief 的简洁、证据化、行动导向格式。", clarity: "把学术背景压缩成决策相关证据和选项。"),
        rubric("public_comment", "公众意见/咨询反馈", "policy", language: ["立场清楚", "事实支撑", "礼貌", "诉求明确"], format: ["身份/利益", "立场", "理由", "证据", "请求"], purpose: "检查意见是否明确支持、反对或建议修改什么。", structure: "检查身份、立场、理由、证据、具体请求是否组织清楚。", evidence: "检查经历、数据、法规或影响说明是否充分。", reader: "模拟政府/机构读者是否能归类并采纳意见。", fit: "检查是否符合公众意见的礼貌、具体、可处理格式。", clarity: "减少情绪宣泄，明确条款、影响和替代建议。"),
        rubric("speech", "演讲稿", "public", language: ["口语", "节奏", "记忆点", "听众连接"], format: ["开场", "主题", "故事/证据", "转折", "行动号召"], purpose: "检查演讲是否明确听众、场合和核心信息。", structure: "检查开场、主体、故事、证据、高潮、结尾是否有听觉节奏。", evidence: "检查例子、数据、引用和个人经历是否支撑主题。", reader: "模拟现场听众是否听得懂、记得住、愿意行动。", fit: "检查是否符合演讲的口语化、重复、节奏和场合风格。", clarity: "把书面长句改成可说的短句和重复记忆点。"),
        rubric("crisis_communication", "危机沟通声明", "public", language: ["负责", "透明", "安抚", "行动明确"], format: ["承认情况", "影响", "已采取措施", "下一步", "联系"], purpose: "检查声明是否明确发生了什么、影响和当前行动。", structure: "检查事实、责任、补救、时间线、后续更新是否顺序合理。", evidence: "检查已知/未知、证据、承诺和联系方式是否充分。", reader: "模拟公众、客户或员工是否感到被尊重和告知。", fit: "检查是否符合危机沟通的透明、谨慎、非防御风格。", clarity: "避免推责和含糊承诺，明确行动与更新时间。"),
        rubric("fundraising_appeal", "募捐/公益倡议", "public", language: ["使命明确", "情感真实", "影响具体", "CTA 清楚"], format: ["问题", "故事", "解决方案", "影响", "捐助方式"], purpose: "检查倡议是否说明为什么现在需要读者支持。", structure: "检查问题、人物故事、方案、影响、捐助动作是否连贯。", evidence: "检查金额用途、影响数据、可信背书和透明度是否充分。", reader: "模拟捐助者是否信任并知道如何行动。", fit: "检查是否符合公益募捐的情感与证据平衡风格。", clarity: "用具体人和具体金额影响替代泛泛使命口号。"),
        rubric("investor_update", "投资人更新", "finance", language: ["透明", "指标导向", "风险清楚", "简洁"], format: ["摘要", "指标", "进展", "问题", "需求", "下一步"], purpose: "检查更新是否说明公司状态、进展和需要帮助的事项。", structure: "检查关键指标、里程碑、挑战、计划和 asks 是否分组。", evidence: "检查数据、同比/环比、现金、风险和假设是否充分。", reader: "模拟投资人是否能判断健康度并提供帮助。", fit: "检查是否符合投资人更新的透明、简洁、指标化风格。", clarity: "突出关键指标变化、风险和具体 ask。"),
        rubric("financial_analysis", "财务分析", "finance", language: ["数据准确", "假设清楚", "解释充分", "决策相关"], format: ["摘要", "数据", "假设", "分析", "敏感性", "建议"], purpose: "检查分析是否明确要支持的财务决策。", structure: "检查数据、假设、模型、结果、敏感性、建议是否完整。", evidence: "检查来源、口径、计算、限制和风险是否充分。", reader: "模拟决策者是否能信任数字并理解含义。", fit: "检查是否符合财务分析的严谨、可追溯、决策导向风格。", clarity: "明确口径和假设，用解释连接数字与建议。"),
        rubric("audit_finding", "审计发现", "finance", language: ["事实化", "风险评级", "证据充分", "整改明确"], format: ["条件", "标准", "原因", "影响", "建议", "管理层回应"], purpose: "检查发现是否明确问题、标准和风险。", structure: "检查条件、标准、原因、影响、建议、责任人是否完整。", evidence: "检查抽样、证据、金额、控制缺陷和法规依据是否充分。", reader: "模拟被审计方是否能理解并整改。", fit: "检查是否符合审计发现的客观、证据化、可整改格式。", clarity: "把主观判断改成标准差异、证据和整改动作。"),
        rubric("data_analysis_report", "数据分析报告", "data", language: ["问题导向", "方法透明", "洞察清楚", "可行动"], format: ["问题", "数据", "方法", "发现", "解释", "建议"], purpose: "检查报告是否明确分析问题和决策场景。", structure: "检查数据来源、方法、发现、解释、建议是否连贯。", evidence: "检查样本、口径、统计方法、限制和可视化说明是否充分。", reader: "模拟业务读者是否理解洞察并知道下一步。", fit: "检查是否符合数据分析的证据化、可复核、行动导向风格。", clarity: "把图表读数转成业务含义和建议。"),
        rubric("survey_report", "调研报告", "data", language: ["样本清楚", "发现聚焦", "方法透明", "限制明确"], format: ["目标", "样本", "方法", "结果", "洞察", "限制"], purpose: "检查调研目的和关键问题是否明确。", structure: "检查样本、方法、题目、结果、洞察、限制是否完整。", evidence: "检查样本量、偏差、置信度、原始问题和交叉分析是否充分。", reader: "模拟读者是否能正确理解调研代表性。", fit: "检查是否符合调研报告的方法透明和发现聚焦风格。", clarity: "明确样本与限制，避免过度推广。"),
    ]
}

public enum ImpactPromptBuilder {
    public static func boundarySystemPrompt() -> String {
        """
        You are a boundary finder for document segmentation.
        Your only task is to choose cut positions. Do not rewrite, summarize, correct, translate, or analyze the text.
        Return strict JSON only: {"cuts":[0],"rationale":[""]}
        Rules:
        - Offsets are UTF-16 offsets relative to the provided windowText.
        - Every final segment must be <= 1000 UTF-16 units.
        - Prefer natural sentence boundaries and semantic topic boundaries.
        - Keep headings with the paragraph that follows.
        - Keep list items together when possible.
        - Avoid cutting inside tables, code blocks, URLs, citations, or quoted strings.
        - If no natural boundary exists, choose the safest boundary before 1000.
        - Do not include 0 or the full window length as cuts.
        - Never use markdown fences.
        """
    }

    public static func boundaryUserPrompt(windowText: String, windowStart: Int, windowLength: Int) -> String {
        """
        windowStartInDocumentUTF16: \(windowStart)
        windowLengthUTF16: \(windowLength)
        maxSegmentLengthUTF16: 1000

        windowText:
        \(windowText)

        Return cut offsets relative to windowText.
        """
    }

    public static func impactSystemPrompt(responseLanguage: GrammarlessLanguageMode = .zh) -> String {
        """
        You are Grammarless Impact Analyzer. Return strict JSON only. Never use markdown fences.
        Use only the provided document text, segment map, genre rubric, and memory context.
        Do not invent fallback, placeholder, or canned analysis. If evidence is insufficient, say so explicitly with low confidence.
        Every finding must be grounded in the document using segmentID and paragraphIDs.
        Selected response language: \(responseLanguage.promptLanguageName).
        \(responseLanguage.promptLanguageInstruction)
        Exact document quotes, code, schema keys, IDs, and copied original text must remain exact.
        Core dimensions: purposeClarity, structureLogic, evidenceSufficiency, readerReaction, genreFit, languageClarity.
        """
    }

    public static func genrePrompt(
        segmentation: ImpactSegmentationResult,
        languageHint: DetectedLanguage,
        memoryContext: WritingMemoryContext,
        responseLanguage: GrammarlessLanguageMode = .zh
    ) -> String {
        let samples = sampledSegments(segmentation.segments, maxCount: 8)
        return """
        Task: classify the document genre, intent, and audience.
        \(languageRequirement(responseLanguage))

        Available genres:
        \(ImpactGenreRegistry.genreIDList)

        languageHint: \(languageHint.rawValue)
        documentLengthUTF16: \(segmentation.documentLengthUTF16)
        paragraphCount: \(segmentation.paragraphs.count)
        segmentCount: \(segmentation.segments.count)
        memoryDocumentSummary: \(memoryContext.documentSummary)

        Document sample:
        \(samples)

        Return JSON:
        {"primaryGenreID":"","secondaryGenreIDs":[],"genreConfidence":0.0,"intent":"","audience":"","formality":"","whyThisGenre":"","formatSignals":[],"missingSignals":[]}
        """
    }

    public static func structurePrompt(
        segment: ImpactSegment,
        rubric: ImpactGenreRubric,
        classification: ImpactGenreClassification,
        responseLanguage: GrammarlessLanguageMode = .zh
    ) -> String {
        """
        Task: analyze local structure and format for one segment.
        \(languageRequirement(responseLanguage))
        Genre: \(rubric.label) / \(rubric.id)
        Intent: \(classification.intent)
        Audience: \(classification.audience)
        Format requirements: \(rubric.formatRequirements.joined(separator: " | "))
        Dimension prompts:
        purposeClarity: \(rubric.dimensionPrompts[.purposeClarity] ?? "")
        structureLogic: \(rubric.dimensionPrompts[.structureLogic] ?? "")
        genreFit: \(rubric.dimensionPrompts[.genreFit] ?? "")

        segmentID: \(segment.id)
        paragraphIDs: \(segment.paragraphIDs.joined(separator: ","))
        segmentText:
        \(segment.text)

        Return JSON:
        {"segmentID":"\(segment.id)","paragraphIDs":[],"localRole":"","expectedRoleForGenre":"","servesDocumentPurpose":true,"structureIssue":"","formatIssue":"","recommendedMove":""}
        """
    }

    public static func localLogicPrompt(
        segment: ImpactSegment,
        rubric: ImpactGenreRubric,
        classification: ImpactGenreClassification,
        responseLanguage: GrammarlessLanguageMode = .zh
    ) -> String {
        """
        Task: analyze single-segment logic and evidence.
        \(languageRequirement(responseLanguage))
        Genre: \(rubric.label) / \(rubric.id)
        Intent: \(classification.intent)
        Audience: \(classification.audience)
        Evidence expectations: \(rubric.dimensionPrompts[.evidenceSufficiency] ?? "")

        Core logic model: claim, evidence, warrant, assumption, gap, contradiction.
        For fiction, evidence means character motivation, setup, consequence, and scene continuity.
        For legal/policy/medical, evidence requirements are strict.

        segmentID: \(segment.id)
        paragraphIDs: \(segment.paragraphIDs.joined(separator: ","))
        segmentText:
        \(segment.text)

        Return JSON:
        {"segmentID":"\(segment.id)","mainClaim":"","localEvidence":[],"logicGap":"","overclaim":"","internalContradiction":"","evidenceStrength":"strong|medium|weak|missing","recommendedFix":""}
        """
    }

    public static func readerPrompt(
        segment: ImpactSegment,
        rubric: ImpactGenreRubric,
        classification: ImpactGenreClassification,
        responseLanguage: GrammarlessLanguageMode = .zh
    ) -> String {
        """
        Task: simulate reader reaction for one segment.
        \(languageRequirement(responseLanguage))
        Genre: \(rubric.label)
        Audience: \(classification.audience)
        Intent: \(classification.intent)
        Reader rubric: \(rubric.dimensionPrompts[.readerReaction] ?? "")

        segmentID: \(segment.id)
        paragraphIDs: \(segment.paragraphIDs.joined(separator: ","))
        segmentText:
        \(segment.text)

        Return JSON:
        {"segmentID":"\(segment.id)","likelyTakeaway":"","likelyConfusion":"","likelyObjection":"","trustLevel":"high|medium|low","nextActionClarity":"clear|unclear|missing","emotionalReaction":"","recommendedFix":""}
        """
    }

    public static func clarityPrompt(
        segment: ImpactSegment,
        rubric: ImpactGenreRubric,
        classification: ImpactGenreClassification,
        responseLanguage: GrammarlessLanguageMode = .zh
    ) -> String {
        """
        Task: analyze language clarity for one segment.
        \(languageRequirement(responseLanguage))
        Genre: \(rubric.label)
        Language requirements: \(rubric.languageRequirements.joined(separator: " | "))
        Clarity rubric: \(rubric.dimensionPrompts[.languageClarity] ?? "")

        Check long sentences, vague references, weak verbs, redundancy, passive phrasing, term inconsistency, unnecessary complex words, too hard/soft tone, and genre mismatch.

        segmentID: \(segment.id)
        paragraphIDs: \(segment.paragraphIDs.joined(separator: ","))
        segmentText:
        \(segment.text)

        Return JSON:
        {"segmentID":"\(segment.id)","clarityIssues":[{"type":"","severity":"medium","original":"","replacement":"","explanation":"","recommendation":""}],"readabilityRisk":"low|medium|high","styleFitRisk":"low|medium|high","recommendedFix":""}
        Rules for clarityIssues:
        - original must be copied exactly from segmentText.
        - replacement must be the exact improved wording in the selected response language that can replace original in-place.
        - Leave replacement empty only when the issue is structural or cannot be safely replaced locally.
        """
    }

    public static func globalLogicPrompt(
        chunks: [[ImpactSegment]],
        rubric: ImpactGenreRubric,
        classification: ImpactGenreClassification,
        documentLengthUTF16: Int,
        responseLanguage: GrammarlessLanguageMode = .zh
    ) -> String {
        let chunkText = chunks.enumerated().map { chunkIndex, segments in
            let body = segments.map { segment in
                "[\(segment.id) paragraphs=\(segment.paragraphIDs.joined(separator: ","))]\n\(segment.text)"
            }.joined(separator: "\n\n")
            return "CHUNK \(chunkIndex + 1)\n\(body)"
        }.joined(separator: "\n\n---\n\n")
        return """
        Task: analyze cross-paragraph logic and evidence using the provided segment context.
        \(languageRequirement(responseLanguage))
        If documentLengthUTF16 > 200000, the context is a paragraph-boundary hard chunk and you must also flag unresolved cross-chunk references.

        Genre: \(rubric.label) / \(rubric.id)
        Intent: \(classification.intent)
        Audience: \(classification.audience)
        documentLengthUTF16: \(documentLengthUTF16)
        Evidence rubric: \(rubric.dimensionPrompts[.evidenceSufficiency] ?? "")
        Structure rubric: \(rubric.dimensionPrompts[.structureLogic] ?? "")

        Segments:
        \(chunkText)

        Analyze:
        - global claims
        - which segments support or weaken each claim
        - unsupported claims
        - contradictions
        - repeated ideas
        - missing bridges across segments
        - reader questions caused by cross-paragraph gaps

        Return JSON:
        {"globalClaims":[{"claimID":"c001","claim":"","introducedIn":"","supportedBy":[],"weakenedBy":[],"evidenceStrength":"strong|medium|weak|missing","gap":"","readerQuestion":""}],"crossParagraphGaps":[],"contradictions":[],"redundancies":[],"missingBridges":[],"globalLogicSummary":""}
        """
    }

    public static func reducerPrompt(
        segmentation: ImpactSegmentationResult,
        rubric: ImpactGenreRubric,
        classification: ImpactGenreClassification,
        structure: [ImpactSegmentStructureResult],
        globalLogic: ImpactGlobalLogicResult,
        localLogic: [ImpactLocalLogicResult],
        readers: [ImpactReaderReactionResult],
        clarity: [ImpactLanguageClarityResult],
        failures: [ImpactAnalysisFailure],
        responseLanguage: GrammarlessLanguageMode = .zh
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func json<T: Encodable>(_ value: T) -> String {
            guard let data = try? encoder.encode(value) else { return "null" }
            return String(decoding: data, as: UTF8.self)
        }
        return """
        Task: synthesize a complete Grammarless Increase Impact report.
        \(languageRequirement(responseLanguage))

        Inputs:
        genreRubric: \(json(rubric))
        genreClassification: \(json(classification))
        segmentationSummary: {"documentLengthUTF16":\(segmentation.documentLengthUTF16),"paragraphCount":\(segmentation.paragraphs.count),"segmentCount":\(segmentation.segments.count),"usedGrammarAwareSegmentation":\(segmentation.usedGrammarAwareSegmentation)}
        structureResults: \(json(structure))
        globalLogicResult: \(json(globalLogic))
        localLogicResults: \(json(localLogic))
        readerReactionResults: \(json(readers))
        languageClarityResults: \(json(clarity))
        analysisFailures: \(json(failures))

        Your job:
        1. Produce one coherent impact report.
        2. Score exactly six dimensions: purposeClarity, structureLogic, evidenceSufficiency, readerReaction, genreFit, languageClarity.
        3. Prioritize issues that reduce the document's ability to achieve its purpose.
        4. Distinguish quick wins from deep structural revisions.
        5. Do not invent issues not supported by inputs; if a path or segment failed, explicitly lower confidence rather than filling the gap.
        6. Use the selected response language for every user-facing report field. Keep exact document quotes, IDs, and schema keys unchanged.

        Return strict JSON:
        {"overallScore":0,"oneSentenceDiagnosis":"","executiveSummary":"","scores":[{"dimension":"purposeClarity","score":0,"reason":"","topFix":"","confidence":0.0}],"topFindings":[{"dimension":"purposeClarity","severity":"high","segmentIDs":[],"paragraphIDs":[],"title":"","explanation":"","evidence":"","recommendation":"","confidence":0.0}],"quickWins":[],"deeperRevisions":[],"readerSummary":"","structureSummary":"","logicSummary":"","doNotChange":[]}
        """
    }

    private static func languageRequirement(_ language: GrammarlessLanguageMode) -> String {
        """
        Selected response language: \(language.promptLanguageName).
        \(language.promptLanguageInstruction)
        """
    }

    private static func sampledSegments(_ segments: [ImpactSegment], maxCount: Int) -> String {
        guard segments.count > maxCount else {
            return segments.map { "[\($0.id)]\n\($0.text)" }.joined(separator: "\n\n")
        }
        let head = Array(segments.prefix(3))
        let tail = Array(segments.suffix(3))
        let middleIndex = max(0, segments.count / 2)
        let middle = [segments[middleIndex]]
        return (head + middle + tail).map { "[\($0.id)]\n\($0.text)" }.joined(separator: "\n\n")
    }
}

public enum ImpactParsing {
    private struct BoundaryEnvelope: Decodable { let cuts: [Int] }

    private static func jsonObject(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImpactAnalysisError.partialAnalysisFailed("Impact JSON was not an object.")
        }
        return object
    }

    private static func string(_ object: [String: Any], _ key: String, default defaultValue: String = "") -> String {
        if let value = object[key] as? String { return value }
        if let value = object[key] as? CustomStringConvertible { return value.description }
        return defaultValue
    }

    private static func stringArray(_ object: [String: Any], _ key: String) -> [String] {
        if let values = object[key] as? [Any] {
            return values.compactMap { value in
                if let value = value as? String { return value }
                if let value = value as? CustomStringConvertible { return value.description }
                return nil
            }
        }
        if let value = object[key] {
            let text: String?
            if let value = value as? String {
                text = value
            } else if let value = value as? CustomStringConvertible {
                text = value.description
            } else {
                text = nil
            }
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? [] : [trimmed]
        }
        return []
    }

    private static func objectArray(_ object: [String: Any], _ key: String) -> [[String: Any]] {
        if let values = object[key] as? [Any] {
            return values.compactMap { $0 as? [String: Any] }
        }
        if let value = object[key] as? [String: Any] { return [value] }
        return []
    }

    private static func bool(_ object: [String: Any], _ key: String, default defaultValue: Bool = false) -> Bool {
        if let value = object[key] as? Bool { return value }
        if let value = object[key] as? NSNumber { return value.boolValue }
        if let value = object[key] as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: break
            }
        }
        return defaultValue
    }

    private static func double(_ object: [String: Any], _ key: String, default defaultValue: Double = 0) -> Double {
        if let value = object[key] as? Double { return value }
        if let value = object[key] as? Int { return Double(value) }
        if let value = object[key] as? NSNumber { return value.doubleValue }
        if let value = object[key] as? String,
           let numeric = firstNumber(in: value)
        {
            return numeric
        }
        return defaultValue
    }

    private static func int(_ object: [String: Any], _ key: String, default defaultValue: Int = 0) -> Int {
        if let value = object[key] as? Int { return value }
        if let value = object[key] as? NSNumber { return value.intValue }
        if let value = object[key] as? String,
           let numeric = firstNumber(in: value)
        {
            return Int(numeric.rounded())
        }
        return defaultValue
    }

    private static func firstNumber(in text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = Double(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "%"))) {
            return direct
        }
        guard let range = trimmed.range(of: #"[-+]?\d+(\.\d+)?"#, options: .regularExpression) else {
            return nil
        }
        return Double(trimmed[range])
    }

    private static func clampedScore(_ value: Int) -> Int {
        min(100, max(0, value))
    }

    private static func confidence(_ object: [String: Any], _ key: String = "confidence") -> Double {
        let value = double(object, key, default: 0)
        let normalized = (value > 1 && value <= 100) ? value / 100 : value
        return min(1, max(0, normalized))
    }

    private static func normalizedIdentifier(_ text: String) -> String {
        text
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
            .map(String.init)
            .joined()
    }

    private static func dimension(from text: String) -> ImpactDimension? {
        let normalized = normalizedIdentifier(text)
        return ImpactDimension.allCases.first { dimension in
            normalizedIdentifier(dimension.rawValue) == normalized ||
                normalizedIdentifier(dimension.displayName) == normalized
        }
    }

    private static func severity(_ object: [String: Any], default defaultValue: ImpactSeverity = .medium) -> ImpactSeverity {
        let normalized = normalizedIdentifier(string(object, "severity"))
        return ImpactSeverity.allCases.first { normalizedIdentifier($0.rawValue) == normalized } ?? defaultValue
    }

    private static func scalar(at index: Int, in text: NSString) -> UnicodeScalar? {
        guard index >= 0, index < text.length else { return nil }
        return text.substring(with: NSRange(location: index, length: 1)).unicodeScalars.first
    }

    private static func isTokenScalar(_ scalar: UnicodeScalar?) -> Bool {
        guard let scalar else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }

    private static func isTokenBoundaryAligned(_ range: NSRange, in text: NSString) -> Bool {
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length > 0,
              NSMaxRange(range) <= text.length else {
            return false
        }
        let first = scalar(at: range.location, in: text)
        let last = scalar(at: NSMaxRange(range) - 1, in: text)
        if range.location > 0,
           isTokenScalar(scalar(at: range.location - 1, in: text)),
           isTokenScalar(first)
        {
            return false
        }
        if NSMaxRange(range) < text.length,
           isTokenScalar(last),
           isTokenScalar(scalar(at: NSMaxRange(range), in: text))
        {
            return false
        }
        return true
    }

    public static func parseBoundaryCuts(_ content: String) throws -> [Int] {
        let data = try ReviewParsing.extractJSONObject(from: content)
        return try JSONDecoder().decode(BoundaryEnvelope.self, from: data).cuts
    }

    public static func parseGenreClassification(_ content: String) throws -> ImpactGenreClassification {
        let data = try ReviewParsing.extractJSONObject(from: content)
        return try JSONDecoder().decode(ImpactGenreClassification.self, from: data)
    }

    public static func parseStructure(_ content: String, fallbackSegment: ImpactSegment) throws -> ImpactSegmentStructureResult {
        let data = try ReviewParsing.extractJSONObject(from: content)
        let object = try jsonObject(from: data)
        return ImpactSegmentStructureResult(
            segmentID: string(object, "segmentID", default: fallbackSegment.id),
            paragraphIDs: stringArray(object, "paragraphIDs").isEmpty ? fallbackSegment.paragraphIDs : stringArray(object, "paragraphIDs"),
            localRole: string(object, "localRole"),
            expectedRoleForGenre: string(object, "expectedRoleForGenre"),
            servesDocumentPurpose: bool(object, "servesDocumentPurpose", default: true),
            structureIssue: string(object, "structureIssue"),
            formatIssue: string(object, "formatIssue"),
            recommendedMove: string(object, "recommendedMove")
        )
    }

    public static func parseLocalLogic(_ content: String, fallbackSegment: ImpactSegment) throws -> ImpactLocalLogicResult {
        let data = try ReviewParsing.extractJSONObject(from: content)
        let object = try jsonObject(from: data)
        return ImpactLocalLogicResult(
            segmentID: string(object, "segmentID", default: fallbackSegment.id),
            mainClaim: string(object, "mainClaim"),
            localEvidence: stringArray(object, "localEvidence"),
            logicGap: string(object, "logicGap"),
            overclaim: string(object, "overclaim"),
            internalContradiction: string(object, "internalContradiction"),
            evidenceStrength: string(object, "evidenceStrength"),
            recommendedFix: string(object, "recommendedFix")
        )
    }

    public static func parseReader(_ content: String, fallbackSegment: ImpactSegment) throws -> ImpactReaderReactionResult {
        let data = try ReviewParsing.extractJSONObject(from: content)
        let object = try jsonObject(from: data)
        return ImpactReaderReactionResult(
            segmentID: string(object, "segmentID", default: fallbackSegment.id),
            likelyTakeaway: string(object, "likelyTakeaway"),
            likelyConfusion: string(object, "likelyConfusion"),
            likelyObjection: string(object, "likelyObjection"),
            trustLevel: string(object, "trustLevel"),
            nextActionClarity: string(object, "nextActionClarity"),
            emotionalReaction: string(object, "emotionalReaction"),
            recommendedFix: string(object, "recommendedFix")
        )
    }

    public static func parseClarity(_ content: String, fallbackSegment: ImpactSegment) throws -> ImpactLanguageClarityResult {
        let data = try ReviewParsing.extractJSONObject(from: content)
        let object = try jsonObject(from: data)
        let issues = objectArray(object, "clarityIssues").map { issue in
            ImpactLanguageClarityIssue(
                type: string(issue, "type"),
                severity: severity(issue),
                original: string(issue, "original"),
                replacement: {
                    let replacement = string(issue, "replacement").trimmingCharacters(in: .whitespacesAndNewlines)
                    return replacement.isEmpty ? nil : replacement
                }(),
                explanation: string(issue, "explanation"),
                recommendation: string(issue, "recommendation")
            )
        }
        return ImpactLanguageClarityResult(
            segmentID: string(object, "segmentID", default: fallbackSegment.id),
            clarityIssues: issues,
            readabilityRisk: string(object, "readabilityRisk"),
            styleFitRisk: string(object, "styleFitRisk"),
            recommendedFix: string(object, "recommendedFix")
        )
    }

    public static func parseGlobalLogic(_ content: String) throws -> ImpactGlobalLogicResult {
        let data = try ReviewParsing.extractJSONObject(from: content)
        let object = try jsonObject(from: data)
        let claims = objectArray(object, "globalClaims").map { item in
            ImpactGlobalClaim(
                claimID: string(item, "claimID", default: UUID().uuidString),
                claim: string(item, "claim"),
                introducedIn: string(item, "introducedIn"),
                supportedBy: stringArray(item, "supportedBy"),
                weakenedBy: stringArray(item, "weakenedBy"),
                evidenceStrength: string(item, "evidenceStrength"),
                gap: string(item, "gap"),
                readerQuestion: string(item, "readerQuestion")
            )
        }
        return ImpactGlobalLogicResult(
            globalClaims: claims,
            crossParagraphGaps: stringArray(object, "crossParagraphGaps"),
            contradictions: stringArray(object, "contradictions"),
            redundancies: stringArray(object, "redundancies"),
            missingBridges: stringArray(object, "missingBridges"),
            globalLogicSummary: string(object, "globalLogicSummary")
        )
    }

    public static func parseReducerReport(
        _ content: String,
        snapshot: TextSnapshot,
        segmentation: ImpactSegmentationResult,
        classification: ImpactGenreClassification,
        rubric: ImpactGenreRubric,
        structure: [ImpactSegmentStructureResult],
        globalLogic: ImpactGlobalLogicResult,
        localLogic: [ImpactLocalLogicResult],
        readers: [ImpactReaderReactionResult],
        clarity: [ImpactLanguageClarityResult],
        failures: [ImpactAnalysisFailure] = []
    ) throws -> DocumentImpactReport {
        let data: Data
        do {
            data = try ReviewParsing.extractJSONObject(from: content)
        } catch {
            throw ImpactAnalysisError.partialAnalysisFailed("Reducer output was not valid JSON: \(error.localizedDescription)")
        }
        let object = try jsonObject(from: data)
        var analysisFailures = failures

        if object["overallScore"] == nil {
            analysisFailures.append(
                ImpactAnalysisFailure(
                    path: .reducer,
                    message: "Reducer output omitted overallScore; showing score 0 instead of inventing a value."
                )
            )
        }

        let scoreObjects = objectArray(object, "scores")
        if scoreObjects.isEmpty {
            analysisFailures.append(
                ImpactAnalysisFailure(
                    path: .reducer,
                    message: "Reducer output omitted dimension scores; empty low-confidence score cards were inserted."
                )
            )
        }
        var parsedScores: [ImpactDimension: ImpactScore] = [:]
        for item in scoreObjects {
            let rawDimension = string(item, "dimension")
            guard let dimension = dimension(from: rawDimension) else {
                analysisFailures.append(
                    ImpactAnalysisFailure(
                        path: .reducer,
                        message: "Reducer returned an unknown score dimension: \(rawDimension.isEmpty ? "<missing>" : rawDimension)."
                    )
                )
                continue
            }
            guard parsedScores[dimension] == nil else {
                analysisFailures.append(
                    ImpactAnalysisFailure(
                        path: .reducer,
                        message: "Reducer returned duplicate score dimension: \(dimension.rawValue); the first value was kept."
                    )
                )
                continue
            }
            parsedScores[dimension] = ImpactScore(
                dimension: dimension,
                score: clampedScore(int(item, "score")),
                reason: string(item, "reason"),
                topFix: string(item, "topFix"),
                confidence: confidence(item)
            )
        }
        let scores = ImpactDimension.allCases.map { dimension -> ImpactScore in
            if let score = parsedScores[dimension] { return score }
            analysisFailures.append(
                ImpactAnalysisFailure(
                    path: .reducer,
                    message: "Reducer output omitted \(dimension.rawValue); no synthetic analysis was generated for that card."
                )
            )
            return ImpactScore(
                dimension: dimension,
                score: 0,
                reason: "Reducer output did not include this dimension.",
                topFix: "",
                confidence: 0
            )
        }

        let findings = objectArray(object, "topFindings").compactMap { item -> ImpactFinding? in
            let rawDimension = string(item, "dimension")
            guard let dimension = dimension(from: rawDimension) else {
                analysisFailures.append(
                    ImpactAnalysisFailure(
                        path: .reducer,
                        message: "Reducer returned a top finding with unknown dimension: \(rawDimension.isEmpty ? "<missing>" : rawDimension)."
                    )
                )
                return nil
            }
            return ImpactFinding(
                dimension: dimension,
                severity: severity(item),
                segmentIDs: stringArray(item, "segmentIDs"),
                paragraphIDs: stringArray(item, "paragraphIDs"),
                title: string(item, "title"),
                explanation: string(item, "explanation"),
                evidence: string(item, "evidence"),
                recommendation: string(item, "recommendation"),
                confidence: confidence(item)
            )
        }
        let patchCandidates = languagePatchCandidates(
            snapshot: snapshot,
            segmentation: segmentation,
            clarity: clarity
        )
        return DocumentImpactReport(
            snapshotRevision: snapshot.revision,
            documentLengthUTF16: (snapshot.fullText as NSString).length,
            segmentation: segmentation,
            genreClassification: classification,
            primaryGenre: rubric,
            overallScore: clampedScore(int(object, "overallScore")),
            oneSentenceDiagnosis: string(object, "oneSentenceDiagnosis"),
            executiveSummary: string(object, "executiveSummary"),
            scores: scores,
            topFindings: findings,
            structureResults: structure,
            globalLogicResult: globalLogic,
            localLogicResults: localLogic,
            readerReactionResults: readers,
            languageClarityResults: clarity,
            quickWins: stringArray(object, "quickWins"),
            deeperRevisions: stringArray(object, "deeperRevisions"),
            readerSummary: string(object, "readerSummary"),
            structureSummary: string(object, "structureSummary"),
            logicSummary: string(object, "logicSummary"),
            doNotChange: stringArray(object, "doNotChange"),
            analysisFailures: analysisFailures,
            patchCandidates: patchCandidates
        )
    }

    private static func languagePatchCandidates(
        snapshot: TextSnapshot,
        segmentation: ImpactSegmentationResult,
        clarity: [ImpactLanguageClarityResult]
    ) -> [TextPatch] {
        var patches: [TextPatch] = []
        let nsText = snapshot.fullText as NSString
        let segmentsByID = Dictionary(uniqueKeysWithValues: segmentation.segments.map { ($0.id, $0) })
        for result in clarity {
            guard let segment = segmentsByID[result.segmentID] else { continue }
            let segmentText = segment.text as NSString
            for issue in result.clarityIssues {
                guard patches.count < 12 else { return patches }
                let original = issue.original.trimmingCharacters(in: .whitespacesAndNewlines)
                let replacement = (issue.replacement ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !original.isEmpty,
                      !replacement.isEmpty,
                      original != replacement,
                      (original as NSString).length <= 320,
                      (replacement as NSString).length <= 640 else { continue }
                let localRange = segmentText.range(of: original)
                guard localRange.location != NSNotFound else { continue }
                let nextSearchLocation = localRange.location + localRange.length
                let nextRange = segmentText.range(
                    of: original,
                    options: [],
                    range: NSRange(
                        location: nextSearchLocation,
                        length: max(0, segmentText.length - nextSearchLocation)
                    )
                )
                guard nextRange.location == NSNotFound else { continue }
                let fullRange = NSRange(
                    location: segment.rangeInFullText.location + localRange.location,
                    length: localRange.length
                )
                guard NSMaxRange(fullRange) <= nsText.length,
                      nsText.substring(with: fullRange) == original,
                      isTokenBoundaryAligned(fullRange, in: nsText) else { continue }
                let reason = [
                    "Impact language clarity",
                    issue.type,
                    issue.explanation.isEmpty ? issue.recommendation : issue.explanation,
                ]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                let patch = TextPatch(
                    rangeInFullText: fullRange,
                    originalText: original,
                    replacementText: replacement,
                    reason: reason
                )
                if patch.validate(against: snapshot.fullText),
                   !patches.contains(where: { $0.rangeInFullText == patch.rangeInFullText && $0.replacementText == patch.replacementText })
                {
                    patches.append(patch)
                }
            }
        }
        return patches
    }
}

private enum ImpactPartialOutcome<Value> {
    case success(Value)
    case failure(ImpactAnalysisFailure)
}

public final class ImpactAnalysisOrchestrator {
    private let llmClient: LLMReviewing
    private let segmenter: ImpactDocumentSegmenter
    private let maxConcurrentSegmentAnalyses: Int
    private let globalLogicHardLimitUTF16: Int

    public init(
        llmClient: LLMReviewing,
        segmenter: ImpactDocumentSegmenter = ImpactDocumentSegmenter(),
        maxConcurrentSegmentAnalyses: Int = 6,
        globalLogicHardLimitUTF16: Int = 200_000
    ) {
        self.llmClient = llmClient
        self.segmenter = segmenter
        self.maxConcurrentSegmentAnalyses = maxConcurrentSegmentAnalyses
        self.globalLogicHardLimitUTF16 = globalLogicHardLimitUTF16
    }

    public func run(
        snapshot: TextSnapshot,
        configuration: AppConfiguration,
        memoryContext: WritingMemoryContext,
        progressHandler: ImpactAnalysisProgressHandler? = nil
    ) async throws -> DocumentImpactReport {
        let language = configuration.uiLanguage
        await emitProgress(
            progressHandler,
            path: .segmentation,
            completed: 0,
            total: 1,
            message: ui(language, "Segmenting the document by paragraphs…", zh: "正在按段落切分全文…")
        )
        let segmentation = try await segmenter.segment(text: snapshot.fullText) { [llmClient] windowText, windowStart in
            let content = try await llmClient.performImpactStep(
                systemPrompt: ImpactPromptBuilder.boundarySystemPrompt(),
                userPrompt: ImpactPromptBuilder.boundaryUserPrompt(
                    windowText: windowText,
                    windowStart: windowStart,
                    windowLength: (windowText as NSString).length
                ),
                configuration: configuration,
                timeout: max(configuration.actionTimeoutSeconds, 120)
            )
            return try ImpactParsing.parseBoundaryCuts(content)
        }
        await emitProgress(
            progressHandler,
            path: .segmentation,
            completed: 1,
            total: 1,
            message: ui(language, "Segmentation complete: \(segmentation.segments.count) analysis segments.", zh: "切分完成：\(segmentation.segments.count) 个分析段落。")
        )

        await emitProgress(
            progressHandler,
            path: .genreClassification,
            completed: 0,
            total: 1,
            message: ui(language, "Identifying genre, purpose, and reader…", zh: "正在识别文体、目的和读者…")
        )
        let classificationContent = try await llmClient.performImpactStep(
            systemPrompt: ImpactPromptBuilder.impactSystemPrompt(responseLanguage: configuration.uiLanguage),
            userPrompt: ImpactPromptBuilder.genrePrompt(
                segmentation: segmentation,
                languageHint: snapshot.languageHint,
                memoryContext: memoryContext,
                responseLanguage: configuration.uiLanguage
            ),
            configuration: configuration,
            timeout: max(configuration.actionTimeoutSeconds, 120)
        )
        let classification = try ImpactParsing.parseGenreClassification(classificationContent)
        guard let rubric = ImpactGenreRegistry.rubric(id: classification.primaryGenreID) else {
            throw ImpactAnalysisError.unknownGenre(classification.primaryGenreID)
        }
        await emitProgress(
            progressHandler,
            path: .genreClassification,
            completed: 1,
            total: 1,
            message: ui(language, "Genre identified: \(localizedRubricLabel(rubric, language: language)).", zh: "文体识别完成：\(rubric.label)。")
        )

        async let globalLogicBundle = analyzeGlobalLogic(
            segmentation: segmentation,
            rubric: rubric,
            classification: classification,
            configuration: configuration,
            progressHandler: progressHandler
        )
        async let structureBundle = analyzeSegmentPath(
            segmentation.segments,
            path: .structureFormat,
            label: ui(language, "structure and format", zh: "结构与格式"),
            configuration: configuration
        ) { [self] segment in
            let content = try await llmClient.performImpactStep(
                systemPrompt: ImpactPromptBuilder.impactSystemPrompt(responseLanguage: configuration.uiLanguage),
                userPrompt: ImpactPromptBuilder.structurePrompt(segment: segment, rubric: rubric, classification: classification, responseLanguage: configuration.uiLanguage),
                configuration: configuration,
                timeout: max(configuration.actionTimeoutSeconds, 90)
            )
            return try ImpactParsing.parseStructure(content, fallbackSegment: segment)
        } progressHandler: {
            progressHandler
        }
        async let localLogicBundle = analyzeSegmentPath(
            segmentation.segments,
            path: .localLogicEvidence,
            label: ui(language, "local logic and evidence", zh: "单段逻辑与证据"),
            configuration: configuration
        ) { [self] segment in
            let content = try await llmClient.performImpactStep(
                systemPrompt: ImpactPromptBuilder.impactSystemPrompt(responseLanguage: configuration.uiLanguage),
                userPrompt: ImpactPromptBuilder.localLogicPrompt(segment: segment, rubric: rubric, classification: classification, responseLanguage: configuration.uiLanguage),
                configuration: configuration,
                timeout: max(configuration.actionTimeoutSeconds, 90)
            )
            return try ImpactParsing.parseLocalLogic(content, fallbackSegment: segment)
        } progressHandler: {
            progressHandler
        }
        async let readersBundle = analyzeSegmentPath(
            segmentation.segments,
            path: .readerReaction,
            label: ui(language, "reader reaction", zh: "读者反应"),
            configuration: configuration
        ) { [self] segment in
            let content = try await llmClient.performImpactStep(
                systemPrompt: ImpactPromptBuilder.impactSystemPrompt(responseLanguage: configuration.uiLanguage),
                userPrompt: ImpactPromptBuilder.readerPrompt(segment: segment, rubric: rubric, classification: classification, responseLanguage: configuration.uiLanguage),
                configuration: configuration,
                timeout: max(configuration.actionTimeoutSeconds, 90)
            )
            return try ImpactParsing.parseReader(content, fallbackSegment: segment)
        } progressHandler: {
            progressHandler
        }
        async let clarityBundle = analyzeSegmentPath(
            segmentation.segments,
            path: .languageClarity,
            label: ui(language, "language clarity", zh: "语言清晰度"),
            configuration: configuration
        ) { [self] segment in
            let content = try await llmClient.performImpactStep(
                systemPrompt: ImpactPromptBuilder.impactSystemPrompt(responseLanguage: configuration.uiLanguage),
                userPrompt: ImpactPromptBuilder.clarityPrompt(segment: segment, rubric: rubric, classification: classification, responseLanguage: configuration.uiLanguage),
                configuration: configuration,
                timeout: max(configuration.actionTimeoutSeconds, 90)
            )
            return try ImpactParsing.parseClarity(content, fallbackSegment: segment)
        } progressHandler: {
            progressHandler
        }

        let (resolvedGlobalLogic, globalFailures) = try await globalLogicBundle
        let (resolvedStructure, structureFailures) = try await structureBundle
        let (resolvedLocalLogic, localLogicFailures) = try await localLogicBundle
        let (resolvedReaders, readerFailures) = try await readersBundle
        let (resolvedClarity, clarityFailures) = try await clarityBundle
        let analysisFailures = globalFailures + structureFailures + localLogicFailures + readerFailures + clarityFailures
        if !analysisFailures.isEmpty,
           resolvedStructure.isEmpty,
           resolvedLocalLogic.isEmpty,
           resolvedReaders.isEmpty,
           resolvedClarity.isEmpty,
           resolvedGlobalLogic.globalClaims.isEmpty,
           resolvedGlobalLogic.crossParagraphGaps.isEmpty,
           resolvedGlobalLogic.contradictions.isEmpty,
           resolvedGlobalLogic.redundancies.isEmpty,
           resolvedGlobalLogic.missingBridges.isEmpty
        {
            throw ImpactAnalysisError.partialAnalysisFailed(ui(language, "All analysis paths failed; no fake report was generated.", zh: "所有分析路径都失败，未生成伪报告。"))
        }

        await emitProgress(
            progressHandler,
            path: .reducer,
            completed: 0,
            total: 1,
            message: ui(language, "Synthesizing all paths into the final Impact report…", zh: "正在汇总四条路径，生成最终 Impact 报告…")
        )
        let reducerContent = try await llmClient.performImpactStep(
            systemPrompt: ImpactPromptBuilder.impactSystemPrompt(responseLanguage: configuration.uiLanguage),
            userPrompt: ImpactPromptBuilder.reducerPrompt(
                segmentation: segmentation,
                rubric: rubric,
                classification: classification,
                structure: resolvedStructure,
                globalLogic: resolvedGlobalLogic,
                localLogic: resolvedLocalLogic,
                readers: resolvedReaders,
                clarity: resolvedClarity,
                failures: analysisFailures,
                responseLanguage: configuration.uiLanguage
            ),
            configuration: configuration,
            timeout: max(configuration.actionTimeoutSeconds, 180)
        )

        let report = try ImpactParsing.parseReducerReport(
            reducerContent,
            snapshot: snapshot,
            segmentation: segmentation,
            classification: classification,
            rubric: rubric,
            structure: resolvedStructure,
            globalLogic: resolvedGlobalLogic,
            localLogic: resolvedLocalLogic,
            readers: resolvedReaders,
            clarity: resolvedClarity,
            failures: analysisFailures
        )
        await emitProgress(
            progressHandler,
            path: .reducer,
            completed: 1,
            total: 1,
            message: ui(language, "Impact report generated.", zh: "Impact 报告已生成。")
        )
        return report
    }

    private func analyzeGlobalLogic(
        segmentation: ImpactSegmentationResult,
        rubric: ImpactGenreRubric,
        classification: ImpactGenreClassification,
        configuration: AppConfiguration,
        progressHandler: ImpactAnalysisProgressHandler?
    ) async throws -> (ImpactGlobalLogicResult, [ImpactAnalysisFailure]) {
        let language = configuration.uiLanguage
        let chunks = globalLogicChunks(for: segmentation.segments)
        if chunks.count == 1 {
            await emitProgress(
                progressHandler,
                path: .globalLogicEvidence,
                completed: 0,
                total: 1,
                message: ui(language, "Analyzing cross-paragraph logic and evidence…", zh: "正在分析跨段落逻辑与证据…")
            )
            do {
                let content = try await llmClient.performImpactStep(
                    systemPrompt: ImpactPromptBuilder.impactSystemPrompt(responseLanguage: configuration.uiLanguage),
                    userPrompt: ImpactPromptBuilder.globalLogicPrompt(
                        chunks: chunks,
                        rubric: rubric,
                        classification: classification,
                        documentLengthUTF16: segmentation.documentLengthUTF16,
                        responseLanguage: configuration.uiLanguage
                    ),
                    configuration: configuration,
                    timeout: max(configuration.actionTimeoutSeconds, 180)
                )
                await emitProgress(
                    progressHandler,
                    path: .globalLogicEvidence,
                    completed: 1,
                    total: 1,
                    message: ui(language, "Cross-paragraph logic and evidence analysis complete.", zh: "跨段落逻辑与证据分析完成。")
                )
                return (try ImpactParsing.parseGlobalLogic(content), [])
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                await emitProgress(
                    progressHandler,
                    path: .globalLogicEvidence,
                    completed: 1,
                    total: 1,
                    message: ui(language, "Cross-paragraph logic path failed and was recorded.", zh: "跨段落逻辑路径失败，已显式记录。")
                )
                return (
                    ImpactGlobalLogicResult(globalLogicSummary: ui(language, "Global logic analysis failed; see analysisFailures.", zh: "跨段落逻辑分析失败；详见 analysisFailures。")),
                    [
                        ImpactAnalysisFailure(
                            path: .globalLogicEvidence,
                            message: error.localizedDescription
                        ),
                    ]
                )
            }
        }

        let (partials, failures): ([ImpactGlobalLogicResult], [ImpactAnalysisFailure]) = try await analyzeItemsAllowingPartialFailures(
            chunks,
            path: .globalLogicEvidence,
            label: ui(language, "cross-paragraph logic chunks", zh: "跨段落逻辑分块"),
            language: language,
            progressHandler: progressHandler,
            failureDescriptor: { chunk in
                let first = chunk.first?.id ?? "unknown"
                let last = chunk.last?.id ?? first
                return ("\(first)-\(last)", chunk.flatMap(\.paragraphIDs))
            }
        ) { [self] chunk in
            let content = try await llmClient.performImpactStep(
                systemPrompt: ImpactPromptBuilder.impactSystemPrompt(responseLanguage: configuration.uiLanguage),
                userPrompt: ImpactPromptBuilder.globalLogicPrompt(
                    chunks: [chunk],
                    rubric: rubric,
                    classification: classification,
                    documentLengthUTF16: segmentation.documentLengthUTF16,
                    responseLanguage: configuration.uiLanguage
                ),
                configuration: configuration,
                timeout: max(configuration.actionTimeoutSeconds, 180)
            )
            return try ImpactParsing.parseGlobalLogic(content)
        }
        return (mergeGlobalLogic(partials), failures)
    }

    private func globalLogicChunks(for segments: [ImpactSegment]) -> [[ImpactSegment]] {
        var chunks: [[ImpactSegment]] = []
        var current: [ImpactSegment] = []
        var currentLength = 0
        for segment in segments {
            let segmentLength = (segment.text as NSString).length
            if !current.isEmpty, currentLength + segmentLength > globalLogicHardLimitUTF16 {
                chunks.append(current)
                current = []
                currentLength = 0
            }
            current.append(segment)
            currentLength += segmentLength
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private func mergeGlobalLogic(_ partials: [ImpactGlobalLogicResult]) -> ImpactGlobalLogicResult {
        ImpactGlobalLogicResult(
            globalClaims: partials.flatMap(\.globalClaims),
            crossParagraphGaps: partials.flatMap(\.crossParagraphGaps),
            contradictions: partials.flatMap(\.contradictions),
            redundancies: partials.flatMap(\.redundancies),
            missingBridges: partials.flatMap(\.missingBridges),
            globalLogicSummary: partials.map(\.globalLogicSummary).filter { !$0.isEmpty }.joined(separator: "\n")
        )
    }

    private func analyzeSegmentPath<U>(
        _ segments: [ImpactSegment],
        path: ImpactAnalysisPath,
        label: String,
        configuration: AppConfiguration,
        operation: @escaping (ImpactSegment) async throws -> U,
        progressHandler: () -> ImpactAnalysisProgressHandler?
    ) async throws -> ([U], [ImpactAnalysisFailure]) {
        try await analyzeItemsAllowingPartialFailures(
            segments,
            path: path,
            label: label,
            language: configuration.uiLanguage,
            progressHandler: progressHandler(),
            failureDescriptor: { segment in (segment.id, segment.paragraphIDs) },
            operation: operation
        )
    }

    private func analyzeItemsAllowingPartialFailures<T, U>(
        _ items: [T],
        path: ImpactAnalysisPath,
        label: String,
        language: GrammarlessLanguageMode,
        progressHandler: ImpactAnalysisProgressHandler?,
        failureDescriptor: @escaping (T) -> (segmentID: String?, paragraphIDs: [String]),
        operation: @escaping (T) async throws -> U
    ) async throws -> ([U], [ImpactAnalysisFailure]) {
        guard !items.isEmpty else { return ([], []) }
        await emitProgress(
            progressHandler,
            path: path,
            completed: 0,
            total: items.count,
            message: progressMessage(label: label, completed: 0, total: items.count, language: language)
        )
        var outcomes: [(Int, ImpactPartialOutcome<U>)] = []
        var cursor = 0
        while cursor < items.count {
            let batch = Array(items[cursor..<min(cursor + maxConcurrentSegmentAnalyses, items.count)])
            let batchResults = try await withThrowingTaskGroup(of: (Int, ImpactPartialOutcome<U>).self) { group in
                for (offset, item) in batch.enumerated() {
                    let absoluteOffset = cursor + offset
                    group.addTask {
                        do {
                            try Task.checkCancellation()
                            return (absoluteOffset, .success(try await operation(item)))
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            let descriptor = failureDescriptor(item)
                            return (
                                absoluteOffset,
                                .failure(
                                    ImpactAnalysisFailure(
                                        path: path,
                                        segmentID: descriptor.segmentID,
                                        paragraphIDs: descriptor.paragraphIDs,
                                        message: error.localizedDescription
                                    )
                                )
                            )
                        }
                    }
                }
                var resolved: [(Int, ImpactPartialOutcome<U>)] = []
                for try await result in group {
                    resolved.append(result)
                    let completed = outcomes.count + resolved.count
                    await emitProgress(
                        progressHandler,
                        path: path,
                        completed: completed,
                        total: items.count,
                        message: progressMessage(label: label, completed: completed, total: items.count, language: language)
                    )
                }
                return resolved.sorted { $0.0 < $1.0 }
            }
            outcomes.append(contentsOf: batchResults)
            cursor += batch.count
        }
        let sorted = outcomes.sorted { $0.0 < $1.0 }
        var values: [U] = []
        var failures: [ImpactAnalysisFailure] = []
        for (_, outcome) in sorted {
            switch outcome {
            case .success(let value):
                values.append(value)
            case .failure(let failure):
                failures.append(failure)
            }
        }
        return (values, failures)
    }

    private func emitProgress(
        _ handler: ImpactAnalysisProgressHandler?,
        path: ImpactAnalysisPath,
        completed: Int,
        total: Int,
        message: String
    ) async {
        await handler?(
            ImpactAnalysisProgress(
                path: path,
                completed: completed,
                total: total,
                message: message
            )
        )
    }

    private func progressMessage(label: String, completed: Int, total: Int, language: GrammarlessLanguageMode) -> String {
        ui(language, "Analyzing \(label) (\(completed)/\(total))…", zh: "正在分析\(label)（\(completed)/\(total)）…")
    }

    private func ui(_ language: GrammarlessLanguageMode, _ english: String, zh chinese: String) -> String {
        language == .zh ? chinese : english
    }

    private func localizedRubricLabel(_ rubric: ImpactGenreRubric, language: GrammarlessLanguageMode) -> String {
        guard language == .en else { return rubric.label }
        return rubric.id
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

import Foundation

public struct NormalizedText: Equatable {
    public let original: String
    public let normalized: String
    public let normalizedToOriginalUTF16: [Int: Int]
}

public enum TextNormalizer {
    public static func normalize(_ text: String) -> NormalizedText {
        var normalized = ""
        var mapping: [Int: Int] = [:]
        var originalUTF16Offset = 0
        var normalizedUTF16Offset = 0

        for scalar in text.unicodeScalars {
            let originalCharacter = String(scalar)
            let normalizedCharacter = normalizeScalar(scalar)
            mapping[normalizedUTF16Offset] = originalUTF16Offset
            normalized += normalizedCharacter
            originalUTF16Offset += (originalCharacter as NSString).length
            normalizedUTF16Offset += (normalizedCharacter as NSString).length
        }

        mapping[normalizedUTF16Offset] = originalUTF16Offset
        return NormalizedText(
            original: text,
            normalized: normalized,
            normalizedToOriginalUTF16: mapping
        )
    }

    private static func normalizeScalar(_ scalar: UnicodeScalar) -> String {
        let value = scalar.value
        if (0xFF10...0xFF19).contains(value), let mapped = UnicodeScalar(value - 0xFF10 + 0x30) {
            return String(mapped)
        }
        if (0xFF21...0xFF3A).contains(value), let mapped = UnicodeScalar(value - 0xFF21 + 0x41) {
            return String(mapped)
        }
        if (0xFF41...0xFF5A).contains(value), let mapped = UnicodeScalar(value - 0xFF41 + 0x61) {
            return String(mapped)
        }
        if value == 0x3000 { return " " }
        return String(scalar)
    }
}

public struct ProofSentence: Equatable {
    public let text: String
    public let rangeInFullText: NSRange
}

public enum SentenceSegmenter {
    private static let terminalScalars = Set("。！？!?；;\n".unicodeScalars)

    public static func segment(_ text: String, baseRange: NSRange) -> [ProofSentence] {
        let nsText = text as NSString
        guard nsText.length > 0 else { return [] }

        var sentences: [ProofSentence] = []
        var start = 0
        var utf16Offset = 0
        for scalar in text.unicodeScalars {
            let scalarLength = (String(scalar) as NSString).length
            let nextOffset = utf16Offset + scalarLength
            if terminalScalars.contains(scalar) {
                appendSentence(in: text, localRange: NSRange(location: start, length: nextOffset - start), baseRange: baseRange, to: &sentences)
                start = nextOffset
            }
            utf16Offset = nextOffset
        }
        if start < nsText.length {
            appendSentence(in: text, localRange: NSRange(location: start, length: nsText.length - start), baseRange: baseRange, to: &sentences)
        }
        return sentences
    }

    private static func appendSentence(in text: String, localRange: NSRange, baseRange: NSRange, to sentences: inout [ProofSentence]) {
        let nsText = text as NSString
        guard localRange.length > 0, NSMaxRange(localRange) <= nsText.length else { return }
        let raw = nsText.substring(with: localRange)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sentences.append(
            ProofSentence(
                text: raw,
                rangeInFullText: NSRange(location: baseRange.location + localRange.location, length: localRange.length)
            )
        )
    }
}

public struct ProofIssueAdjudication: Equatable, Codable {
    public enum Decision: String, Codable {
        case accept
        case reject
        case revise
    }

    public var issueID: UUID
    public var decision: Decision
    public var replacementText: String?
    public var confidence: Double?
    public var explanation: String?

    public init(
        issueID: UUID,
        decision: Decision,
        replacementText: String? = nil,
        confidence: Double? = nil,
        explanation: String? = nil
    ) {
        self.issueID = issueID
        self.decision = decision
        self.replacementText = replacementText
        self.confidence = confidence
        self.explanation = explanation
    }

    private enum CodingKeys: String, CodingKey {
        case issueID
        case issueId
        case id
        case decision
        case replacementText
        case confidence
        case explanation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        issueID = try container.decodeIfPresent(UUID.self, forKey: .issueID) ??
            container.decodeIfPresent(UUID.self, forKey: .issueId) ??
            container.decode(UUID.self, forKey: .id)
        decision = try container.decode(Decision.self, forKey: .decision)
        replacementText = try container.decodeIfPresent(String.self, forKey: .replacementText)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        explanation = try container.decodeIfPresent(String.self, forKey: .explanation)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(issueID, forKey: .issueID)
        try container.encode(decision, forKey: .decision)
        try container.encodeIfPresent(replacementText, forKey: .replacementText)
        try container.encodeIfPresent(confidence, forKey: .confidence)
        try container.encodeIfPresent(explanation, forKey: .explanation)
    }
}

public enum LLMAdjudicator {
    private struct DecisionEnvelope: Decodable {
        let decisions: [ProofIssueAdjudication]
    }

    public static func parseDecisions(from content: String) -> [ProofIssueAdjudication] {
        let decoder = JSONDecoder()
        let candidates = jsonPayloadCandidates(from: content)
        for payload in candidates {
            let data = Data(payload.utf8)
            if let array = try? decoder.decode([ProofIssueAdjudication].self, from: data) {
                return array
            }
            if let envelope = try? decoder.decode(DecisionEnvelope.self, from: data) {
                return envelope.decisions
            }
        }
        return []
    }

    public static func apply(decisions: [ProofIssueAdjudication], to issues: [ProofIssue]) -> [ProofIssue] {
        var decisionsByID: [UUID: ProofIssueAdjudication] = [:]
        for decision in decisions {
            decisionsByID[decision.issueID] = decision
        }
        return issues.compactMap { issue in
            guard let decision = decisionsByID[issue.id] else {
                return issue.needsLLMAdjudication ? nil : issue
            }
            switch decision.decision {
            case .reject:
                return nil
            case .accept:
                var accepted = issue
                if let confidence = decision.confidence {
                    accepted.confidence = min(max(confidence, 0), 1)
                }
                if let explanation = decision.explanation, !explanation.isEmpty {
                    accepted.explanation = explanation
                }
                return accepted.isNoOpReplacement ? nil : accepted
            case .revise:
                var revised = issue
                if let replacement = decision.replacementText, !replacement.isEmpty {
                    revised.replacementText = replacement
                }
                if let confidence = decision.confidence {
                    revised.confidence = min(max(confidence, 0), 1)
                }
                if let explanation = decision.explanation, !explanation.isEmpty {
                    revised.explanation = explanation
                }
                return revised.isNoOpReplacement ? nil : revised
            }
        }
    }

    private static func jsonPayloadCandidates(from content: String) -> [String] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var candidates = [trimmed]
        if let fenced = trimmed.range(of: #"```(?:json)?\s*([\s\S]*?)```"#, options: .regularExpression) {
            let block = String(trimmed[fenced])
                .replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
            candidates.insert(block.trimmingCharacters(in: .whitespacesAndNewlines), at: 0)
        }
        if let start = trimmed.firstIndex(where: { $0 == "[" || $0 == "{" }),
           let end = trimmed.lastIndex(where: { $0 == "]" || $0 == "}" }),
           start < end {
            candidates.append(String(trimmed[start...end]))
        }
        return candidates
    }
}

public final class ProofreadingPipeline {
    private let lexicon: ProofreadingLexicon

    public init(lexicon: ProofreadingLexicon = .default) {
        self.lexicon = lexicon
    }

    public func issues(for snapshot: TextSnapshot) -> [ProofIssue] {
        _ = TextNormalizer.normalize(snapshot.analysisText)
        var issues: [ProofIssue] = []
        let analysisBaseRange = snapshot.analysisRangeInFullText

        issues += DeterministicDetectors.detect(in: snapshot.analysisText, analysisRangeInFullText: analysisBaseRange, lexicon: lexicon)
        if snapshot.languageHint != .en {
            issues += ConfusionCandidateGenerator.detectChinese(in: snapshot.analysisText, analysisRangeInFullText: analysisBaseRange, lexicon: lexicon)
            issues += GrammarRuleDetector.detectChinese(in: snapshot.analysisText, analysisRangeInFullText: analysisBaseRange)
        }
        if snapshot.languageHint != .zh {
            issues += ConfusionCandidateGenerator.detectEnglish(in: snapshot.analysisText, analysisRangeInFullText: analysisBaseRange, lexicon: lexicon)
            issues += GrammarRuleDetector.detectEnglish(in: snapshot.analysisText, analysisRangeInFullText: analysisBaseRange)
        }
        return IssueMerger.merge(issues)
    }

    public func suggestions(for snapshot: TextSnapshot) -> [Suggestion] {
        let paragraphIdentity = snapshot.paragraphIdentity
        return issues(for: snapshot).compactMap { $0.asSuggestion(paragraphIdentity: paragraphIdentity) }
    }
}

public enum IssueMerger {
    public static func merge(_ issues: [ProofIssue]) -> [ProofIssue] {
        let filtered = issues.filter { issue in
            guard issue.rangeInFullText.location != NSNotFound, issue.rangeInFullText.length > 0 else { return false }
            guard (0...1).contains(issue.confidence) else { return false }
            return !issue.isNoOpReplacement
        }
        let sorted = filtered.sorted(by: issueComesBefore(_:_:))
        var merged: [ProofIssue] = []
        var seen = Set<String>()

        for issue in sorted {
            let key = "\(issue.kind.rawValue)|\(issue.rangeInFullText.location)|\(issue.rangeInFullText.length)|\(issue.replacementText ?? "")"
            guard seen.insert(key).inserted else { continue }
            if let overlappingIndex = merged.firstIndex(where: { rangesOverlap($0.rangeInFullText, issue.rangeInFullText) }) {
                if issueBeats(issue, merged[overlappingIndex]) {
                    merged[overlappingIndex] = issue
                }
            } else {
                merged.append(issue)
            }
        }
        return merged.sorted(by: issueComesBefore(_:_:))
    }

    private static func rangesOverlap(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        NSIntersectionRange(lhs, rhs).length > 0
    }

    private static func issueBeats(_ lhs: ProofIssue, _ rhs: ProofIssue) -> Bool {
        if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
        if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
        if lhs.rangeInFullText.length != rhs.rangeInFullText.length { return lhs.rangeInFullText.length < rhs.rangeInFullText.length }
        return lhs.explanation.count > rhs.explanation.count
    }

    private static func issueComesBefore(_ lhs: ProofIssue, _ rhs: ProofIssue) -> Bool {
        if lhs.rangeInFullText.location != rhs.rangeInFullText.location {
            return lhs.rangeInFullText.location < rhs.rangeInFullText.location
        }
        if lhs.rangeInFullText.length != rhs.rangeInFullText.length {
            return lhs.rangeInFullText.length < rhs.rangeInFullText.length
        }
        if lhs.severity != rhs.severity {
            return lhs.severity > rhs.severity
        }
        if lhs.confidence != rhs.confidence {
            return lhs.confidence > rhs.confidence
        }
        return lhs.kind.rawValue < rhs.kind.rawValue
    }
}

public struct ProofreadingLexicon {
    public struct ConfusionEntry: Codable, Equatable {
        public var source: String
        public var candidates: [String]
        public var kind: ProofIssueKind
        public var tip: String
        public var confidence: Double
    }

    public struct ReplacementEntry: Codable, Equatable {
        public var source: String
        public var replacement: String
        public var kind: ProofIssueKind
        public var tip: String
        public var confidence: Double
    }

    public let zhConfusions: [ConfusionEntry]
    public let enConfusions: [ConfusionEntry]
    public let pinyinConfusions: [ReplacementEntry]
    public let glyphConfusions: [ReplacementEntry]
    public let properNouns: [ReplacementEntry]
    public let adminDivisions: [ReplacementEntry]
    public let leaderTitles: [ReplacementEntry]

    public static let `default` = ProofreadingLexicon(
        zhConfusions: loadConfusions(named: "confusion_zh", fallback: [
            .init(source: "截止目前", candidates: ["截至目前"], kind: .confusableWord, tip: "“截至”后接时间点表示到某时为止；“截止”强调停止。", confidence: 0.88),
            .init(source: "权力义务", candidates: ["权利义务"], kind: .confusableWord, tip: "“权利”指依法享有的利益；“权力”指支配力量或职权。", confidence: 0.90),
            .init(source: "制订政策", candidates: ["制定政策"], kind: .confusableWord, tip: "“制定”更常用于政策、法令、制度。", confidence: 0.88),
        ]),
        enConfusions: loadConfusions(named: "confusion_en", fallback: [
            .init(source: "their is", candidates: ["there is"], kind: .confusableWord, tip: "Use “there” for existence/location; “their” is possessive.", confidence: 0.91),
            .init(source: "effect the", candidates: ["affect the"], kind: .confusableWord, tip: "Use “affect” as a verb meaning to influence.", confidence: 0.88),
        ]),
        pinyinConfusions: loadReplacements(named: "pinyin_confusions", fallback: [
            .init(source: "我门", replacement: "我们", kind: .phoneticSimilarChar, tip: "“们”用于人称复数，“门”是名词。", confidence: 0.99),
            .init(source: "在次", replacement: "再次", kind: .phoneticSimilarChar, tip: "表示又一次时应写作“再次”。", confidence: 0.96),
            .init(source: "慢慢的走", replacement: "慢慢地走", kind: .phoneticSimilarChar, tip: "“地”用于修饰动作。", confidence: 0.90),
            .init(source: "以经", replacement: "已经", kind: .phoneticSimilarChar, tip: "“已经”表示事情完成或发生。", confidence: 0.98),
        ]),
        glyphConfusions: loadReplacements(named: "glyph_confusions", fallback: [
            .init(source: "己经", replacement: "已经", kind: .visualSimilarChar, tip: "“己/已/巳”形近，此处应为“已经”。", confidence: 0.97),
            .init(source: "末来", replacement: "未来", kind: .visualSimilarChar, tip: "“未/末”形近，此处应为“未来”。", confidence: 0.97),
            .init(source: "辩认", replacement: "辨认", kind: .visualSimilarChar, tip: "“辩/辨/辫/瓣”形近，此处应为“辨认”。", confidence: 0.95),
        ]),
        properNouns: loadReplacements(named: "proper_nouns", fallback: [
            .init(source: "OpenAi", replacement: "OpenAI", kind: .properNoun, tip: "专有名词大小写应统一为 OpenAI。", confidence: 0.99),
        ]),
        adminDivisions: loadReplacements(named: "admin_divisions", fallback: [
            .init(source: "郫县", replacement: "郫都区", kind: .adminDivision, tip: "郫县已撤县设区，更名为郫都区。", confidence: 0.99),
        ]),
        leaderTitles: loadReplacements(named: "leader_titles", fallback: [
            .init(source: "张三主任", replacement: "张三局长", kind: .leaderTitle, tip: "本地测试词库显示张三当前称谓应为“局长”。", confidence: 0.98),
        ])
    )

    public init(
        zhConfusions: [ConfusionEntry],
        enConfusions: [ConfusionEntry],
        pinyinConfusions: [ReplacementEntry],
        glyphConfusions: [ReplacementEntry],
        properNouns: [ReplacementEntry],
        adminDivisions: [ReplacementEntry],
        leaderTitles: [ReplacementEntry]
    ) {
        self.zhConfusions = zhConfusions
        self.enConfusions = enConfusions
        self.pinyinConfusions = pinyinConfusions
        self.glyphConfusions = glyphConfusions
        self.properNouns = properNouns
        self.adminDivisions = adminDivisions
        self.leaderTitles = leaderTitles
    }

    private static func loadConfusions(named name: String, fallback: [ConfusionEntry]) -> [ConfusionEntry] {
        loadJSONLines(named: name, as: ConfusionEntry.self) ?? fallback
    }

    private static func loadReplacements(named name: String, fallback: [ReplacementEntry]) -> [ReplacementEntry] {
        loadJSONLines(named: name, as: ReplacementEntry.self) ?? fallback
    }

    private static func loadJSONLines<T: Decodable>(named name: String, as type: T.Type) -> [T]? {
        guard let content = ResourceLoader.text(named: name, fileExtension: "jsonl") else { return nil }
        let decoder = JSONDecoder()
        let rows = content.split(separator: "\n").compactMap { line -> T? in
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            return try? decoder.decode(T.self, from: Data(trimmed.utf8))
        }
        return rows.isEmpty ? nil : rows
    }
}

private final class ResourceBundleProbe {}

private enum ResourceLoader {
    static func text(named name: String, fileExtension ext: String) -> String? {
        let bundles = [Bundle(for: ResourceBundleProbe.self), Bundle.main]
        for bundle in bundles {
            let urls = [
                bundle.url(forResource: name, withExtension: ext, subdirectory: "Proofreading"),
                bundle.url(forResource: name, withExtension: ext),
                bundle.url(forResource: name, withExtension: ext, subdirectory: "Resources/Proofreading"),
            ]
            for url in urls.compactMap({ $0 }) {
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    return content
                }
            }
        }
        return nil
    }
}

private enum ConfusionCandidateGenerator {
    static func detectChinese(in text: String, analysisRangeInFullText: NSRange, lexicon: ProofreadingLexicon) -> [ProofIssue] {
        var issues: [ProofIssue] = []
        issues += lexicon.pinyinConfusions.flatMap { replacementIssues(entry: $0, text: text, baseRange: analysisRangeInFullText, detectorSource: "pinyin_confusions") }
        issues += lexicon.glyphConfusions.flatMap { replacementIssues(entry: $0, text: text, baseRange: analysisRangeInFullText, detectorSource: "glyph_confusions") }
        issues += lexicon.zhConfusions.flatMap { confusionIssues(entry: $0, text: text, baseRange: analysisRangeInFullText, detectorSource: "confusion_zh") }
        return issues
    }

    static func detectEnglish(in text: String, analysisRangeInFullText: NSRange, lexicon: ProofreadingLexicon) -> [ProofIssue] {
        lexicon.enConfusions.flatMap { confusionIssues(entry: $0, text: text, baseRange: analysisRangeInFullText, detectorSource: "confusion_en") }
    }

    private static func replacementIssues(entry: ProofreadingLexicon.ReplacementEntry, text: String, baseRange: NSRange, detectorSource: String) -> [ProofIssue] {
        ranges(of: entry.source, in: text).map { range in
            makeIssue(
                kind: entry.kind,
                severity: .warning,
                localRange: range,
                text: text,
                baseRange: baseRange,
                replacement: entry.replacement,
                confidence: entry.confidence,
                detectorSource: detectorSource,
                explanation: "疑似\(entry.kind.rawValue)：“\(entry.source)”建议改为“\(entry.replacement)”。",
                advancedTip: entry.tip,
                autofixSafe: entry.confidence >= 0.96,
                evidence: ["entrySource": entry.source, "entryReplacement": entry.replacement]
            )
        }
    }

    private static func confusionIssues(entry: ProofreadingLexicon.ConfusionEntry, text: String, baseRange: NSRange, detectorSource: String) -> [ProofIssue] {
        let replacement = entry.candidates.first ?? entry.source
        return ranges(of: entry.source, in: text).map { range in
            makeIssue(
                kind: entry.kind,
                severity: .warning,
                localRange: range,
                text: text,
                baseRange: baseRange,
                replacement: replacement,
                confidence: entry.confidence,
                detectorSource: detectorSource,
                explanation: "疑似易混淆表达：“\(entry.source)”可考虑“\(replacement)”。",
                advancedTip: entry.tip,
                autofixSafe: false,
                evidence: ["confusionSet": ([entry.source] + entry.candidates).joined(separator: "/")]
            )
        }
    }
}

private enum GrammarRuleDetector {
    static func detectChinese(in text: String, analysisRangeInFullText: NSRange) -> [ProofIssue] {
        let rules: [(pattern: String, replacement: String?, kind: ProofIssueKind, severity: ProofIssueSeverity, confidence: Double, explanation: String, tip: String, autofix: Bool)] = [
            (#"尽快的去"#, "尽快", .grammarRedundant, .warning, 0.99, "“的去”在这里冗余。", "去掉冗余成分，表达更简洁。", true),
            (#"一下下"#, "一下", .styleRedundancy, .info, 0.97, "“一下下”偏口语，正式文本中可简化。", "长文或正式写作中建议使用更简洁表达。", true),
            (#"通过[^。！？\n]{1,30}使"#, nil, .grammarMissing, .warning, 0.74, "“通过……使……”结构可能造成主语缺失。", "建议检查主语是否明确。", false),
            (#"把[^。！？\n]{1,20}被"#, nil, .grammarDisorder, .warning, 0.78, "“把”和“被”结构混用，语序可能不当。", "建议改写为清晰的主动或被动结构。", false),
            (#"非常十分"#, "非常", .grammarRedundant, .warning, 0.97, "“非常”和“十分”语义重复。", "保留其中一个程度副词即可。", true),
            (#"进行优化一下"#, "优化一下", .grammarSelection, .warning, 0.92, "“进行”与后面的口语化补语搭配不自然。", "可去掉“进行”，或整体改成更正式表达。", true),
        ]
        return regexRuleIssues(rules: rules, text: text, baseRange: analysisRangeInFullText, detectorSource: "grammar_rule_zh")
    }

    static func detectEnglish(in text: String, analysisRangeInFullText: NSRange) -> [ProofIssue] {
        let rules: [(pattern: String, replacement: String?, kind: ProofIssueKind, severity: ProofIssueSeverity, confidence: Double, explanation: String, tip: String, autofix: Bool)] = [
            (#"(?i)\b(?:he|she|it)\s+(do not knows)\b"#, "does not know", .grammarSelection, .warning, 0.99, "Use singular agreement here.", "After he/she/it, use “does not know”.", true),
            (#"(?i)\b(?:he|she|it)\s+(do not know)\b"#, "does not know", .grammarSelection, .warning, 0.99, "Use singular agreement here.", "After he/she/it, use “does not know”.", true),
            (#"(?i)\b(?:he|she|it)\s+(don't knows)\b"#, "doesn't know", .grammarSelection, .warning, 0.99, "Use singular agreement here.", "Use “doesn't know”.", true),
            (#"(?i)\b(does not knows)\b"#, "does not know", .grammarSelection, .warning, 0.99, "Use the base verb after does not.", "The verb after “does not” should be base form.", true),
            (#"(?i)\b(do not knows)\b"#, "do not know", .grammarSelection, .warning, 0.95, "Use the base verb after do not.", "The verb after “do not” should be base form.", true),
            (#"(?i)\b(the the)\b"#, "the", .grammarRedundant, .warning, 0.99, "Duplicated word.", "Remove the repeated word.", true),
        ]
        return regexRuleIssues(rules: rules, text: text, baseRange: analysisRangeInFullText, detectorSource: "grammar_rule_en")
    }

    private static func regexRuleIssues(
        rules: [(pattern: String, replacement: String?, kind: ProofIssueKind, severity: ProofIssueSeverity, confidence: Double, explanation: String, tip: String, autofix: Bool)],
        text: String,
        baseRange: NSRange,
        detectorSource: String
    ) -> [ProofIssue] {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var issues: [ProofIssue] = []
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            for match in regex.matches(in: text, range: fullRange) {
                let localRange = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range
                let original = nsText.substring(with: localRange)
                let replacement = rule.replacement ?? inferredReplacement(for: original, kind: rule.kind)
                issues.append(makeIssue(
                    kind: rule.kind,
                    severity: rule.severity,
                    localRange: localRange,
                    text: text,
                    baseRange: baseRange,
                    replacement: replacement,
                    confidence: rule.confidence,
                    detectorSource: detectorSource,
                    explanation: rule.explanation,
                    advancedTip: rule.tip,
                    autofixSafe: rule.autofix,
                    evidence: ["pattern": rule.pattern, "matchedText": original]
                ))
            }
        }
        return issues
    }

    private static func inferredReplacement(for original: String, kind: ProofIssueKind) -> String? {
        switch kind {
        case .grammarMissing where original.hasPrefix("通过") && original.contains("使"):
            return String(original.dropFirst("通过".count))
        case .grammarDisorder where original.hasPrefix("把") && original.contains("被"):
            return String(original.dropFirst("把".count))
        default:
            return nil
        }
    }
}

private enum DeterministicDetectors {
    static func detect(in text: String, analysisRangeInFullText: NSRange, lexicon: ProofreadingLexicon) -> [ProofIssue] {
        var issues: [ProofIssue] = []
        issues += DateDetector.detect(in: text, baseRange: analysisRangeInFullText)
        issues += AmountDetector.detect(in: text, baseRange: analysisRangeInFullText)
        issues += PunctuationDetector.detect(in: text, baseRange: analysisRangeInFullText)
        issues += SequenceNumberDetector.detect(in: text, baseRange: analysisRangeInFullText)
        issues += DuplicateDefinitionDetector.detect(in: text, baseRange: analysisRangeInFullText)
        issues += lexicon.properNouns.flatMap { replacementIssues(entry: $0, text: text, baseRange: analysisRangeInFullText, detectorSource: "proper_nouns") }
        issues += lexicon.adminDivisions.flatMap { replacementIssues(entry: $0, text: text, baseRange: analysisRangeInFullText, detectorSource: "admin_divisions") }
        issues += lexicon.leaderTitles.flatMap { replacementIssues(entry: $0, text: text, baseRange: analysisRangeInFullText, detectorSource: "leader_titles") }
        return issues
    }

    private static func replacementIssues(entry: ProofreadingLexicon.ReplacementEntry, text: String, baseRange: NSRange, detectorSource: String) -> [ProofIssue] {
        ranges(of: entry.source, in: text).map { range in
            makeIssue(
                kind: entry.kind,
                severity: .critical,
                localRange: range,
                text: text,
                baseRange: baseRange,
                replacement: entry.replacement,
                confidence: entry.confidence,
                detectorSource: detectorSource,
                explanation: "本地词库建议将“\(entry.source)”统一为“\(entry.replacement)”。",
                advancedTip: entry.tip,
                autofixSafe: entry.confidence >= 0.98,
                evidence: ["lexiconSource": entry.source, "lexiconReplacement": entry.replacement]
            )
        }
    }
}

private enum DateDetector {
    private static let weekdayMap: [String: Int] = ["日": 1, "天": 1, "一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7]
    private static let weekdayNames: [Int: String] = [1: "日", 2: "一", 3: "二", 4: "三", 5: "四", 6: "五", 7: "六"]

    static func detect(in text: String, baseRange: NSRange) -> [ProofIssue] {
        let patterns = [
            #"(\d{4})年(\d{1,2})月(\d{1,2})日(?:\s*星期([一二三四五六日天]))?"#,
            #"(\d{4})[-/](\d{1,2})[-/](\d{1,2})"#,
        ]
        var issues: [ProofIssue] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsText = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
                guard match.numberOfRanges >= 4 else { continue }
                let year = intCapture(match, 1, nsText)
                let month = intCapture(match, 2, nsText)
                let day = intCapture(match, 3, nsText)
                guard let year, let month, let day else { continue }
                let source = nsText.substring(with: match.range)
                if let date = makeDate(year: year, month: month, day: day) {
                    if match.numberOfRanges > 4, match.range(at: 4).location != NSNotFound {
                        let stated = nsText.substring(with: match.range(at: 4))
                        let actualWeekday = Calendar(identifier: .gregorian).component(.weekday, from: date)
                        if weekdayMap[stated] != actualWeekday, let actualName = weekdayNames[actualWeekday] {
                            let replacement = source.replacingOccurrences(of: "星期\(stated)", with: "星期\(actualName)")
                            issues.append(makeIssue(
                                kind: .date,
                                severity: .critical,
                                localRange: match.range,
                                text: text,
                                baseRange: baseRange,
                                replacement: replacement,
                                confidence: 0.99,
                                detectorSource: "date_detector",
                                explanation: "日期与星期不匹配。",
                                advancedTip: "\(year)年\(month)月\(day)日对应星期\(actualName)。",
                                autofixSafe: true,
                                evidence: ["actualWeekday": "星期\(actualName)", "statedWeekday": "星期\(stated)"]
                            ))
                        }
                    }
                } else {
                    let replacement = suggestedValidDate(year: year, month: month, day: day, source: source)
                    issues.append(makeIssue(
                        kind: .date,
                        severity: .critical,
                        localRange: match.range,
                        text: text,
                        baseRange: baseRange,
                        replacement: replacement,
                        confidence: 0.99,
                        detectorSource: "date_detector",
                        explanation: "日期不存在或不符合日历规则。",
                        advancedTip: "请核对月份天数、闰年和原始日期。",
                        autofixSafe: false,
                        evidence: ["year": "\(year)", "month": "\(month)", "day": "\(day)"]
                    ))
                }
            }
        }
        return issues
    }

    private static func makeDate(year: Int, month: Int, day: Int) -> Date? {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.year = year
        components.month = month
        components.day = day
        guard let date = components.date else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        return calendar.component(.year, from: date) == year &&
            calendar.component(.month, from: date) == month &&
            calendar.component(.day, from: date) == day ? date : nil
    }

    private static func suggestedValidDate(year: Int, month: Int, day: Int, source: String) -> String? {
        guard (1...12).contains(month) else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1
        guard let firstDay = calendar.date(from: components), let range = calendar.range(of: .day, in: .month, for: firstDay) else { return nil }
        let maxDay = range.count
        guard day > maxDay else { return nil }
        return source
            .replacingOccurrences(of: "\(month)月\(day)日", with: "\(month)月\(maxDay)日")
            .replacingOccurrences(of: String(format: "%02d-%02d", month, day), with: String(format: "%02d-%02d", month, maxDay))
            .replacingOccurrences(of: "\(month)-\(day)", with: "\(month)-\(maxDay)")
    }
}

private enum AmountDetector {
    static func detect(in text: String, baseRange: NSRange) -> [ProofIssue] {
        let nsText = text as NSString
        guard let chineseRegex = try? NSRegularExpression(pattern: #"[零壹贰叁肆伍陆柒捌玖拾佰仟万亿]+元整?"#),
              let arabicRegex = try? NSRegularExpression(pattern: #"[0-9][0-9,]*(?:\.[0-9]+)?\s*(?:万|亿)?\s*元"#)
        else { return [] }
        let fullRange = NSRange(location: 0, length: nsText.length)
        let chineseMatches = chineseRegex.matches(in: text, range: fullRange)
        let arabicMatches = arabicRegex.matches(in: text, range: fullRange)
        var issues: [ProofIssue] = []

        for chinese in chineseMatches {
            let chineseText = nsText.substring(with: chinese.range)
            guard let chineseAmount = parseChineseAmount(chineseText) else { continue }
            for arabic in arabicMatches where abs(arabic.range.location - chinese.range.location) <= 40 {
                let arabicText = nsText.substring(with: arabic.range)
                guard let arabicAmount = parseArabicAmount(arabicText), arabicAmount != chineseAmount else { continue }
                let replacement = "\(chineseAmount)元"
                issues.append(makeIssue(
                    kind: .amount,
                    severity: .critical,
                    localRange: arabic.range,
                    text: text,
                    baseRange: baseRange,
                    replacement: replacement,
                    confidence: 0.99,
                    detectorSource: "amount_detector",
                    explanation: "金额大小写表达不一致。",
                    advancedTip: "中文大写金额折算为 \(chineseAmount) 元，当前阿拉伯数字为 \(arabicAmount) 元。",
                    autofixSafe: false,
                    evidence: ["chineseAmount": "\(chineseAmount)", "arabicAmount": "\(arabicAmount)"]
                ))
            }
        }
        return issues
    }

    private static func parseArabicAmount(_ raw: String) -> Int? {
        let compact = raw.replacingOccurrences(of: " ", with: "")
        let multiplier: Double
        if compact.contains("亿元") {
            multiplier = 100_000_000
        } else if compact.contains("万元") {
            multiplier = 10_000
        } else {
            multiplier = 1
        }
        let number = compact
            .replacingOccurrences(of: "亿元", with: "")
            .replacingOccurrences(of: "万元", with: "")
            .replacingOccurrences(of: "元", with: "")
            .replacingOccurrences(of: ",", with: "")
        guard let value = Double(number) else { return nil }
        return Int((value * multiplier).rounded())
    }

    private static func parseChineseAmount(_ raw: String) -> Int? {
        let text = raw.replacingOccurrences(of: "元整", with: "").replacingOccurrences(of: "元", with: "")
        let digit: [Character: Int] = ["零": 0, "壹": 1, "贰": 2, "叁": 3, "肆": 4, "伍": 5, "陆": 6, "柒": 7, "捌": 8, "玖": 9]
        let unit: [Character: Int] = ["拾": 10, "佰": 100, "仟": 1000]
        var total = 0
        var section = 0
        var current = 0
        for char in text {
            if let d = digit[char] {
                current = d
            } else if let u = unit[char] {
                section += (current == 0 ? 1 : current) * u
                current = 0
            } else if char == "万" {
                section += current
                total += section * 10_000
                section = 0
                current = 0
            } else if char == "亿" {
                section += current
                total += section * 100_000_000
                section = 0
                current = 0
            }
        }
        return total + section + current
    }
}

private enum PunctuationDetector {
    static func detect(in text: String, baseRange: NSRange) -> [ProofIssue] {
        var issues: [ProofIssue] = []
        issues += capturedRegexIssues(
            pattern: #"[\u4e00-\u9fff](,)[\u4e00-\u9fff]"#,
            captureIndex: 1,
            text: text,
            baseRange: baseRange,
            replacement: "，",
            explanation: "中文句子中疑似使用了英文逗号。",
            tip: "中文正文中建议使用中文逗号。"
        )
        issues += regexIssues(pattern: #"[。！？!?]{2,}"#, text: text, baseRange: baseRange) { match, nsText in
            let source = nsText.substring(with: match.range)
            let first = source.first.map(String.init) ?? source
            return (first, "连续标点可能过多。", "正式写作中通常保留一个句末标点。")
        }
        issues += unclosedBracketIssues(in: text, baseRange: baseRange)
        return issues
    }

    private static func capturedRegexIssues(
        pattern: String,
        captureIndex: Int,
        text: String,
        baseRange: NSRange,
        replacement: String,
        explanation: String,
        tip: String
    ) -> [ProofIssue] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap { match in
            guard match.numberOfRanges > captureIndex, match.range(at: captureIndex).location != NSNotFound else {
                return nil
            }
            return makeIssue(
                kind: .punctuation,
                severity: .warning,
                localRange: match.range(at: captureIndex),
                text: text,
                baseRange: baseRange,
                replacement: replacement,
                confidence: 0.98,
                detectorSource: "punctuation_detector",
                explanation: explanation,
                advancedTip: tip,
                autofixSafe: true,
                evidence: ["pattern": pattern]
            )
        }
    }

    private static func regexIssues(
        pattern: String,
        text: String,
        baseRange: NSRange,
        replacement: (NSTextCheckingResult, NSString) -> (String, String, String)
    ) -> [ProofIssue] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).map { match in
            let result = replacement(match, nsText)
            return makeIssue(
                kind: .punctuation,
                severity: .warning,
                localRange: match.range,
                text: text,
                baseRange: baseRange,
                replacement: result.0,
                confidence: 0.97,
                detectorSource: "punctuation_detector",
                explanation: result.1,
                advancedTip: result.2,
                autofixSafe: true,
                evidence: ["pattern": pattern]
            )
        }
    }

    private static func unclosedBracketIssues(in text: String, baseRange: NSRange) -> [ProofIssue] {
        let pairs: [Character: Character] = ["（": "）", "(": ")", "“": "”", "《": "》"]
        var stack: [(Character, Int)] = []
        var offset = 0
        for char in text {
            if pairs.keys.contains(char) {
                stack.append((char, offset))
            } else if pairs.values.contains(char), !stack.isEmpty {
                stack.removeLast()
            }
            offset += (String(char) as NSString).length
        }
        guard let unclosed = stack.last else { return [] }
        let close = pairs[unclosed.0].map(String.init) ?? ""
        return [makeIssue(
            kind: .punctuation,
            severity: .warning,
            localRange: NSRange(location: unclosed.1, length: (String(unclosed.0) as NSString).length),
            text: text,
            baseRange: baseRange,
            replacement: String(unclosed.0) + close,
            confidence: 0.86,
            detectorSource: "punctuation_detector",
            explanation: "括号或引号可能未闭合。",
            advancedTip: "请补齐对应的闭合标点。",
            autofixSafe: false,
            evidence: ["opening": String(unclosed.0), "expectedClosing": close]
        )]
    }
}

private enum SequenceNumberDetector {
    static func detect(in text: String, baseRange: NSRange) -> [ProofIssue] {
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^\s*(\d+)[\.、]"#) else { return [] }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var expected: Int?
        var issues: [ProofIssue] = []
        for match in matches where match.numberOfRanges > 1 {
            guard let actual = Int(nsText.substring(with: match.range(at: 1))) else { continue }
            if expected == nil { expected = actual }
            if let currentExpected = expected, actual != currentExpected {
                issues.append(makeIssue(
                    kind: .sequenceNumber,
                    severity: .critical,
                    localRange: match.range(at: 1),
                    text: text,
                    baseRange: baseRange,
                    replacement: "\(currentExpected)",
                    confidence: 0.98,
                    detectorSource: "sequence_number_detector",
                    explanation: "序号疑似跳号或重复。",
                    advancedTip: "当前层级期望序号为 \(currentExpected)，实际为 \(actual)。",
                    autofixSafe: false,
                    evidence: ["expected": "\(currentExpected)", "actual": "\(actual)"]
                ))
                expected = actual + 1
            } else {
                expected = actual + 1
            }
        }
        return issues
    }
}

private enum DuplicateDefinitionDetector {
    static func detect(in text: String, baseRange: NSRange) -> [ProofIssue] {
        guard let regex = try? NSRegularExpression(pattern: #"([^，。；\n（）()]{2,20})[（(](?:以下简称|下称)([^）)]+)[）)]"#) else { return [] }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var firstByAlias: [String: String] = [:]
        var issues: [ProofIssue] = []
        for match in matches where match.numberOfRanges > 2 {
            let term = nsText.substring(with: match.range(at: 1))
            let alias = nsText.substring(with: match.range(at: 2))
            if let firstTerm = firstByAlias[alias], firstTerm != term {
                issues.append(makeIssue(
                    kind: .duplicateDefinition,
                    severity: .critical,
                    localRange: match.range(at: 2),
                    text: text,
                    baseRange: baseRange,
                    replacement: "\(alias)2",
                    confidence: 0.94,
                    detectorSource: "duplicate_definition_detector",
                    explanation: "同一简称被用于不同定义。",
                    advancedTip: "“\(alias)”已先用于“\(firstTerm)”，这里又用于“\(term)”。自动建议仅为占位，请人工统一简称。",
                    autofixSafe: false,
                    evidence: ["alias": alias, "firstTerm": firstTerm, "currentTerm": term]
                ))
            } else {
                firstByAlias[alias] = term
            }
        }
        return issues
    }
}

private func ranges(of needle: String, in text: String) -> [NSRange] {
    let nsText = text as NSString
    var ranges: [NSRange] = []
    var searchRange = NSRange(location: 0, length: nsText.length)
    while searchRange.length > 0 {
        let found = nsText.range(of: needle, options: [], range: searchRange)
        guard found.location != NSNotFound else { break }
        ranges.append(found)
        let nextLocation = found.location + max(found.length, 1)
        searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
    }
    return ranges
}

private func makeIssue(
    kind: ProofIssueKind,
    severity: ProofIssueSeverity,
    localRange: NSRange,
    text: String,
    baseRange: NSRange,
    replacement: String?,
    confidence: Double,
    detectorSource: String,
    explanation: String,
    advancedTip: String?,
    autofixSafe: Bool,
    evidence: [String: String]
) -> ProofIssue {
    let nsText = text as NSString
    let source = NSMaxRange(localRange) <= nsText.length ? nsText.substring(with: localRange) : ""
    return ProofIssue(
        kind: kind,
        severity: severity,
        rangeInFullText: ParagraphContextExtractor.mapAnalysisRangeToFullText(
            analysisRange: localRange,
            analysisRangeInFullText: baseRange
        ),
        sourceText: source,
        replacementText: replacement,
        confidence: min(max(confidence, 0), 1),
        detectorSource: detectorSource,
        explanation: explanation,
        advancedTip: advancedTip,
        autofixSafe: autofixSafe,
        evidence: evidence
    )
}

private func intCapture(_ match: NSTextCheckingResult, _ index: Int, _ text: NSString) -> Int? {
    guard match.numberOfRanges > index, match.range(at: index).location != NSNotFound else { return nil }
    return Int(text.substring(with: match.range(at: index)))
}

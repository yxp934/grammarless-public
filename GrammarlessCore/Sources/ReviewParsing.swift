import Foundation

public enum ReviewParsing {
    public struct ReviewEnvelope: Decodable {
        public let language: String
        public let suggestions: [ReviewSuggestionEnvelope]
    }

    public struct ReviewSuggestionEnvelope: Decodable {
        public let kind: String
        public let start: Int
        public let end: Int
        public let original: String
        public let replacement: String
        public let explanation: String
    }

    public struct RedSuggestionOperationEnvelope: Decodable {
        public let operations: [RedSuggestionOperation]

        private enum CodingKeys: String, CodingKey {
            case operations
            case redOperations
            case red_operations
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            operations = try container.decodeIfPresent([RedSuggestionOperation].self, forKey: .operations) ??
                container.decodeIfPresent([RedSuggestionOperation].self, forKey: .redOperations) ??
                container.decodeIfPresent([RedSuggestionOperation].self, forKey: .red_operations) ??
                []
        }
    }

    public struct RedSuggestionOperation: Decodable {
        public let op: String
        public let id: String?
        public let start: Int?
        public let end: Int?
        public let original: String?
        public let replacement: String?
        public let explanation: String?

        private enum CodingKeys: String, CodingKey {
            case op
            case operation
            case id
            case start
            case end
            case original
            case replacement
            case explanation
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            op = try container.decodeIfPresent(String.self, forKey: .op) ??
                container.decodeIfPresent(String.self, forKey: .operation) ??
                ""
            id = try container.decodeIfPresent(String.self, forKey: .id)
            start = try container.decodeIfPresent(Int.self, forKey: .start)
            end = try container.decodeIfPresent(Int.self, forKey: .end)
            original = try container.decodeIfPresent(String.self, forKey: .original)
            replacement = try container.decodeIfPresent(String.self, forKey: .replacement)
            explanation = try container.decodeIfPresent(String.self, forKey: .explanation)
        }
    }

    public struct ActionEnvelope: Decodable {
        public let replacement: String
        public let explanation: String
    }

    public struct AgentEnvelope: Decodable {
        public let message: String?
        public let patches: [AgentPatchEnvelope]?
        public let outline: [String]?
    }

    public struct AgentToolTurnEnvelope: Decodable {
        public let message: String?
        public let final_message: String?
        public let tool_calls: [AgentToolCallEnvelope]?
        public let patches: [AgentPatchEnvelope]?
        public let outline: [String]?
    }

    public struct AgentToolCallEnvelope: Decodable {
        public let id: String?
        public let name: String
        public let arguments: LossyStringDictionary?
    }

    public struct LossyStringDictionary: Decodable, Equatable {
        public let values: [String: String]

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let dictionary = try? container.decode([String: String].self) {
                values = dictionary
                return
            }
            if let dictionary = try? container.decode([String: LossyStringValue].self) {
                values = dictionary.mapValues(\.value)
                return
            }
            values = [:]
        }
    }

    public struct LossyStringValue: Decodable, Equatable {
        public let value: String

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                value = string
            } else if let int = try? container.decode(Int.self) {
                value = String(int)
            } else if let double = try? container.decode(Double.self) {
                value = String(double)
            } else if let bool = try? container.decode(Bool.self) {
                value = bool ? "true" : "false"
            } else {
                value = ""
            }
        }
    }

    public struct AgentPatchEnvelope: Decodable {
        public let start: Int
        public let end: Int
        public let original: String
        public let replacement: String
        public let reason: String?
    }

    public struct GhostEnvelope: Decodable {
        public let completion: String
        public let explanation: String?
    }

    public static func extractJSONObject(from text: String) throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }
        guard
            let first = trimmed.firstIndex(of: "{"),
            let last = trimmed.lastIndex(of: "}")
        else {
            throw LLMError.malformedJSON
        }
        let slice = String(trimmed[first...last])
        guard let data = slice.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw LLMError.malformedJSON
        }
        return data
    }

    public static func parseSuggestionBatch(
        content: String,
        snapshot: TextSnapshot
    ) throws -> SuggestionBatch {
        let jsonData = try extractJSONObject(from: content)
        let envelope = try JSONDecoder().decode(ReviewEnvelope.self, from: jsonData)
        let analysisNSString = snapshot.analysisText as NSString
        let paragraphIdentity = "\(snapshot.analysisRangeInFullText.location):\(snapshot.analysisRangeInFullText.length)"
        let suggestions = envelope.suggestions.compactMap { item -> Suggestion? in
            guard item.start >= 0, item.end >= item.start else { return nil }
            let localRange = NSRange(location: item.start, length: item.end - item.start)
            guard NSMaxRange(localRange) <= analysisNSString.length else { return nil }
            let original = analysisNSString.substring(with: localRange)
            guard original == item.original else { return nil }
            guard let kind = SuggestionKind(rawValue: item.kind) else { return nil }
            let fullRange = ParagraphContextExtractor.mapAnalysisRangeToFullText(
                analysisRange: localRange,
                analysisRangeInFullText: snapshot.analysisRangeInFullText
            )
            let suggestion = Suggestion(
                kind: kind,
                source: .llm,
                rangeInFullText: fullRange,
                originalText: original,
                replacementText: item.replacement,
                explanation: item.explanation,
                paragraphIdentity: paragraphIdentity
            )
            guard !suggestion.isNoOpReplacement else { return nil }
            return suggestion
        }
        return SuggestionBatch(
            snapshotRevision: snapshot.revision,
            paragraphIdentity: paragraphIdentity,
            suggestions: suggestions
        )
    }

    public static func parseRedSuggestionBatch(
        content: String,
        snapshot: TextSnapshot,
        candidates: [Suggestion]
    ) throws -> SuggestionBatch {
        let jsonData = try extractJSONObject(from: content)
        let envelope = try JSONDecoder().decode(RedSuggestionOperationEnvelope.self, from: jsonData)
        let analysisNSString = snapshot.analysisText as NSString
        let paragraphIdentity = "\(snapshot.analysisRangeInFullText.location):\(snapshot.analysisRangeInFullText.length)"
        var existingByID: [String: Suggestion] = [:]
        for candidate in candidates {
            existingByID[candidate.stableIdentity] = candidate
        }
        var added: [Suggestion] = []

        for operation in envelope.operations {
            let op = operation.op.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch op {
            case "keep", "read", "query", "find":
                guard let id = operation.id, var suggestion = existingByID[id] else { continue }
                if let explanation = operation.explanation?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !explanation.isEmpty {
                    suggestion.explanation = explanation
                }
                existingByID[id] = suggestion
            case "delete", "remove", "reject":
                guard let id = operation.id else { continue }
                existingByID.removeValue(forKey: id)
            case "update", "revise", "modify":
                guard let id = operation.id, let existing = existingByID[id] else { continue }
                guard let revised = redSuggestion(
                    from: operation,
                    fallback: existing,
                    snapshot: snapshot,
                    analysisNSString: analysisNSString,
                    paragraphIdentity: paragraphIdentity
                ) else {
                    existingByID.removeValue(forKey: id)
                    continue
                }
                existingByID[id] = revised
            case "add", "create", "insert":
                guard let suggestion = redSuggestion(
                    from: operation,
                    fallback: nil,
                    snapshot: snapshot,
                    analysisNSString: analysisNSString,
                    paragraphIdentity: paragraphIdentity
                ) else { continue }
                added.append(suggestion)
            default:
                continue
            }
        }

        let suggestions = Array(existingByID.values) + added
        return SuggestionBatch(
            snapshotRevision: snapshot.revision,
            paragraphIdentity: paragraphIdentity,
            suggestions: suggestions.filter { !$0.isNoOpReplacement }
        )
    }

    private static func redSuggestion(
        from operation: RedSuggestionOperation,
        fallback: Suggestion?,
        snapshot: TextSnapshot,
        analysisNSString: NSString,
        paragraphIdentity: String
    ) -> Suggestion? {
        let localRange: NSRange
        let original: String

        if let start = operation.start, let end = operation.end {
            guard start >= 0, end > start else { return nil }
            localRange = NSRange(location: start, length: end - start)
            guard NSMaxRange(localRange) <= analysisNSString.length else { return nil }
            original = analysisNSString.substring(with: localRange)
            if let requestedOriginal = operation.original, requestedOriginal != original {
                return nil
            }
        } else if let fallback {
            localRange = NSRange(
                location: fallback.rangeInFullText.location - snapshot.analysisRangeInFullText.location,
                length: fallback.rangeInFullText.length
            )
            guard localRange.location >= 0,
                  NSMaxRange(localRange) <= analysisNSString.length else {
                return nil
            }
            original = fallback.originalText
        } else {
            return nil
        }

        let replacement = operation.replacement?.trimmingCharacters(in: .whitespacesAndNewlines) ??
            fallback?.replacementText ??
            ""
        guard !replacement.isEmpty, replacement != original else { return nil }

        let fullRange = ParagraphContextExtractor.mapAnalysisRangeToFullText(
            analysisRange: localRange,
            analysisRangeInFullText: snapshot.analysisRangeInFullText
        )
        let explanation = operation.explanation?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Suggestion(
            id: fallback?.id ?? UUID(),
            kind: .spelling,
            source: .llm,
            rangeInFullText: fullRange,
            originalText: original,
            replacementText: replacement,
            explanation: explanation?.isEmpty == false ? explanation! : (fallback?.explanation ?? "LLM red underline adjudication."),
            paragraphIdentity: paragraphIdentity,
            proofIssueKind: fallback?.proofIssueKind ?? .spelling,
            proofIssueSeverity: fallback?.proofIssueSeverity ?? .warning,
            proofIssueConfidence: fallback?.proofIssueConfidence,
            proofIssueDetectorSource: "llm_red_judge",
            proofIssueAdvancedTip: fallback?.proofIssueAdvancedTip,
            proofIssueAutofixSafe: false
        )
    }

    public static func parseActionResult(content: String) throws -> ReviewActionResult {
        let jsonData = try extractJSONObject(from: content)
        let envelope = try JSONDecoder().decode(ActionEnvelope.self, from: jsonData)
        return ReviewActionResult(replacement: envelope.replacement, explanation: envelope.explanation)
    }

    public static func parseAgentResponse(
        content: String,
        snapshot: TextSnapshot
    ) throws -> AgentResponse {
        let jsonData = try extractJSONObject(from: content)
        let envelope = try JSONDecoder().decode(AgentEnvelope.self, from: jsonData)
        let patches = parseAgentPatches(envelope.patches ?? [], snapshot: snapshot)
        let message = envelope.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let outline = (envelope.outline ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !message.isEmpty || !patches.isEmpty || !outline.isEmpty else {
            throw LLMError.emptyContent
        }
        return AgentResponse(message: message, patches: patches, outline: outline)
    }

    public static func parseAgentToolTurnResponse(
        content: String,
        snapshot: TextSnapshot
    ) throws -> AgentToolTurnResponse {
        let jsonData = try extractJSONObject(from: content)
        let envelope = try JSONDecoder().decode(AgentToolTurnEnvelope.self, from: jsonData)
        let message = (envelope.final_message ?? envelope.message ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let toolCalls = (envelope.tool_calls ?? []).compactMap { item -> AgentToolCall? in
            guard let name = AgentToolName(rawValue: item.name) else { return nil }
            return AgentToolCall(
                id: item.id?.isEmpty == false ? item.id! : UUID().uuidString,
                name: name,
                arguments: item.arguments?.values ?? [:]
            )
        }
        let patches = parseAgentPatches(envelope.patches ?? [], snapshot: snapshot)
        let outline = (envelope.outline ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !message.isEmpty || !toolCalls.isEmpty || !patches.isEmpty || !outline.isEmpty else {
            throw LLMError.emptyContent
        }
        return AgentToolTurnResponse(message: message, toolCalls: toolCalls, patches: patches, outline: outline)
    }

    public static func parseGhostSuggestion(
        content: String,
        snapshot: TextSnapshot,
        caretRange: NSRange,
        maxUTF16Length: Int = 80
    ) throws -> GhostSuggestion {
        let jsonData = try extractJSONObject(from: content)
        let envelope = try JSONDecoder().decode(GhostEnvelope.self, from: jsonData)
        let completion = envelope.completion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !completion.isEmpty else { throw LLMError.emptyContent }
        guard (completion as NSString).length <= maxUTF16Length else { throw LLMError.malformedJSON }
        guard caretRange.length == 0,
              caretRange.location >= 0,
              caretRange.location <= (snapshot.fullText as NSString).length else {
            throw LLMError.malformedJSON
        }
        return GhostSuggestion(
            rangeInFullText: caretRange,
            text: completion,
            explanation: envelope.explanation ?? "",
            snapshotRevision: snapshot.revision
        )
    }

    private static func parseAgentPatches(
        _ patchEnvelopes: [AgentPatchEnvelope],
        snapshot: TextSnapshot
    ) -> [TextPatch] {
        let nsText = snapshot.fullText as NSString
        return patchEnvelopes.compactMap { item -> TextPatch? in
            guard item.start >= 0, item.end >= item.start else { return nil }
            let range = NSRange(location: item.start, length: item.end - item.start)
            guard NSMaxRange(range) <= nsText.length else { return nil }
            let original = nsText.substring(with: range)
            guard original == item.original else { return nil }
            let patch = TextPatch(
                rangeInFullText: range,
                originalText: original,
                replacementText: item.replacement,
                reason: item.reason ?? ""
            )
            guard patch.validate(against: snapshot.fullText) else { return nil }
            return patch
        }
    }
}
